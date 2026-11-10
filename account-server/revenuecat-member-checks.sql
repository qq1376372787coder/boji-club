CREATE TABLE IF NOT EXISTS revenuecat_member_checks (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 observed_at_ms BIGINT UNSIGNED NULL,
 verified_at DATETIME NULL,
 verified_status ENUM('active','inactive') NULL,
 product_id VARCHAR(191) NOT NULL DEFAULT '',
 starts_at DATETIME NULL,
 expires_at DATETIME NULL,
 purchase_id VARCHAR(255) NULL,
 attempt_token CHAR(32) NULL,
 attempt_started_at DATETIME NULL,
 last_attempt_at DATETIME NULL,
 next_attempt_at DATETIME NULL,
 last_error_code VARCHAR(40) NULL,
 CONSTRAINT rc_member_checks_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
