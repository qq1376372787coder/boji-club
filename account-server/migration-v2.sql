CREATE TABLE IF NOT EXISTS membership_admin_grants (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 status ENUM('active','revoked') NOT NULL DEFAULT 'active',
 starts_at DATETIME NOT NULL,
 expires_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT membership_grants_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO membership_admin_grants(user_id,status,starts_at,expires_at,updated_at)
 SELECT user_id,IF(status='active','active','revoked'),starts_at,expires_at,UTC_TIMESTAMP()
 FROM membership_entitlements WHERE source='admin';

ALTER TABLE club_reward_claims ADD COLUMN IF NOT EXISTS shipped_at DATETIME NULL;
UPDATE club_reward_claims SET shipped_at=updated_at WHERE shipped_at IS NULL AND (status IN ('shipped','delivered') OR COALESCE(tracking_number,'')<>'');

CREATE TABLE IF NOT EXISTS account_deletions (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NULL UNIQUE,
 token_hash CHAR(64) NOT NULL UNIQUE,
 status ENUM('queued','retrying','completed') NOT NULL,
 job_ids MEDIUMTEXT NOT NULL,
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 last_error_code VARCHAR(40) NULL,
 next_attempt DATETIME NOT NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 INDEX account_deletions_due(status,next_attempt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS apple_tokens (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 client_id VARCHAR(191) NOT NULL,
 token_cipher TEXT NOT NULL,
 checked_at DATETIME NOT NULL,
 CONSTRAINT apple_tokens_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
