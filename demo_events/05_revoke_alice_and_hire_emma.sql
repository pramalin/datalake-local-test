-- Mar 15: Alice's original Admin access to prod-db-01 is revoked
-- (role change), and a new hire, Emma, is granted Analyst access
-- to ml-pipeline
UPDATE iam_denormalized
SET revoked_at = '2026-03-15 10:00:00', updated_at = '2026-03-15 10:00:00'
WHERE grant_id = 1;

INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(6, 105, 'emma.wong', 'emma.wong@client.com', 2, 'Analyst', 'Standard',
 506, 'ml-pipeline', 'Service', '2026-03-15 11:00:00', NULL, '2026-03-15 11:00:00', false);
