# Local Data Lake Schema Test Environment

A local stack for validating the **star schema, SCD Type-1/Type-2 logic,
columnar table design, and live CDC capture** before touching the client's
real infrastructure.

## What's in here

| Component | Role | Stands in for |
|---|---|---|
| `postgres` | Source OLTP database with sample IAM data | Client's PostgreSQL |
| `minio` | S3-compatible object storage | AWS S3 |
| `iceberg-rest` | Apache Iceberg REST catalog (table metadata/versioning) | Snowflake's internal table format handling |
| `trino` | Columnar SQL query engine — supports `MERGE INTO`, partitioning, ANSI SQL | Snowflake's query engine |
| `debezium-server` | Captures Postgres WAL changes via logical replication | The real CDC layer proposed for the client |
| `echo-receiver` | HTTP endpoint that logs incoming CDC events | Temporary stand-in for the S3 sink (see note below) |

Apache Iceberg is the closest open equivalent to how Snowflake actually
manages tables under the hood, and Snowflake natively supports querying
Iceberg tables — so schema/logic validated here should translate cleanly.

**Status:** schema and SCD merge logic are fully validated. Debezium Server
is capturing real Postgres WAL changes end-to-end (snapshot + live
streaming both confirmed working). Landing those events into S3/Iceberg
automatically is not yet solved — see "Known limitation" below.

## 1. Start the stack

```bash
docker compose up -d
```

Wait ~30 seconds for health checks to pass. Verify:
- MinIO console: http://localhost:9001 (minioadmin / minioadmin) — you should see a `datalake` bucket
- Trino UI: http://localhost:8080
- Debezium Server logs: `docker logs -f dl_debezium_server` — should reach `"Processing messages"` with no errors

## 2. Connect a SQL client

**To Trino** (star schema / Iceberg tables): use the Trino CLI (`docker exec -it dl_trino trino`) or DBeaver with the Trino driver, JDBC URL `jdbc:trino://localhost:8080/iceberg/iam?user=dbeaver` (any username works — no real auth configured).

**To Postgres directly** (source data, needed to trigger live CDC events): a separate DBeaver connection — host `localhost`, port `5432`, database `iam_source`, user `iam_user`, password `iam_pass`. Running `UPDATE`/`DELETE` statements here is what Debezium actually watches.

## 3. Build the star schema

Run the contents of `lakehouse-sql/01_star_schema.sql` in your SQL client
against Trino. This creates `dim_user`, `dim_role`, `dim_resource`,
`fact_access_grant` (Type 1) and `fact_access_grant_history` (Type 2) as
Iceberg tables.

**Run it as individual statements, not as a full script** — see
`TROUBLESHOOTING.md` for why DBeaver's "Execute Script" mode has been
unreliable with these files.

## 4. Load the day-2 delta and test SCD merge logic

The Postgres source (`postgres-init/01_schema.sql`) seeds:
- `iam_denormalized` — day-1 state (5 grants)
- `iam_denormalized_day2_delta` — day-2 changes (1 update/revoke, 1 new grant, 1 hard delete)

Load the delta into `iceberg.iam.stg_delta` (see `02_merge_delta.sql` for
the staging table DDL), either via Trino's Postgres catalog federation
(`INSERT INTO iceberg.iam.stg_delta SELECT * FROM postgres.public.iam_denormalized_day2_delta`)
or manually.

Then run `lakehouse-sql/02_merge_delta.sql`. It applies both:
- **Type 1** merge into `fact_access_grant` (overwrite — current state only)
- **Type 2** merge into `fact_access_grant_history` (close old row, insert new versioned row)

The sanity-check queries at the bottom demonstrate exactly the kind of
point-in-time query ("what access existed as of Feb 1") that the history
table needs to support for the client.

**Important:** load day-1 base data into `fact_access_grant` /
`fact_access_grant_history` *before* running the merge, or you'll be
merging against an empty table. See `TROUBLESHOOTING.md` for the exact
symptom this produces if skipped.

## 5. Debezium: live CDC capture

Debezium Server watches `public.iam_denormalized` via PostgreSQL logical
replication (the `pgoutput` plugin — no extra Postgres extension needed)
and emits a change event for every insert/update/delete, including hard
deletes, independent of any `updated_at` column discipline.

**Try it:**
```sql
-- against the direct Postgres connection, not Trino
UPDATE iam_denormalized SET revoked_at = now(), updated_at = now() WHERE grant_id = 3;
```

Then:
```bash
docker logs dl_echo_receiver --tail 30
```

You should see a fresh JSON event with `"op": "u"` and `"snapshot": "false"`
land within a second or two — proof the WAL capture is live.

### Known limitation: no S3 sink in this image

`debezium/server:3.0.0.Final`'s bundled sinks are: `eventhubs`, `http`,
`infinispan`, `kafka`, `kinesis`, `nats-jetstream`, `nats-streaming`,
`pravega`, `pubsub`, `pulsar`, `rabbitmq`, `redis`, `rocketmq`, `sqs`.
**No S3.** The `http` sink (pointed at `echo-receiver`, a simple
request-logging container) is being used as a temporary stand-in to prove
the CDC mechanism works end-to-end.

Landing events into S3 (matching the architecture proposed to the client)
still needs one of:
- A custom image adding the `debezium-server-s3` JAR + its AWS SDK
  dependencies to `/debezium/lib`
- A purpose-built alternative image with native Iceberg-table writing
  (skips the S3-intermediate step entirely)
- Reconsidering the sink choice for this local test vs. what's actually
  proposed for the client environment

This is the next open task — not yet resolved as of this commit.

### REPLICA IDENTITY note

`iam_denormalized` currently has `REPLICA IDENTITY DEFAULT`, so
update/delete events only carry previous values for primary-key columns,
not the full old row. For IAM data where "what changed" matters for audit
purposes, consider:
```sql
ALTER TABLE iam_denormalized REPLICA IDENTITY FULL;
```

## 6. What to actually validate here

- Does the star schema (flattened dims + fact) hold up against the real
  denormalized IAM source, or does it reveal a normalization the client's
  data actually needs?
- Does the Type 1 / Type 2 merge logic correctly handle all three delta
  operations (create/update/delete), including the hard-delete case?
- Does partitioning by `updated_at`/`effective_start` behave sensibly for
  the query patterns you expect (e.g., point-in-time lookups, "who currently
  has access to X")?
- Does Debezium's WAL-based capture actually catch changes a batch/
  `updated_at`-filtered query would miss? (Confirmed yes, for hard deletes.)

## Not covered here (intentionally)

- S3/Iceberg landing for CDC events — open task, see "Known limitation" above
- Environment isolation — this is a single local sandbox
- Snowflake-specific features (Hybrid Tables, clustering keys, exact SQL
  dialect quirks) — for those, validate against a real Snowflake **free
  trial account** (cloud-only, 30 days) once the schema is stable here

## Troubleshooting

See `TROUBLESHOOTING.md` for real issues hit setting this up (S3 path-style
access, smart-quote corruption, DBeaver script-parsing quirks, wrong
Debezium image tag/config path, missing S3 sink) and their fixes.

## Tear down

```bash
docker compose down -v   # -v also removes the local data volumes
```
