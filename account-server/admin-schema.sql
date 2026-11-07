CREATE TABLE IF NOT EXISTS admin_accounts (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 username VARCHAR(60) NOT NULL UNIQUE,
 password_hash VARCHAR(255) NOT NULL,
 role ENUM('super_admin','operator','content','support','readonly') NOT NULL DEFAULT 'readonly',
 status ENUM('active','disabled') NOT NULL DEFAULT 'active',
 session_version INT NOT NULL DEFAULT 1,
 created_at DATETIME NOT NULL,
 last_login_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS admin_login_limits (
 bucket CHAR(64) PRIMARY KEY,
 attempts INT NOT NULL DEFAULT 0,
 window_start DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS admin_audit (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 admin_id BIGINT UNSIGNED NULL,
 action VARCHAR(40) NOT NULL,
 target_user_id BIGINT UNSIGNED NULL,
 detail VARCHAR(500) NOT NULL DEFAULT '',
 ip VARCHAR(64) NOT NULL,
 created_at DATETIME NOT NULL,
 INDEX(created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_admin_profiles (
 user_id BIGINT UNSIGNED PRIMARY KEY,
 tags_json TEXT NOT NULL,
 updated_by BIGINT UNSIGNED NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT member_admin_profiles_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_admin_notes (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 admin_id BIGINT UNSIGNED NOT NULL,
 note VARCHAR(1000) NOT NULL,
 created_at DATETIME NOT NULL,
 INDEX(user_id,created_at),
 CONSTRAINT member_admin_notes_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
