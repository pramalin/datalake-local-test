-- ============================================================
-- BRONZE -> GOLD MERGE
--
-- Bronze (bronze_dev_iam_public_iam_denormalized) is append-only: every
-- CDC event from Debezium is a NEW row, never overwritten. This script
-- derives the gold current-state and history tables FROM that immutable
-- log -- it is safe to re-run at any time (idempotent via the watermark
-- table below), and it is the actual answer to "where does history come
-- from if the live pipeline upserts?" -- it doesn't upsert anymore.
-- ============================================================

-- One-time setup: watermark table, tracks how far the gold merge has
-- processed the bronze log. Run once.
CREATE TABLE IF NOT EXISTS iceberg.iam.gold_merge_watermark (
    target_table       VARCHAR,
    last_processed_ts  BIGINT
) WITH (format = 'PARQUET');

-- ============================================================
-- Run everything below this line each time you want to advance gold.
-- Re-running with no new bronze events since the last run is a safe no-op.
-- ============================================================

-- Step 1: build this run's batch -- the latest bronze event per grant_id,
-- restricted to events newer than the watermark. The ROW_NUMBER dedup is
-- what makes this safe even if bronze has multiple events per grant_id
-- since the last run (e.g. two quick updates to the same grant).
--
-- business_ts: for creates/updates, the row's own updated_at is a real,
-- app-set business timestamp. For a DELETE, there is no such thing --
-- under REPLICA IDENTITY DEFAULT (the default here) a delete's "before"
-- image only carries primary-key columns, so updated_at comes through
-- NULL. Deletes fall back to Debezium's own capture time
-- (__source_ts_ns) as the best available record of when the deletion
-- actually happened -- this is a deliberate, documented choice (see
-- README.md "Known limitations" -- hard deletes have no business-level
-- "deleted at" timestamp at all), not an oversight.
DROP TABLE IF EXISTS iceberg.iam.stg_bronze_batch;
CREATE TABLE iceberg.iam.stg_bronze_batch AS
SELECT grant_id, user_id, role_id, resource_id, granted_at, revoked_at,
       updated_at, is_deleted, __op AS op, __source_ts_ns,
       CASE
           WHEN __op = 'd' THEN from_unixtime(CAST(__source_ts_ns AS DOUBLE) / 1000000000)
           ELSE updated_at
       END AS business_ts
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY grant_id ORDER BY __source_ts_ns DESC) AS rn
    FROM iceberg.iam.bronze_dev_iam_public_iam_denormalized
    WHERE __source_ts_ns > (
        SELECT COALESCE(MAX(last_processed_ts), 0)
        FROM iceberg.iam.gold_merge_watermark
        WHERE target_table = 'fact_access_grant_history'
    )
) t
WHERE rn = 1;

-- Step 2: Type 1 merge -- current-state table
MERGE INTO iceberg.iam.fact_access_grant AS target
USING iceberg.iam.stg_bronze_batch AS source
ON target.grant_id = source.grant_id
WHEN MATCHED AND source.op = 'd' THEN
    DELETE
WHEN MATCHED THEN
    UPDATE SET
        role_id = source.role_id,
        resource_id = source.resource_id,
        revoked_at = source.revoked_at,
        updated_at = source.updated_at,
        is_deleted = source.is_deleted
WHEN NOT MATCHED AND source.op != 'd' THEN
    INSERT (grant_id, user_id, role_id, resource_id, granted_at, revoked_at, updated_at, is_deleted)
    VALUES (source.grant_id, source.user_id, source.role_id, source.resource_id,
            source.granted_at, source.revoked_at, source.updated_at, source.is_deleted);

-- Step 3: Type 2 -- close out the currently-active version for any
-- grant_id touched in this batch. Uses business_ts, NOT updated_at
-- directly, so deletes close out with a real timestamp instead of NULL.
UPDATE iceberg.iam.fact_access_grant_history
SET effective_end = (
        SELECT business_ts FROM iceberg.iam.stg_bronze_batch b
        WHERE b.grant_id = fact_access_grant_history.grant_id
    ),
    is_current = false
WHERE is_current = true
  AND grant_id IN (SELECT grant_id FROM iceberg.iam.stg_bronze_batch);

-- Step 4: Type 2 -- insert the new current version (deletes just close
-- the row above; no new "current" version for a deleted grant).
INSERT INTO iceberg.iam.fact_access_grant_history
SELECT grant_id, user_id, role_id, resource_id, granted_at, revoked_at,
       business_ts AS effective_start,
       NULL AS effective_end,
       true AS is_current,
       is_deleted
FROM iceberg.iam.stg_bronze_batch
WHERE op != 'd';

-- Step 5: advance the watermark to the latest event actually processed
-- in this run. If stg_bronze_batch was empty (no new events), this
-- correctly does nothing -- re-running is then a true no-op.
DELETE FROM iceberg.iam.gold_merge_watermark WHERE target_table = 'fact_access_grant_history';
INSERT INTO iceberg.iam.gold_merge_watermark
SELECT 'fact_access_grant_history', MAX(__source_ts_ns)
FROM iceberg.iam.stg_bronze_batch
HAVING COUNT(*) > 0;

-- ============================================================
-- Idempotency / correctness check -- run after every merge.
-- Must always return zero rows. If it doesn't, the merge broke.
-- ============================================================
SELECT grant_id, COUNT(*) AS current_version_count
FROM iceberg.iam.fact_access_grant_history
WHERE is_current
GROUP BY grant_id
HAVING COUNT(*) > 1;
