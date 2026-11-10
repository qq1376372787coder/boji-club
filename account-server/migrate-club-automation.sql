CREATE TABLE IF NOT EXISTS club_automation (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
 enabled TINYINT(1) NOT NULL DEFAULT 0,
 preferences_json MEDIUMTEXT NOT NULL,
 coverage_json MEDIUMTEXT NOT NULL,
 cloud_revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
 next_run DATETIME NOT NULL,
 last_status VARCHAR(100) NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT club_automation_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX club_automation_due(enabled,next_run)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
