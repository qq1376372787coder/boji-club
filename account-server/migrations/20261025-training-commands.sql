-- Phase 1: unified Domain Commands for the training lifecycle + direct records.
-- Expand-only: old clients never read these structures; DROP TABLE / DROP COLUMN
-- is a safe rollback (commands.php rejects the new types when the table is gone).
--
-- 1. Single active workout session invariant (DB level, P0-2 / E2E #1).
--    One row per user; the start command claims it inside the account command
--    transaction, the finish command releases it. Legacy full-state syncs
--    backfill or respect it instead of silently creating a second session.
CREATE TABLE IF NOT EXISTS active_workout_sessions (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 session_id CHAR(36) NOT NULL,
 date_key CHAR(10) NOT NULL,
 started_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT active_workout_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. Semantic idempotency for proposal-free direct commands: the client sends a
--    stable idempotency_key per user intent; the same key must always map to
--    the same payload. Existing rows keep NULL (MySQL/MariaDB allow repeats).
ALTER TABLE data_operations ADD COLUMN IF NOT EXISTS idempotency_key CHAR(64) NULL AFTER payload_hash;
ALTER TABLE data_operations ADD UNIQUE KEY IF NOT EXISTS data_ops_idem (user_id, idempotency_key);
