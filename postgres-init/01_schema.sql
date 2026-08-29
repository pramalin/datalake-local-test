-- Stand-in for the client's denormalized IAM view (~8GB in production).
-- Small sample here -- the point is to validate schema shape, not volume.

CREATE TABLE IF NOT EXISTS iam_denormalized (
    grant_id        BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL,
    user_name       TEXT NOT NULL,
    user_email      TEXT NOT NULL,
    role_id         BIGINT NOT NULL,
    role_name       TEXT NOT NULL,
    role_category   TEXT,
    resource_id     BIGINT NOT NULL,
    resource_name   TEXT NOT NULL,
    resource_type   TEXT,
    granted_at      TIMESTAMP NOT NULL,
    revoked_at      TIMESTAMP,              -- NULL = still active
    updated_at      TIMESTAMP NOT NULL DEFAULT now(),
    is_deleted      BOOLEAN NOT NULL DEFAULT false
);

INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(1, 101, 'alice.chen',  'alice.chen@client.com',  1, 'Admin',    'Privileged', 501, 'prod-db-01',   'Database', '2026-01-05 09:00', NULL, '2026-01-05 09:00', false),
(2, 102, 'bob.singh',   'bob.singh@client.com',   2, 'Analyst',  'Standard',   502, 'reporting-svc','Service',  '2026-01-06 10:15', NULL, '2026-01-06 10:15', false),
(3, 103, 'carla.diaz',  'carla.diaz@client.com',  1, 'Admin',    'Privileged', 503, 'billing-api',  'Service',  '2026-01-07 11:30', '2026-02-01 08:00', '2026-02-01 08:00', false),
(4, 101, 'alice.chen',  'alice.chen@client.com',  3, 'Auditor',  'Read-Only',  504, 'audit-logs',   'Storage',  '2026-02-10 13:00', NULL, '2026-02-10 13:00', false),
(5, 104, 'dev.contractor','dev.contractor@client.com', 2, 'Analyst','Standard', 505, 'staging-db',  'Database', '2026-02-15 08:45', NULL, '2026-03-01 09:20', true); -- hard-delete simulation

-- A second table showing a *later* state, to simulate "day 2" deltas you can
-- merge into the lakehouse to test Type 1 / Type 2 SCD logic.
CREATE TABLE IF NOT EXISTS iam_denormalized_day2_delta (
    grant_id        BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL,
    user_name       TEXT NOT NULL,
    user_email      TEXT NOT NULL,
    role_id         BIGINT NOT NULL,
    role_name       TEXT NOT NULL,
    role_category   TEXT,
    resource_id     BIGINT NOT NULL,
    resource_name   TEXT NOT NULL,
    resource_type   TEXT,
    granted_at      TIMESTAMP NOT NULL,
    revoked_at      TIMESTAMP,
    updated_at      TIMESTAMP NOT NULL,
    is_deleted      BOOLEAN NOT NULL DEFAULT false,
    op              CHAR(1) NOT NULL  -- 'c'=create, 'u'=update, 'd'=delete -- mimics a Debezium event flag
);

INSERT INTO iam_denormalized_day2_delta
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted, op)
VALUES
-- Alice's Admin role gets revoked (update)
(1, 101, 'alice.chen', 'alice.chen@client.com', 1, 'Admin', 'Privileged', 501, 'prod-db-01', 'Database', '2026-01-05 09:00', '2026-03-15 10:00', '2026-03-15 10:00', false, 'u'),
-- A brand new grant (create)
(6, 105, 'emma.wong', 'emma.wong@client.com', 2, 'Analyst', 'Standard', 506, 'ml-pipeline', 'Service', '2026-03-15 11:00', NULL, '2026-03-15 11:00', false, 'c'),
-- The contractor's staging-db grant is now hard-deleted (delete)
(5, 104, 'dev.contractor', 'dev.contractor@client.com', 2, 'Analyst', 'Standard', 505, 'staging-db', 'Database', '2026-02-15 08:45', NULL, '2026-03-15 12:00', true, 'd');
