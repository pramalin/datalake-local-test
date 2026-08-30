# Sample Run: `./scripts/run-full-demo.sh`

This is the **complete, unedited output** of an actual run of the full
demo script (captured 2026-08-30) — every phase, every event, in order,
nothing skipped or cleaned up. It's here so the claims in `README.md`
aren't just assertions: you can see exactly what happened and judge for
yourself.

Reproduce it yourself with:
```bash
./scripts/run-full-demo.sh
```
Your own run's exact timestamps, the hard-delete's capture time, and
Trino's internal query IDs will differ — but every `PASS` line should
stay a `PASS`. If any of them don't, something has regressed; please
open an issue.

---

## Phase 1: Reset and setup

```
=== Resetting the environment (docker compose down -v && up -d) ===
[+] down 3/3
 ✔ Volume datalake-local-test_minio_data    Removed                                          0.3s
 ✔ Volume datalake-local-test_debezium_data Removed                                          0.0s
 ✔ Volume datalake-local-test_pg_data       Removed                                          0.1s
[+] up 11/11
 ✔ Volume datalake-local-test_debezium_data Created                                          0.0s
 ✔ Volume datalake-local-test_minio_data    Created                                          0.0s
 ✔ Network datalake-local-test_default      Created                                          0.1s
 ✔ Volume datalake-local-test_pg_data       Created                                          0.0s
 ✔ Container dl_minio                       Healthy                                          8.2s
 ✔ Container dl_postgres                    Healthy                                          9.0s
 ✔ Container dl_echo_receiver               Started                                          2.8s
 ✔ Container dl_minio_init                  Exited                                           8.2s
 ✔ Container dl_iceberg_rest                Started                                          7.6s
 ✔ Container dl_debezium_server             Started                                          8.2s
 ✔ Container dl_trino                       Started                                          7.6s

=== Waiting for Trino to finish initializing ===
  still initializing... (1/30)
  still initializing... (2/30)
  still initializing... (3/30)
  still initializing... (4/30)
  still initializing... (5/30)
Trino is ready.

=== Running setup ===
=== Step 1: build the star schema ===
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/01_star_schema.sql against Trino (iceberg.iam)
CREATE SCHEMA
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE VIEW
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/01_star_schema.sql

=== Step 2: wait for Debezium's initial snapshot to land in bronze ===
(the day-1 seed has 3 rows -- waiting up to 60s for them to appear)
  bronze row count: 3
  bronze snapshot has landed.

=== Step 3: seed gold from the day-1 bronze snapshot ===
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 3 rows
MERGE: 3 rows
UPDATE: 0 rows
INSERT: 3 rows
DELETE: 0 rows
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql

=== Setup complete -- current gold row counts ===
"3"
"3"
```

> **Reading this phase:** Trino's container reports "Started" well before
> its coordinator actually accepts queries — the explicit poll loop (not
> a fixed sleep) is why setup doesn't just fail here on a slower machine.
> Six objects get created in one shot (5 tables + the
> `current_active_access` view) — schema and safe view together, per
> `TROUBLESHOOTING.md` issue #19's follow-up. Bronze reaching exactly 3
> rows confirms Debezium's initial snapshot of the clean day-1 seed
> landed correctly, and gold's `3`/`3` confirms the very first
> bronze→gold merge seeded both tables from it.

## Phase 2: Replaying the narrative — all five events, in order

### Event 1 of 5

```
############################################################
# Event: 01_revoke_carla.sql
############################################################
==> Running /home/padhu/sources/datalake-local-test/demo_events/01_revoke_carla.sql against Postgres (iam_source)
UPDATE 1
==> Done: /home/padhu/sources/datalake-local-test/demo_events/01_revoke_carla.sql
  waiting 8s for Debezium to capture and commit to bronze...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 1 row
MERGE: 1 row
UPDATE: 1 row
INSERT: 0 rows
DELETE: 1 row
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
  -- current gold state after 01_revoke_carla.sql --
"3"
"3"
```

> **Reading this event:** `fact_access_grant_history` stays at **3**, not
> 4. This is the access-period model working as intended — Carla's
> revocation `UPDATE`d one existing history row (closed it) and did
> **not** insert a new one, exactly the fix in `TROUBLESHOOTING.md`
> issue #18. (An earlier, buggy version would have shown `4` here — a
> phantom "current, but revoked" row.)

### Event 2 of 5

```
############################################################
# Event: 02_grant_alice_auditor.sql
############################################################
==> Running /home/padhu/sources/datalake-local-test/demo_events/02_grant_alice_auditor.sql against Postgres (iam_source)
INSERT 0 1
==> Done: /home/padhu/sources/datalake-local-test/demo_events/02_grant_alice_auditor.sql
  waiting 8s for Debezium to capture and commit to bronze...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 1 row
MERGE: 1 row
UPDATE: 0 rows
INSERT: 1 row
DELETE: 1 row
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
  -- current gold state after 02_grant_alice_auditor.sql --
"4"
"4"
```

> **Reading this event:** a straightforward new grant — Alice's Auditor
> access to `audit-logs`. Both gold tables grow by exactly one row
> (`3`→`4`), since this is a genuine new `grant_id` with no prior history
> to close out.

### Event 3 of 5

```
############################################################
# Event: 03_grant_contractor.sql
############################################################
==> Running /home/padhu/sources/datalake-local-test/demo_events/03_grant_contractor.sql against Postgres (iam_source)
INSERT 0 1
==> Done: /home/padhu/sources/datalake-local-test/demo_events/03_grant_contractor.sql
  waiting 8s for Debezium to capture and commit to bronze...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 1 row
MERGE: 1 row
UPDATE: 0 rows
INSERT: 1 row
DELETE: 1 row
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
  -- current gold state after 03_grant_contractor.sql --
"5"
"5"
```

> **Reading this event:** same pattern as event 2 — another genuine new
> grant (the contractor's temporary `staging-db` access), both tables
> grow by one (`4`→`5`). This grant is the one about to be hard-deleted
> in event 4, which is exactly why the narrative introduces it here
> rather than reusing an existing grant.

### Event 4 of 5

```
############################################################
# Event: 04_offboard_contractor.sql
############################################################
==> Running /home/padhu/sources/datalake-local-test/demo_events/04_offboard_contractor.sql against Postgres (iam_source)
DELETE 1
==> Done: /home/padhu/sources/datalake-local-test/demo_events/04_offboard_contractor.sql
  waiting 8s for Debezium to capture and commit to bronze...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 1 row
MERGE: 1 row
UPDATE: 1 row
INSERT: 0 rows
DELETE: 1 row
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
  -- current gold state after 04_offboard_contractor.sql --
"4"
"5"
```

> **Reading this event:** `fact_access_grant` drops from 5 to **4** (the
> contractor's row is genuinely gone — a real hard `DELETE`, not a
> soft-delete flag), while `fact_access_grant_history` **stays at 5**
> (the contractor's one history row gets closed, not duplicated — the
> same access-period behavior as event 1, this time triggered by a
> delete instead of a revocation). This is the exact hard-delete path
> `docs/images/schema_er.svg` and the source-schema section of
> `README.md` describe.

### Event 5 of 5

```
############################################################
# Event: 05_revoke_alice_and_hire_emma.sql
############################################################
==> Running /home/padhu/sources/datalake-local-test/demo_events/05_revoke_alice_and_hire_emma.sql against Postgres (iam_source)
UPDATE 1
INSERT 0 1
==> Done: /home/padhu/sources/datalake-local-test/demo_events/05_revoke_alice_and_hire_emma.sql
  waiting 8s for Debezium to capture and commit to bronze...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 2 rows
MERGE: 2 rows
UPDATE: 1 row
INSERT: 1 row
DELETE: 1 row
INSERT: 1 row
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
  -- current gold state after 05_revoke_alice_and_hire_emma.sql --
"5"
"6"

=== Narrative replay complete ===
Run scripts/02-verify.sh to check the acceptance queries and idempotency.
```

> **Reading this event:** two things happen in the same bronze batch —
> Alice's original Admin grant is revoked, and Emma is hired and granted
> access. `fact_access_grant` stays at **5** (one revoked, one added —
> net zero), while `fact_access_grant_history` grows to **6** (Alice's
> revocation closes a row with no replacement, same access-period
> pattern again; Emma's grant adds a new one). Final state: one history
> row per grant across all six grants that ever existed.

## Phase 3: Verification — where the real proof is

```
=== Verifying ===
=== Acceptance queries (Q1-Q8) ===
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/04_acceptance_queries.sql against Trino (iceberg.iam)
"1","101","1","501","2026-01-05 09:00:00.000000","","2026-01-05 09:00:00.000000","2026-03-15 10:00:00.000000","false","false"
"3","103","1","503","2026-01-07 11:30:00.000000","","2026-01-07 11:30:00.000000","2026-02-01 08:00:00.000000","false","false"
"1","101","1","501","2026-01-05 09:00:00.000000","","2026-01-05 09:00:00.000000","2026-03-15 10:00:00.000000","false","false"
"5","104","2","505","2026-02-15 08:45:00.000000","","2026-02-15 08:45:00.000000","2026-08-30 11:29:17.352000","false","true"
"5","104","2","505","2026-02-15 08:45:00.000000","","2026-02-15 08:45:00.000000","2026-08-30 11:29:17.352000","false","true"
"1","101","1","501","2026-01-05 09:00:00.000000","2026-03-15 10:00:00.000000","2026-03-15 10:00:00.000000","false"
"2","102","2","502","2026-01-06 10:15:00.000000","","2026-01-06 10:15:00.000000","false"
"3","103","1","503","2026-01-07 11:30:00.000000","2026-02-01 08:00:00.000000","2026-02-01 08:00:00.000000","false"
"4","101","3","504","2026-02-10 13:00:00.000000","","2026-02-10 13:00:00.000000","false"
"6","105","2","506","2026-03-15 11:00:00.000000","","2026-03-15 11:00:00.000000","false"
"2","102","2","502","2026-01-06 10:15:00.000000","","2026-01-06 10:15:00.000000","false"
"4","101","3","504","2026-02-10 13:00:00.000000","","2026-02-10 13:00:00.000000","false"
"6","105","2","506","2026-03-15 11:00:00.000000","","2026-03-15 11:00:00.000000","false"
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/04_acceptance_queries.sql
```

> **Reading this block:** this is the raw output of all 9 queries in
> `lakehouse-sql/04_acceptance_queries.sql` run back to back, with no
> query-boundary markers — that's just how the Trino CLI streams
> results. The row shapes tell you which query produced them: 10-column
> rows are from `fact_access_grant_history` (Q1–Q5), 8-column rows are
> from `fact_access_grant` (Q6), and the last 3 rows (also 8 columns) are
> `current_active_access` (Q6b) — correctly showing only Bob, Alice's
> Auditor grant, and Emma, with the two revoked grants and the deleted
> one filtered out.

```
=== Idempotency check ===
Before re-run: fact_access_grant=5  fact_access_grant_history=6
Re-running the merge with no new bronze events...
==> Running /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql against Trino (iceberg.iam)
CREATE TABLE
DROP TABLE
CREATE TABLE: 0 rows
MERGE: 0 rows
UPDATE: 0 rows
INSERT: 0 rows
DELETE: 1 row
INSERT: 0 rows
==> Done: /home/padhu/sources/datalake-local-test/lakehouse-sql/03_bronze_to_gold.sql
After re-run:  fact_access_grant=5  fact_access_grant_history=6
PASS: gold row counts unchanged -- merge is idempotent.

=== Duplicate current-version check (must be zero rows) ===
(no output above this line means zero rows -- correct)
```

> **Reading this block:** the merge ran a second time, found zero new
> bronze events (the watermark correctly skipped everything already
> processed), and touched nothing. Row counts before and after are
> identical. This is a genuine idempotency proof, not an assumption —
> see `scripts/02-verify.sh`.

```
=== Business-answer assertions ===
(idempotency and the duplicate-check above prove the merge is STABLE --
 this proves the ANSWERS are actually CORRECT, which is a different thing)
=== Business-answer assertions ===
PASS: Alice has exactly one active grant as of Jan 31 (expected=1 actual=1)
PASS: Carla has NO active access as of March 1 (revocation regression test) (expected=0 actual=0)
PASS: Contractor had access on Feb 20 (expected=1 actual=1)
PASS: Contractor's closed grant is correctly classified as a hard delete (is_deleted=true) (expected=1 actual=1)
PASS: No grant has more than one current history version (expected=0 actual=0)
PASS: Total history row count matches THIS DEMO SCENARIO (6: one row per grant, no phantom rows from revocations/deletes -- scenario-specific, not a generic pipeline invariant) (expected=6 actual=6)
PASS: Emma (new hire) currently has active access (expected=1 actual=1)
PASS: Bob (never touched) currently has active access (expected=1 actual=1)
PASS: current_active_access view returns exactly 3 active grants (Bob, Alice's Auditor grant, Emma) (expected=3 actual=3)

ALL ASSERTIONS PASSED

=== Full demo run complete ===
```

> **Reading this block — the actual point of the whole project:** the
> second assertion is a direct regression test for the single most
> important bug found during development (`TROUBLESHOOTING.md` #18): a
> revoked grant genuinely, provably does not show up as active a month
> later. Every other line asserts a specific, checkable business answer
> — not just "the script didn't crash." This is the difference between a
> demo that *runs* and a demo that's *correct*.

---

## Why this log is worth reading, not just the pass/fail summary

Three separate rounds of external review on this project each found a
real, distinct problem — an upsert that silently discarded history, a
revocation bug that made the core use case answer incorrectly, and an
integration miss where a fix existed but wasn't actually wired into the
path that runs. All three are visible as fixed, specific behavior in the
log above, not just claimed in prose. `TROUBLESHOOTING.md` has the full
story of each one, including what was tried and didn't work.
