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

## 10. `ghcr.io/memiiso/debezium-server-iceberg:1.1.0.Final` fails to pull

**Symptom:**
```
failed to copy: httpReadSeeker: failed open: content at
https://ghcr.io/v2/memiiso/debezium-server-iceberg/manifests/sha256:...
not found: not found
```

**Root cause:** a broken published image on GHCR — confirmed by a comment
in the project's own release workflow describing a known issue where an
image-cleanup step can delete layers a release tag still points to,
leaving the tag present but unpullable.

**Fix:** use the `latest` tag instead of a specific pinned version
(`ghcr.io/memiiso/debezium-server-iceberg:latest`) — a separate push not
affected by the same broken cleanup run.

---

## 11. `Unsupported format version: v3 (supported: v2)`

**Symptom:**
```
Failed to create table from debezium event ... Error:Unsupported format version: v3 (supported: v2)
```

**Root cause:** `debezium-server-iceberg` defaults to writing Iceberg
tables using table **format-version 3**. `tabulario/iceberg-rest` (the
catalog image used up to this point) is stuck on Iceberg REST catalog spec
version 1.6.0 (no updates in over a year) and only understands v2.

**Fix — the real one:** swap the catalog image for the **official Apache
Iceberg project's own reference image**, which is actively maintained and
supports v3:
```yaml
iceberg-rest:
  image: apache/iceberg-rest-fixture:1.10.1   # was tabulario/iceberg-rest:latest
```
(A same-day workaround of forcing `debezium.sink.iceberg.format-version=2`
also works if you specifically need v2, but the catalog swap is the
better fix since it removes the ceiling entirely.)

**Important side effect:** swapping the catalog image resets its internal
metadata store — existing namespaces/tables are no longer known to the new
catalog, even though the underlying Parquet files remain in MinIO. Do a
full reset (`docker compose down -v && docker compose up -d`) and rebuild
the star schema fresh after this swap.

---

## 12. `Unable to load region from any of the providers in the chain`

**Symptom:**
```
software.amazon.awssdk.core.exception.SdkClientException: Unable to load region
from any of the providers in the chain ... Region must be specified either via
environment variable (AWS_REGION) or system property (aws.region)
```
This happens specifically when actually **writing** a data file (after
table creation already succeeded) — the AWS S3 client requires a region
even when the endpoint is MinIO, which doesn't use regions at all.

**Fix:** set the region in two places for reliability:
```yaml
# docker-compose.yml
debezium-server:
  environment:
    - AWS_REGION=us-east-1
```
```properties
# application.properties
debezium.sink.iceberg.client.region=us-east-1
```

---

## 13. Config file edits silently not taking effect

**Recurring symptom throughout this session:** an error referencing a
property that was definitely added to `application.properties` (e.g.
`debezium.sink.iceberg.warehouse is required`), followed by `grep` on the
file showing the property genuinely absent.

**Root cause:** several `sed`/edit commands across the session updated a
version of the file that wasn't the one actually mounted, or an edit
described in chat was never actually run against the real file on disk.

**Fix / habit that prevented repeat failures:** after any config change,
always verify with a direct `grep` on the exact property before restarting
containers — e.g. `grep "warehouse" debezium/conf/application.properties`
— rather than assuming an edit landed. When in doubt, overwrite the whole
file in one `cat > file << 'EOF' ... EOF` block rather than patching
piecemeal, since that removes any ambiguity about what the file actually
contains afterward.

---

## 14. Upsert-mode sink silently discards history (design bug, not a technical one)

**Symptom:** none -- this "worked" with no errors. Debezium's Iceberg sink
with `upsert=true` correctly captured every CDC event and correctly
updated the Iceberg table in place. The problem only surfaced under
external review: an upsert *overwrites* the previous row, so the pipeline
could capture every change but still could not answer "what did this
grant look like before this change?" -- the very question the whole
historical model exists to answer.

**Root cause:** conflating two different jobs into one table. Upsert mode
is correct for a *current-state* table, but the CDC landing table itself
also needs to be the permanent record -- and a table that gets
overwritten cannot serve as a permanent record.

**Fix:** split into bronze (append-only, `upsert=false`) and gold (derived
from bronze via a real merge). See README.md section 5 for the full
design and `lakehouse-sql/03_bronze_to_gold.sql` for the implementation.
This is the single most important fix to come out of this project --
worth internalizing as a general pattern: **a CDC sink that overwrites is
a current-state cache, not a history log. If you need history, land the
raw events append-only first, and derive current-state and historical
views from that log separately.**

---

## 15. After a full reset, only some star-schema tables existed

**Symptom:** after `docker compose down -v` (needed to reset the Iceberg
catalog when switching sink modes), `SHOW TABLES FROM iceberg.iam` showed
`fact_access_grant_history` but not `dim_user`, `dim_role`, `dim_resource`,
or `fact_access_grant` -- and a subsequent merge script failed with
`Table 'iceberg.iam.fact_access_grant' does not exist`, despite
`01_star_schema.sql` having apparently been run.

**Root cause:** the same DBeaver "Execute Script" partial-failure pattern
documented in issue #3, recurring after a full environment reset. A script
run can silently stop partway through without a clearly visible error,
leaving some `CREATE TABLE` statements executed and later ones skipped.

**Fix / standing practice:** after *any* full reset, don't assume
`01_star_schema.sql` completed -- verify with `SHOW TABLES FROM
iceberg.iam` and confirm the expected table count before proceeding to
any script that depends on those tables existing. Running DDL scripts
statement-by-statement rather than as a full script remains the more
reliable path with this DBeaver/Trino combination.

---

## Final resolution

The full pipeline -- PostgreSQL (WAL, pgoutput) -> Debezium Server
(`debezium-server-iceberg`, **append-only bronze sink**) -> Apache Iceberg
REST catalog (`apache/iceberg-rest-fixture`) -> S3/MinIO Parquet tables,
with an **idempotent, watermark-tracked bronze-to-gold merge** deriving
current-state and effective-dated history -- is confirmed working end to
end. Verified directly: a live Postgres `UPDATE` lands as a new,
non-destructive row in the bronze log; the gold merge correctly derives
two history versions from it; and re-running the merge with no new bronze
events leaves both gold tables' row counts and current-version counts
exactly unchanged. See `README.md` section 5 for the final architecture
and `lakehouse-sql/03_bronze_to_gold.sql` for the implementation.

---

## General lesson

Most of the above weren't bugs in the SQL or the architecture — they were
copy/paste corruption (smart quotes), an under-documented image config
(S3 path-style), a client-side script-parsing quirk (DBeaver), and ordinary
operator error compounded by not checking state between steps. None of them
say anything bad about Iceberg, Trino, or the schema design itself — the
star schema and SCD Type 1/2 merge logic both validated correctly once the
environment noise was eliminated.
