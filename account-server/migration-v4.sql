CREATE TABLE IF NOT EXISTS media_cleanup_queue (
 user_id BIGINT UNSIGNED NOT NULL,
 media_id CHAR(40) NOT NULL,
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 next_attempt DATETIME NOT NULL,
 created_at DATETIME NOT NULL,
 last_error_code VARCHAR(40) NULL,
 PRIMARY KEY(user_id,media_id),
 INDEX media_cleanup_due(next_attempt),
 CONSTRAINT media_cleanup_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Existing tombstones may represent uncleaned files. Already missing files are harmless.
INSERT IGNORE INTO media_cleanup_queue(user_id,media_id,next_attempt,created_at)
 SELECT d.user_id,d.media_id,UTC_TIMESTAMP(),UTC_TIMESTAMP()
 FROM deleted_media d JOIN users u ON u.id=d.user_id;
