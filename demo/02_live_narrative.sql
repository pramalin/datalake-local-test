-- ============================================================
-- LIVE DEMO NARRATIVE
--
-- Run these against the direct Postgres connection (localhost:5432,
-- iam_source), ONE AT A TIME, in order. Each one is a real change,
-- captured by Debezium into bronze exactly as it happens.
--
-- After each event, re-run lakehouse-sql/03_bronze_to_gold.sql to
-- advance gold, then check the "as of" query for that date in
-- lakehouse-sql/05_acceptance_queries.sql -- the answer should
-- change exactly as expected, and answers for PAST dates should
-- never change once recorded.
--
-- Note: granted_at/revoked_at/updated_at below are set to the
-- narrative business dates. When you actually run each statement
-- does not matter -- the gold merge uses these business timestamps
-- for effective_start/effective_end, not the moment you typed the
-- command. (Debezium's own capture timestamp, __source_ts_ns, is
-- tracked separately and used only for the idempotency watermark.)
-- ============================================================

-- ------------------------------------------------------------
-- Event A -- Feb 1: Carla's Admin access to billing-api is revoked
-- ------------------------------------------------------------
UPDATE iam_denormalized
SET revoked_at = '2026-02-01 08:00:00', updated_at = '2026-02-01 08:00:00'
WHERE grant_id = 3;

-- ------------------------------------------------------------
-- Event B -- Feb 10: Alice is additionally granted Auditor access
-- to audit-logs (a second, independent grant -- her original Admin
-- access to prod-db-01 is untouched)
-- ------------------------------------------------------------
INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(4, 101, 'alice.chen', 'alice.chen@client.com', 3, 'Auditor', 'Read-Only',
 504, 'audit-logs', 'Storage', '2026-02-10 13:00:00', NULL, '2026-02-10 13:00:00', false);

-- ------------------------------------------------------------
-- Event C -- Feb 15: a contractor is granted temporary Analyst
-- access to staging-db
-- ------------------------------------------------------------
INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(5, 104, 'dev.contractor', 'dev.contractor@client.com', 2, 'Analyst', 'Standard',
 505, 'staging-db', 'Database', '2026-02-15 08:45:00', NULL, '2026-02-15 08:45:00', false);

-- ------------------------------------------------------------
-- Event D -- Mar 1: the contractor is offboarded; their grant is
-- HARD DELETED (not revoked -- the row is actually removed from
-- the source table, exactly the case a batch/updated_at-filtered
-- extract would silently miss)
-- ------------------------------------------------------------
DELETE FROM iam_denormalized WHERE grant_id = 5;

-- ------------------------------------------------------------
-- Event E -- Mar 15: Alice's original Admin access to prod-db-01
-- is revoked (role change), and a new hire, Emma, is granted
-- Analyst access to ml-pipeline
-- ------------------------------------------------------------
UPDATE iam_denormalized
SET revoked_at = '2026-03-15 10:00:00', updated_at = '2026-03-15 10:00:00'
WHERE grant_id = 1;

INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(6, 105, 'emma.wong', 'emma.wong@client.com', 2, 'Analyst', 'Standard',
 506, 'ml-pipeline', 'Service', '2026-03-15 11:00:00', NULL, '2026-03-15 11:00:00', false);
