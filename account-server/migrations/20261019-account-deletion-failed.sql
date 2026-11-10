-- B1 P1 partial: allow the deletion worker to stop after ten failed rounds
-- and require an admin decision instead of retrying forever every 24 hours.
ALTER TABLE account_deletions
    MODIFY status ENUM('queued','retrying','completed','failed') NOT NULL;
