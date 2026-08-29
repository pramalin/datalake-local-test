-- Mar 1: the contractor is offboarded; their grant is HARD DELETED
-- (not revoked -- the row is actually removed, exactly the case a
-- batch/updated_at-filtered extract would silently miss)
DELETE FROM iam_denormalized WHERE grant_id = 5;
