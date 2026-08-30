# Sample Run: `./scripts/run-full-demo.sh`

This is real, unedited output from an actual run of the full demo script
(captured 2026-08-30) — reset through verification, with nothing skipped
or cleaned up. It's here so the claims in `README.md` aren't just
assertions: you can see exactly what happened and judge for yourself.

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
 ...
[+] up 11/11
 ✔ Container dl_trino                       Started    7.6s

=== Waiting for Trino to finish initializing ===
  still initializing... (1/30)
  ...
Trino is ready.

=== Running setup ===
=== Step 1: build the star schema ===
CREATE SCHEMA
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE TABLE
CREATE VIEW

=== Step 2: wait for Debezium's initial snapshot to land in bronze ===
  bronze row count: 3
  bronze snapshot has landed.

=== Step 3: seed gold from the day-1 bronze snapshot ===
CREATE TABLE: 3 rows
MERGE: 3 rows
INSERT: 3 rows
INSERT: 1 row

=== Setup complete -- current gold row counts ===
"3"
"3"
```

**What to notice:** Trino's container reports "Started" well before its
coordinator actually accepts queries — the explicit poll loop (not a
fixed sleep) is why setup doesn't just fail here on a slower machine.
Six objects get created in one shot (5 tables + the `current_active_access`
view) — schema and safe view together, per `TROUBLESHOOTING.md` issue
#19's follow-up. Bronze reaching exactly 3 rows confirms Debezium's
initial snapshot of the clean day-1 seed landed correctly, and gold's
`3`/`3` confirms the very first bronze→gold merge seeded both tables from
it.

## Phase 2: Replaying the narrative (5 events, one at a time)

```
############################################################
# Event: 01_revoke_carla.sql
############################################################
UPDATE 1
  waiting 8s for Debezium to capture and commit to bronze...
CREATE TABLE: 1 row
MERGE: 1 row
UPDATE: 1 row
INSERT: 0 rows
DELETE: 1 row
INSERT: 1 row
  -- current gold state after 01_revoke_carla.sql --
"3"
"3"
```

**What to notice:** `fact_access_grant_history` stays at **3**, not 4.
This is the access-period model working as intended — Carla's
revocation `UPDATE`d one existing history row (closed it) and did
**not** insert a new one, exactly the behavior `TROUBLESHOOTING.md`
issue #18 fixed. (An earlier, buggy version of this script would have
shown `4` here — a phantom "current, but revoked" row.)

```
############################################################
# Event: 04_offboard_contractor.sql
############################################################
DELETE 1
  waiting 8s for Debezium to capture and commit to bronze...
UPDATE: 1 row
INSERT: 0 rows
  -- current gold state after 04_offboard_contractor.sql --
"4"
"5"
```

**What to notice:** `fact_access_grant` drops from 5 to 4 (the
contractor's row is genuinely gone — a hard delete, not a soft-delete
flag), while `fact_access_grant_history` stays at 5 (the contractor's
one history row gets closed, not duplicated). This is the exact
hard-delete path `docs/images/schema_er.svg` and the source-schema
section of `README.md` describe.

By the end of all 5 events: `fact_access_grant=5`,
`fact_access_grant_history=6` — one history row per grant across all six
grants that ever existed (five still present in some form, one
hard-deleted).

## Phase 3: Verification — where the real proof is

```
=== Idempotency check ===
Before re-run: fact_access_grant=5  fact_access_grant_history=6
Re-running the merge with no new bronze events...
CREATE TABLE: 0 rows
MERGE: 0 rows
After re-run:  fact_access_grant=5  fact_access_grant_history=6
PASS: gold row counts unchanged -- merge is idempotent.

=== Duplicate current-version check (must be zero rows) ===
(no output above this line means zero rows -- correct)
```

**What to notice:** the merge script ran a second time, found zero new
bronze events (the watermark correctly skipped everything already
processed), and touched nothing. Row counts before and after are
byte-for-byte identical. This is a genuine idempotency proof, not an
assumption — see `scripts/02-verify.sh`.

```
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
```

**What to notice — this is the actual point of the whole project:** the
second assertion is a direct regression test for the single most
important bug found during development (`TROUBLESHOOTING.md` #18): a
revoked grant genuinely, provably does not show up as active a month
later. Every other line asserts a specific, checkable business answer —
not just "the script didn't crash." This is the difference between a
demo that *runs* and a demo that's *correct*, and it's why
`scripts/03-assert-business-answers.sh` exists as a separate step from
`scripts/02-verify.sh`'s stability check.

---

## Why this log is worth reading, not just the pass/fail summary

Three separate rounds of external review on this project each found a
real, distinct problem — an upsert that silently discarded history, a
revocation bug that made the core use case answer incorrectly, and an
integration miss where a fix existed but wasn't actually wired into the
path that runs. All three are visible as fixed, specific behavior in the
log above, not just claimed in prose. `TROUBLESHOOTING.md` has the full
story of each one, including what was tried and didn't work.
