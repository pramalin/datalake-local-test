-- These simulate what your daily merge job will do once real CDC/S3 delta
-- files are landing. Point a Postgres connector at the source DB (see
-- trino/catalog/postgres.properties) or load the delta via CSV/CTAS --
-- either way, the MERGE logic below is what matters for schema validation.

-- ------------------------------------------------------------
-- Example: assume the day-2 delta has been loaded into a staging
-- table iceberg.iam.stg_delta with the same shape as
-- iam_denormalized_day2_delta from Postgres.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS iceberg.iam.stg_delta (
    grant_id       BIGINT,
    user_id        BIGINT,
    user_name      VARCHAR,
    user_email     VARCHAR,
    role_id        BIGINT,
    role_name      VARCHAR,
    role_category  VARCHAR,
    resource_id    BIGINT,
    resource_name  VARCHAR,
    resource_type  VARCHAR,
    granted_at     TIMESTAMP,
    revoked_at     TIMESTAMP,
    updated_at     TIMESTAMP,
    is_deleted     BOOLEAN,
    op             VARCHAR
) WITH (format = 'PARQUET');

-- Load it directly from Postgres via the postgres catalog (see setup below),
-- or INSERT VALUES manually to mirror 01_schema.sql's day-2 delta rows.

-- ============================================================
-- TYPE 1 MERGE -- current-state fact table (overwrite on change)
-- ============================================================

MERGE INTO iceberg.iam.fact_access_grant AS target
USING iceberg.iam.stg_delta AS source
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

-- ============================================================
-- TYPE 2 MERGE -- history table (close old version, insert new version)
-- Two-step pattern: Iceberg MERGE can't easily "insert + update" the same
-- logical row in one statement, so this is done as two statements.
-- ============================================================

-- Step 1: close out the currently-active version for any grant_id present in the delta
UPDATE iceberg.iam.fact_access_grant_history
SET effective_end = (SELECT updated_at FROM iceberg.iam.stg_delta d WHERE d.grant_id = fact_access_grant_history.grant_id),
    is_current = false
WHERE is_current = true
  AND grant_id IN (SELECT grant_id FROM iceberg.iam.stg_delta);

-- Step 2: insert the new version as the current row
INSERT INTO iceberg.iam.fact_access_grant_history
SELECT
    grant_id,
    user_id,
    role_id,
    resource_id,
    granted_at,
    revoked_at,
    updated_at AS effective_start,
    NULL AS effective_end,
    true AS is_current,
    is_deleted
FROM iceberg.iam.stg_delta
WHERE op != 'd';   -- deletes just close the row above; no new "current" version

-- ============================================================
-- Sanity checks
-- ============================================================

-- Current state should show Alice's Admin grant revoked, contractor's grant gone, Emma added
SELECT * FROM iceberg.iam.fact_access_grant ORDER BY grant_id;

-- History should show 2 rows for grant_id 1 (Admin), one closed, one... actually revoked closes it too
SELECT * FROM iceberg.iam.fact_access_grant_history WHERE grant_id = 1 ORDER BY effective_start;

-- "As of" query -- what access existed before the day-2 delta was applied
SELECT * FROM iceberg.iam.fact_access_grant_history
WHERE effective_start <= TIMESTAMP '2026-02-01 00:00:00'
  AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-02-01 00:00:00');
