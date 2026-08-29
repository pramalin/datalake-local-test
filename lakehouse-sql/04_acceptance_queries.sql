-- ============================================================
-- ACCEPTANCE QUERIES
--
-- Run these against Trino, after replaying some or all of
-- demo/02_live_narrative.sql (with a bronze-to-gold merge after each
-- event). Each answers a specific business question a regulated-industry
-- auditor might actually ask. Expected answers are noted assuming ALL
-- five narrative events have been applied and merged.
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
-- Expected: Carla's Admin access to billing-api (grant_id 3) was revoked.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE effective_start = TIMESTAMP '2026-02-01 08:00:00'
   OR effective_end   = TIMESTAMP '2026-02-01 08:00:00';

-- Q3: Who had access to prod-db-01 on February 15?
-- Expected: Alice (grant_id 1, Admin) -- not yet revoked; that happens
-- March 15.
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE resource_id = 501
  AND effective_start <= TIMESTAMP '2026-02-15 00:00:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-02-15 00:00:00');

-- Q4: When was the contractor's staging-db grant revoked/removed, and how?
-- Expected: effective_end = 2026-03-01, and is_deleted = true on the
-- closed-out version -- this was a hard delete (offboarding), not a
-- normal revocation, and the history correctly distinguishes it.
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
-- Expected: grant_id 2 (Bob), grant_id 4 (Alice, Auditor), grant_id 6
-- (Emma) are active. Grant 1 (Alice, Admin) shows revoked_at set.
-- Grant 3 (Carla) shows revoked_at set. Grant 5 (contractor) is gone
-- entirely (hard deleted).
SELECT * FROM iceberg.iam.fact_access_grant ORDER BY grant_id;

-- Q7: Does replaying the bronze-to-gold merge with no new events change
-- any of the above answers?
-- Expected: no -- re-run lakehouse-sql/03_bronze_to_gold.sql again and
-- re-run any of Q1-Q6; results must be identical. (Already validated
-- directly during this session -- see TROUBLESHOOTING.md.)

-- Q8: Can any grant have more than one CURRENT history version at once?
-- Expected: zero rows, always. This is the idempotency/correctness
-- guard from README.md section 5.
SELECT grant_id, COUNT(*) AS current_version_count
FROM iceberg.iam.fact_access_grant_history
WHERE is_current
GROUP BY grant_id
HAVING COUNT(*) > 1;
