-- Feb 1: Carla's Admin access to billing-api is revoked
UPDATE iam_denormalized
SET revoked_at = '2026-02-01 08:00:00', updated_at = '2026-02-01 08:00:00'
WHERE grant_id = 3;
