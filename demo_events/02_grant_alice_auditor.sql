-- Feb 10: Alice is additionally granted Auditor access to audit-logs
INSERT INTO iam_denormalized
(grant_id, user_id, user_name, user_email, role_id, role_name, role_category,
 resource_id, resource_name, resource_type, granted_at, revoked_at, updated_at, is_deleted)
VALUES
(4, 101, 'alice.chen', 'alice.chen@client.com', 3, 'Auditor', 'Read-Only',
 504, 'audit-logs', 'Storage', '2026-02-10 13:00:00', NULL, '2026-02-10 13:00:00', false);
