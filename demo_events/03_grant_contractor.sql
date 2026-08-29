-- Feb 15: a contractor is granted temporary Analyst access to staging-db
INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(5, 104, 'dev.contractor', 'dev.contractor@client.com', 2, 'Analyst', 'Standard',
 505, 'staging-db', 'Database', '2026-02-15 08:45:00', NULL, '2026-02-15 08:45:00', false);
