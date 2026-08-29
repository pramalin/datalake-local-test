# Local Data Lake Schema Test Environment

A local stack for validating the **star schema, SCD Type-1/Type-2 logic,
columnar table design, and live CDC capture** before touching the client's
real infrastructure.

## What's in here

| Component | Role | Stands in for |
|---|---|---|
| `postgres` | Source OLTP database with sample IAM data | Client's PostgreSQL |
| `minio` | S3-compatible object storage | AWS S3 |
| `iceberg-rest` | Apache Iceberg REST catalog (table metadata/versioning) — `apache/iceberg-rest-fixture`, the official Apache Iceberg reference image | Snowflake's internal table format handling |
| `trino` | Columnar SQL query engine — supports `MERGE INTO`, partitioning, ANSI SQL | Snowflake's query engine |
| `debezium-server` | Captures Postgres WAL changes and writes directly to Iceberg tables (upsert mode) — `ghcr.io/memiiso/debezium-server-iceberg` | The real CDC + landing layer proposed for the client |
| `echo-receiver` | HTTP endpoint that logs incoming CDC events | Optional — kept from earlier debugging, not required for the current pipeline |

Apache Iceberg is the closest open equivalent to how Snowflake actually
manages tables under the hood, and Snowflake natively supports querying
Iceberg tables — so schema/logic validated here should translate cleanly.

![Local data lake stack architecture](docs/images/architecture.svg)

**Status: fully working end-to-end.** Schema and SCD merge logic are
validated, and Debezium Server now writes real Postgres CDC events —
snapshot and live streaming, inserts/updates/deletes — directly into
Iceberg tables via upsert, with no manual staging or merge step. Verified
with a live `UPDATE` against Postgres correctly appearing as an upsert in
the Iceberg table within seconds.

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

## 5. Debezium: live CDC capture, landing directly in Iceberg

Debezium Server watches `public.iam_denormalized` via PostgreSQL logical
replication (the `pgoutput` plugin — no extra Postgres extension needed)
and emits a change event for every insert/update/delete, including hard
deletes, independent of any `updated_at` column discipline. Those events
are written straight into an Iceberg table via **upsert mode** — no manual
staging table, no separate merge job.

**Try it:**
```sql
-- against the direct Postgres connection, not Trino
UPDATE iam_denormalized SET revoked_at = now(), updated_at = now() WHERE grant_id = 3;
```

Then, in Trino:
```sql
SELECT * FROM iceberg.iam.cdc_dev_iam_public_iam_denormalized WHERE grant_id = 3;
```

Within a few seconds you should see that row updated in place — same row
count, new `revoked_at`/`updated_at`, `__op` showing `u` — proof the whole
chain (WAL → Debezium → Iceberg REST catalog → S3 Parquet) is live and
correct.

![CDC upsert flow: Postgres UPDATE to Iceberg row, end to end](docs/images/cdc-upsert-flow.svg)

### How the S3/Iceberg sink question got resolved

This took real trial and error, documented in full in `TROUBLESHOOTING.md`.
The short version:

1. **Stock `debezium/server` doesn't ship an S3 or Iceberg sink** — its
   bundled sinks are Kafka, Pulsar, Kinesis, Redis, HTTP, etc., but not
   S3/Iceberg, in the version tags actually available on Docker Hub.
2. **`ghcr.io/memiiso/debezium-server-iceberg`** is a community project
   (now referenced directly in Debezium's own official docs as the
   supported way to get an Iceberg sink) that writes CDC events straight
   into Iceberg tables — no Kafka, no S3-JSON intermediate step.
3. That surfaced two more issues, both now fixed:
   - The default table **format-version 3** wasn't supported by
     `tabulario/iceberg-rest` (stale, hasn't been updated in over a year).
     Swapped to **`apache/iceberg-rest-fixture`**, the official Apache
     Iceberg project's own reference image, which does support v3.
   - The AWS S3 client needs an explicit **region** even though MinIO
     ignores it — added `AWS_REGION=us-east-1`.

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
- Does the CDC → Iceberg pipeline correctly upsert changes with no
  duplicate rows and no manual merge step? (Confirmed yes — a live
  Postgres `UPDATE` appears as an in-place upsert in the Iceberg table.)

## Not covered here (intentionally)

- Environment isolation — this is a single local sandbox
- Snowflake-specific features (Hybrid Tables, clustering keys, exact SQL
  dialect quirks) — for those, validate against a real Snowflake **free
  trial account** (cloud-only, 30 days) once the schema is stable here

## Troubleshooting

See `TROUBLESHOOTING.md` for real issues hit setting this up — S3
path-style access, smart-quote corruption, DBeaver script-parsing quirks,
Debezium image tags/config paths, the missing-S3-sink dead end, the
Iceberg format-version mismatch, and the AWS region requirement — and how
each was actually resolved.

## Tear down

```bash
docker compose down -v   # -v also removes the local data volumes
```
