-- Stand-in for the client's denormalized IAM view (~8GB in production).
-- Small sample here -- the point is to validate schema shape, not volume.
--
-- This is a genuinely clean "day 1" snapshot: every grant here is active,
-- nothing is revoked or deleted. Everything that happens after this --
-- revocations, new grants, deletions -- is demonstrated as LIVE changes
-- against this table during the demo (see demo/02_live_narrative.sql),
-- captured for real by Debezium, not pre-baked into the seed data.

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

-- Day 1: three grants, all active, dated Jan 5-7. Nothing revoked,
-- nothing deleted, no future state baked in.
INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(1, 101, 'alice.chen', 'alice.chen@client.com', 1, 'Admin',   'Privileged', 501, 'prod-db-01',    'Database', '2026-01-05 09:00', NULL, '2026-01-05 09:00', false),
(2, 102, 'bob.singh',  'bob.singh@client.com',  2, 'Analyst', 'Standard',   502, 'reporting-svc', 'Service',  '2026-01-06 10:15', NULL, '2026-01-06 10:15', false),
(3, 103, 'carla.diaz', 'carla.diaz@client.com', 1, 'Admin',   'Privileged', 503, 'billing-api',   'Service',  '2026-01-07 11:30', NULL, '2026-01-07 11:30', false);
