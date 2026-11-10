CREATE TABLE IF NOT EXISTS app_config (
    config_key VARCHAR(64) PRIMARY KEY,
    draft_json TEXT NOT NULL,
    published_json TEXT NULL,
    draft_version INT UNSIGNED NOT NULL DEFAULT 0,
    published_version INT UNSIGNED NOT NULL DEFAULT 0,
    updated_by BIGINT UNSIGNED NULL,
    updated_at DATETIME NOT NULL,
    published_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS app_config_versions (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    config_key VARCHAR(64) NOT NULL,
    version INT UNSIGNED NOT NULL,
    value_json TEXT NOT NULL,
    action ENUM('draft','publish','rollback') NOT NULL,
    admin_id BIGINT UNSIGNED NULL,
    note VARCHAR(300) NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL,
    INDEX app_config_versions_key (config_key,version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
