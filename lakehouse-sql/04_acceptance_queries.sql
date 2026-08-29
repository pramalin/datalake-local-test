-- ============================================================
-- ACCEPTANCE QUERIES
--
-- Run these against Trino, after replaying some or all of
-- demo_events/*.sql (with a bronze-to-gold merge after each event --
-- see scripts/01-replay-narrative.sh). Each answers a specific business
-- question a regulated-industry auditor might actually ask. Expected
-- answers are noted assuming ALL five narrative events have been
-- applied and merged.
--
-- fact_access_grant_history uses the ACCESS-PERIOD model: a row exists
-- for as long as access was actually granted. A revocation or hard
-- delete CLOSES a row (sets effective_end) and does NOT open a new
-- "current" row -- so a revoked or deleted grant never appears as
-- active in an "as of" query after its close date. (An earlier version
-- of this script got this wrong -- see TROUBLESHOOTING.md issue #18.)
-- ============================================================

-- Q1: What active access did Alice have at January 31, 23:59 -- i.e.
-- before ANY of the narrative events happened?
-- Expected: grant_id 1 (Admin, prod-db-01) only. Grant 4 (Auditor,
-- audit-logs) doesn't exist yet -- it isn't granted until Feb 10.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE user_id = 101
  AND effective_start <= TIMESTAMP '2026-01-31 23:59:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-01-31 23:59:00');

-- Q2: What changed on February 1?
-- Expected: ONE row -- Carla's Admin access to billing-api (grant_id 3)
-- closed with effective_end = Feb 1. Under the access-period model, a
-- revocation does not open a second "new version" row, so only the
-- closed row appears here (not two).
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE effective_end = TIMESTAMP '2026-02-01 08:00:00';

-- Q3: Who had access to prod-db-01 on February 15?
-- Expected: Alice (grant_id 1, Admin) -- not yet revoked; that happens
-- March 15.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE resource_id = 501
  AND effective_start <= TIMESTAMP '2026-02-15 00:00:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-02-15 00:00:00');

-- Q4: When was the contractor's staging-db grant revoked/removed, and how?
-- Expected: ONE row, is_deleted = true, is_current = false. effective_end
-- will be close to whenever you actually ran the demo, NOT March 1 --
-- hard deletes carry no business-level "deleted at" timestamp (Postgres
-- never sends one), so this correctly uses Debezium's capture time
-- instead. This is a documented, deliberate tradeoff (README.md "Known
-- limitations"), not a bug -- do not expect an exact March 1 date here.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE user_id = 104 AND resource_id = 505
ORDER BY effective_start;

-- Q5: Did the contractor's access exist on February 20 -- i.e. between
-- being granted (Feb 15) and being removed (Mar 1)?
-- Expected: yes, one row returned.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE user_id = 104
  AND effective_start <= TIMESTAMP '2026-02-20 00:00:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-02-20 00:00:00');

-- Q6: What is the CURRENT access state (today), independent of history?
-- Expected: a RAW mirror of the source table's current rows -- includes
-- grants 1 and 3 even though they're revoked (revoked_at is populated
-- on those rows). This table is NOT pre-filtered to "active access
-- only" -- callers asking "who currently has access" must filter
-- revoked_at IS NULL AND is_deleted = false, same convention as the
-- history table's access-period rows. Grant 5 (contractor) is absent
-- entirely (hard deleted, so no row exists here at all).
SELECT * FROM iceberg.iam.fact_access_grant ORDER BY grant_id;

-- Q6b: the same thing, but safely -- current_active_access (created in
-- 01_star_schema.sql, alongside the tables it depends on, not here --
-- it's a reusable model object, not a one-off acceptance query) applies
-- that filter for you.
SELECT * FROM iceberg.iam.current_active_access ORDER BY grant_id;

-- Q7: Does replaying the bronze-to-gold merge with no new events change
-- any of the above answers?
-- Expected: no -- re-run lakehouse-sql/03_bronze_to_gold.sql again and
-- re-run any of Q1-Q6; results must be identical. Checked automatically
-- by scripts/02-verify.sh, not just by eye.

-- Q8: Can any grant have more than one CURRENT history version at once?
-- Expected: zero rows, always. This is the idempotency/correctness
-- guard from README.md section 5.
SELECT grant_id, COUNT(*) AS current_version_count
FROM iceberg.iam.fact_access_grant_history
WHERE is_current
GROUP BY grant_id
HAVING COUNT(*) > 1;

-- Q9: DIRECT REGRESSION TEST for the revocation bug found by external
-- review -- does Carla still show as having active access to
-- billing-api as of March 1, a full month after her Feb 1 revocation?
-- Expected: ZERO rows. If this returns a row, the revocation-as-close
-- fix has regressed.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE user_id = 103 AND resource_id = 503
  AND effective_start <= TIMESTAMP '2026-03-01 00:00:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-03-01 00:00:00');
