# Local Data Lake Schema Test Environment

A local stack for validating the **star schema, SCD Type-1/Type-2 logic, and
columnar table design** before touching the client's real infrastructure.
This intentionally skips Debezium/Kafka — per the client's priority, schema
correctness matters more right now than pipeline mechanics.

## What's in here

| Component | Role | Stands in for |
|---|---|---|
| `postgres` | Source OLTP database with sample IAM data | Client's PostgreSQL |
| `minio` | S3-compatible object storage | AWS S3 |
| `iceberg-rest` | Apache Iceberg REST catalog (table metadata/versioning) | Snowflake's internal table format handling |
| `trino` | Columnar SQL query engine — supports `MERGE INTO`, partitioning, ANSI SQL | Snowflake's query engine |

Apache Iceberg is the closest open equivalent to how Snowflake actually
manages tables under the hood, and Snowflake natively supports querying
Iceberg tables — so schema/logic validated here should translate cleanly.

## 1. Start the stack

```bash
docker compose up -d
```

Wait ~30 seconds for health checks to pass. Verify:
- MinIO console: http://localhost:9001 (minioadmin / minioadmin) — you should see a `datalake` bucket
- Trino UI: http://localhost:8080

## 2. Connect a SQL client to Trino

Easiest: use the Trino CLI.

```bash
docker exec -it dl_trino trino
```

Or connect any JDBC/DBeaver client to `localhost:8080`, catalog `iceberg`, no auth required (this is a local test setup — not for anything beyond your laptop).

## 3. Build the star schema

Run the contents of `lakehouse-sql/01_star_schema.sql` in your SQL client.
This creates `dim_user`, `dim_role`, `dim_resource`, `fact_access_grant`
(Type 1) and `fact_access_grant_history` (Type 2) as Iceberg tables.

## 4. Load the day-2 delta and test SCD merge logic

The Postgres source (`postgres-init/01_schema.sql`) seeds:
- `iam_denormalized` — day-1 state (5 grants)
- `iam_denormalized_day2_delta` — day-2 changes (1 update/revoke, 1 new grant, 1 hard delete)

Either:
- **(a)** Query Postgres directly from Trino using the `postgres` catalog
  (already configured) and `INSERT INTO iceberg.iam.stg_delta SELECT ... FROM postgres.public.iam_denormalized_day2_delta`, or
- **(b)** Manually insert the same rows into `iceberg.iam.stg_delta` (see
  comments in `02_merge_delta.sql`).

Then run `lakehouse-sql/02_merge_delta.sql`. It applies both:
- **Type 1** merge into `fact_access_grant` (overwrite — current state only)
- **Type 2** merge into `fact_access_grant_history` (close old row, insert new versioned row)

The sanity-check queries at the bottom demonstrate exactly the kind of
point-in-time query ("what access existed as of Feb 1") that the history
table needs to support for the client.

## 5. What to actually validate here

- Does the star schema (flattened dims + fact) hold up against the real
  denormalized IAM source, or does it reveal a normalization the client's
  data actually needs?
- Does the Type 1 / Type 2 merge logic correctly handle all three delta
  operations (create/update/delete), including the hard-delete case?
- Does partitioning by `updated_at`/`effective_start` behave sensibly for
  the query patterns you expect (e.g., point-in-time lookups, "who currently
  has access to X")?

## Not covered here (intentionally)

- Debezium / CDC streaming — out of scope while schema is the priority
- Environment isolation — this is a single local sandbox
- Snowflake-specific features (Hybrid Tables, clustering keys, exact SQL
  dialect quirks) — for those, validate against a real Snowflake **free
  trial account** (cloud-only, 30 days) once the schema is stable here

## Tear down

```bash
docker compose down -v   # -v also removes the local data volumes
```
