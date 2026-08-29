-- Run these via the Trino CLI or any SQL client connected to Trino (localhost:8080).
-- Catalog: iceberg | Schema: iam

CREATE SCHEMA IF NOT EXISTS iceberg.iam;

-- ============================================================
-- DIMENSIONS (flattened — star schema, not snowflake schema)
-- ============================================================

CREATE TABLE IF NOT EXISTS iceberg.iam.dim_user (
    user_id     BIGINT,
    user_name   VARCHAR,
    user_email  VARCHAR
) WITH (format = 'PARQUET');

CREATE TABLE IF NOT EXISTS iceberg.iam.dim_role (
    role_id        BIGINT,
    role_name      VARCHAR,
    role_category  VARCHAR
) WITH (format = 'PARQUET');

CREATE TABLE IF NOT EXISTS iceberg.iam.dim_resource (
    resource_id    BIGINT,
    resource_name  VARCHAR,
    resource_type  VARCHAR
) WITH (format = 'PARQUET');

-- ============================================================
-- FACT TABLE — Type 1 (current state, one row per grant)
-- ============================================================

CREATE TABLE IF NOT EXISTS iceberg.iam.fact_access_grant (
    grant_id     BIGINT,
    user_id      BIGINT,
    role_id      BIGINT,
    resource_id  BIGINT,
    granted_at   TIMESTAMP,
    revoked_at   TIMESTAMP,
    updated_at   TIMESTAMP,
    is_deleted   BOOLEAN
) WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(updated_at)']   -- clustering-key equivalent for pruning
);

-- ============================================================
-- HISTORY TABLE — Type 2 (effective-dated, full audit trail)
-- ============================================================

CREATE TABLE IF NOT EXISTS iceberg.iam.fact_access_grant_history (
    grant_id       BIGINT,
    user_id        BIGINT,
    role_id        BIGINT,
    resource_id    BIGINT,
    granted_at     TIMESTAMP,
    revoked_at     TIMESTAMP,
    effective_start TIMESTAMP,
    effective_end   TIMESTAMP,     -- NULL = currently active version
    is_current      BOOLEAN,
    is_deleted      BOOLEAN
) WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(effective_start)']
);
