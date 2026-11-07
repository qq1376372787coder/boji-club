CREATE TABLE IF NOT EXISTS club_push_devices (
 device_id CHAR(36) PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 session_hash CHAR(64) NOT NULL,
 token TEXT NOT NULL,
 environment ENUM('development','production') NOT NULL,
 enabled TINYINT(1) NOT NULL,
 preferences_json TEXT NOT NULL,
 notify_after DATETIME NOT NULL,
 next_check DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX club_push_due(enabled,next_check), INDEX club_push_owner(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS club_push_receipts (
 device_id CHAR(36) NOT NULL,
 client_job_id CHAR(36) NOT NULL,
 status ENUM('pending','sent','failed','skipped') NOT NULL DEFAULT 'pending',
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 next_attempt DATETIME NOT NULL,
 reason VARCHAR(100) NULL,
 updated_at DATETIME NOT NULL,
 PRIMARY KEY(device_id,client_job_id),
 FOREIGN KEY(device_id) REFERENCES club_push_devices(device_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
