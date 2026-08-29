# Troubleshooting

Real issues hit while standing up this stack and validating the schema, and
how they were resolved — kept here so the next run (or the next person) hits
them once, not repeatedly.

---

## 1. `UnknownHostException: datalake.<bucket>` on `CREATE TABLE`

**Symptom:**
```
SQL Error [...]: Query failed: Failed to commit the transaction during create table:
Service failed: 500: Received an UnknownHostException when attempting to interact
with a service...
Caused by: java.net.UnknownHostException: datalake.minio
```

Note this only fails on `CREATE TABLE` (which writes real files to S3), not on
`CREATE SCHEMA` (which doesn't) — so if schema creation succeeds and table
creation doesn't, this is the first thing to check.

**Root cause:** without forcing path-style S3 addressing, the AWS S3 client
inside the `iceberg-rest` catalog service defaults to *virtual-hosted-style*
addressing — it prepends the bucket name as a subdomain (`datalake.minio`)
instead of using it as a path (`minio/datalake`). Docker's internal DNS has
no record for `datalake.minio`, so the request fails to resolve.

**Fix:** add path-style access flags to the `iceberg-rest` service in
`docker-compose.yml`:

```yaml
  iceberg-rest:
    environment:
      CATALOG_WAREHOUSE: s3://datalake/warehouse
      CATALOG_IO__IMPL: org.apache.iceberg.aws.s3.S3FileIO
      CATALOG_S3_ENDPOINT: http://minio:9000
      CATALOG_S3_PATH__STYLE__ACCESS: "true"
      CATALOG_S3_PATH_STYLE_ACCESS: "true"
      AWS_ACCESS_KEY_ID: minioadmin
      AWS_SECRET_ACCESS_KEY: minioadmin
      AWS_REGION: us-east-1
```

Both underscore variants are included because the exact env-var naming
convention for this image isn't consistently documented across sources —
the unused one is simply ignored, so including both costs nothing and avoids
another guess-and-check cycle.

**Verify the flag actually landed** before assuming the fix is in place:
```bash
docker exec dl_iceberg_rest env | grep -i path
```
Both `CATALOG_S3_PATH__STYLE__ACCESS=true` and `CATALOG_S3_PATH_STYLE_ACCESS=true`
should appear. If they don't, `docker compose up -d` didn't pick up the file
change — check the file itself (`grep -A 12 "iceberg-rest:" docker-compose.yml`)
before assuming the container is wrong.

---

## 2. `mismatched input ';'` on a `CREATE SCHEMA ... WITH (location = ...)` clause

**Symptom:**
```
SQL Error [1]: Query failed: line 5:48: mismatched input ';'. Expecting: '%', ')', '*', ...
```

**Root cause (confirmed in this case):** the single quotes around the S3
path had been silently converted to curly/smart quotes (`'…'` instead of
`'…'`) at some point — likely by whatever copied the SQL text between
tools. Trino's parser doesn't recognize a smart-quoted string as a properly
closed string literal, so the clause after it reads as malformed.

**Fix applied:** dropped the `WITH (location = ...)` clause entirely — it's
not required. The Iceberg REST catalog derives the schema's location
automatically from `CATALOG_WAREHOUSE`.
```sql
CREATE SCHEMA IF NOT EXISTS iceberg.iam;
```

**If you hit smart quotes elsewhere:** check for them explicitly rather than
assuming a single fix caught them all:
```bash
grep -n "[‘’“”]" lakehouse-sql/*.sql
sed -i "s/[‘’]/'/g; s/[“”]/\"/g" lakehouse-sql/*.sql
```

---

## 3. Same error signature recurring at a *different* line number

**Symptom:** after fixing #2, the identical `mismatched input ';'` error
reappeared later in the same file (a different `WITH (format = 'PARQUET')`
clause) — and after fixing that, the error persisted again, at a line
number that didn't match the file's actual content on inspection.

**Root cause:** not the SQL file at all. `cat`, `cat -A` (checking for
stray `\r` / smart quotes), and a full manual read of the file all came back
clean. The actual cause was **DBeaver's "Execute SQL Script" mode**
(multi-statement, e.g. Alt+X) misjudging statement boundaries across the
file — the reported line/column was relative to whatever DBeaver decided to
send as one chunk, not to the file's real line numbers.

**Fix / workaround:** run statements individually instead of as a full
script — click into a single statement and use **Execute SQL Statement**
(`Ctrl+Enter`), not Execute Script, especially for files with multiple
`CREATE TABLE` blocks. Slower, but each error then maps directly and
unambiguously to the exact text that failed.

---

## 4. `Schema 'iam_source' does not exist` when querying Postgres from Trino

**Symptom:**
```sql
SELECT * FROM postgres.iam_source.iam_denormalized_day2_delta;
-- Schema 'iam_source' does not exist
```

**Root cause:** `iam_source` is the **Postgres database name**, not a
schema. Trino's Postgres connector addresses tables as
`<trino-catalog>.<postgres-schema>.<table>` — and the schema is whatever
schema the table actually lives in inside that database (Postgres's default
is `public`), not the database name itself.

**Fix:**
```sql
SHOW SCHEMAS FROM postgres;   -- confirm what's actually there
SELECT * FROM postgres.public.iam_denormalized_day2_delta;
```

---

## 5. Silently double-running a seed/insert step

**Symptom:** row counts and query results that don't match expectations in
ways that don't point at any SQL logic bug — e.g. a point-in-time query
returning two identical rows for the same grant, or a history table with
exactly double the expected row count (10 instead of 5).

**Root cause:** re-running an `INSERT ... SELECT ... FROM postgres...`
seed statement a second time (e.g., after a script-mode failure and retry)
silently duplicates the base data, since these seed inserts have no
uniqueness guard.

**Fix / prevention:** after every load/seed/merge statement, immediately
check the row count before moving to the next step, rather than running
several statements in a row and only checking at the end:
```sql
SELECT COUNT(*) FROM iceberg.iam.fact_access_grant_history;
```
When state does get corrupted, the fastest fix is a full reset rather than
trying to reverse-engineer what ran how many times:
```sql
DROP SCHEMA IF EXISTS iceberg.iam CASCADE;
```
then rebuild from `01_star_schema.sql` forward, checking counts after each
step.

---

## 6. `debezium/server:latest` — image not found

**Symptom:**
```
Error response from daemon: failed to resolve reference "docker.io/debezium/server:latest": ...not found
```

**Root cause:** the official `debezium/server` image on Docker Hub has no
`latest` tag — only explicit version tags (e.g. `3.0.0.Final`,
`2.7.3.Final`). The whole `debezium` org on Docker Hub also hasn't
published anything new in roughly two years; Debezium may have shifted
primary publishing elsewhere since.

**Fix:** pin to a real, verified tag:
```yaml
image: debezium/server:3.0.0.Final
```

---

## 7. `Failed to load mandatory config value 'debezium.sink.type'`

**Symptom:** Debezium Server starts, logs warnings about
`application.properties.example`/`application.properties.cassandra.redis.example`
being unrecognized config files, then fails with a missing
`debezium.sink.type` error — even though `application.properties` was
mounted and looked correct.

**Root cause:** the volume was mounted to the wrong container path.
Debezium Server reads config from **`/debezium/config`**, not
`/debezium/conf`. The local folder can be named anything; the container
path must be exactly `/debezium/config`.

**Fix:**
```yaml
volumes:
  - ./debezium/conf:/debezium/config   # right-hand side must be /debezium/config
```

---

## 8. `No Debezium consumer named 's3' is available`

**Symptom:** config loads correctly (no more `sink.type` error), but
startup fails with this exact message, preceded by several
`Unrecognized configuration key "quarkus.s3.*"` warnings.

**Root cause:** `debezium/server:3.0.0.Final`'s bundled sinks do **not**
include S3. Confirmed directly by listing the image's lib folder:
```bash
docker exec dl_debezium_server sh -c "ls /debezium/lib | grep -i debezium-server"
```
Bundled: `eventhubs`, `http`, `infinispan`, `kafka`, `kinesis`,
`nats-jetstream`, `nats-streaming`, `pravega`, `pubsub`, `pulsar`,
`rabbitmq`, `redis`, `rocketmq`, `sqs`. No `s3`.

**Workaround used here:** switched to `debezium.sink.type=http` (confirmed
bundled) pointed at a `mendhak/http-https-echo` container, to prove the
WAL-capture mechanism works end-to-end without being blocked on the S3
question. This is **not** the final architecture — just a way to get a
real, verified "yes, CDC is working" checkpoint. Landing events in
S3/Iceberg for real is an open follow-up (see README "Known limitation").

---

## 9. Postgres replication connections silently refused

**Symptom:** would show up as Debezium failing to create a replication
slot, or connection-refused-style errors specifically on the replication
connection while normal queries work fine.

**Root cause:** `pg_hba.conf`'s `all` database keyword does **not** cover
replication connections — Postgres treats replication as a distinct
connection type requiring its own explicit rule, even for `trust`/`md5`
catch-all entries.

**Fix:** add an init script that appends a replication-specific rule
before the database starts for the first time:
```bash
# postgres-init/00_enable_replication.sh
echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"
```
Like the schema seed script, this only takes effect on a **fresh** volume
— `docker compose down -v && docker compose up -d` if added after the
first run.

---

## General lesson

Most of the above weren't bugs in the SQL or the architecture — they were
copy/paste corruption (smart quotes), an under-documented image config
(S3 path-style), a client-side script-parsing quirk (DBeaver), and ordinary
operator error compounded by not checking state between steps. None of them
say anything bad about Iceberg, Trino, or the schema design itself — the
star schema and SCD Type 1/2 merge logic both validated correctly once the
environment noise was eliminated.
