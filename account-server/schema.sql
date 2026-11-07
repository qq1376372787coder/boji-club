CREATE TABLE IF NOT EXISTS users (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    phone VARCHAR(20) NULL UNIQUE,
    apple_subject VARCHAR(255) NULL UNIQUE,
    status ENUM('active','disabled','deleted') NOT NULL DEFAULT 'active',
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Existing test phone accounts remain usable; new members can use Apple ID only.

CREATE TABLE IF NOT EXISTS verification_codes (
    phone VARCHAR(20) NOT NULL PRIMARY KEY,
    code_hash CHAR(64) NOT NULL,
    expires_at DATETIME NOT NULL,
    attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
    requested_at DATETIME NOT NULL,
    request_day DATE NOT NULL,
    request_count SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    request_ip VARCHAR(64) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    token_hash CHAR(64) NOT NULL UNIQUE,
    created_at DATETIME NOT NULL,
    last_used_at DATETIME NOT NULL,
    expires_at DATETIME NOT NULL,
    INDEX sessions_user_id (user_id),
    INDEX sessions_expires_at (expires_at),
    CONSTRAINT sessions_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_user_jobs (
    user_id BIGINT UNSIGNED NOT NULL,
    client_job_id CHAR(36) NOT NULL,
    server_job_id CHAR(36) NOT NULL UNIQUE,
    kind ENUM('generate_plan','parse_plan','food','report','weekly_review','coach') NOT NULL,
    completed_at DATETIME NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (user_id, client_job_id),
    INDEX ai_user_jobs_daily (user_id, created_at),
    CONSTRAINT ai_user_jobs_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_user_usage (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    client_job_id CHAR(36) NOT NULL,
    action ENUM('create','retry') NOT NULL,
    created_at DATETIME NOT NULL,
    INDEX ai_user_usage_daily (user_id, created_at),
    CONSTRAINT ai_user_usage_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS membership_entitlements (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    status ENUM('active','expired','revoked') NOT NULL DEFAULT 'active',
    source ENUM('apple','admin') NOT NULL,
    plan_code VARCHAR(60) NOT NULL DEFAULT 'annual',
    starts_at DATETIME NOT NULL,
    expires_at DATETIME NOT NULL,
    last_transaction_id VARCHAR(255) NULL,
    INDEX membership_entitlements_transaction (last_transaction_id),
    updated_by BIGINT UNSIGNED NULL,
    operator_note VARCHAR(500) NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT membership_entitlements_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX membership_entitlements_status (status, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS membership_adjustments (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    admin_id BIGINT UNSIGNED NOT NULL,
    action ENUM('grant','extend','revoke') NOT NULL,
    previous_status VARCHAR(20) NULL,
    previous_expires_at DATETIME NULL,
    next_status VARCHAR(20) NOT NULL,
    next_expires_at DATETIME NULL,
    reason VARCHAR(200) NOT NULL,
    created_at DATETIME NOT NULL,
    CONSTRAINT membership_adjustments_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX membership_adjustments_user (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS profiles (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    nickname VARCHAR(30) NOT NULL,
    gender VARCHAR(10) NOT NULL,
    age TINYINT UNSIGNED NOT NULL,
    height_cm DECIMAL(5,1) NOT NULL,
    weight_kg DECIMAL(5,1) NOT NULL,
    goal VARCHAR(30) NOT NULL,
    experience VARCHAR(20) NOT NULL,
    venue VARCHAR(20) NOT NULL,
    days_per_week TINYINT UNSIGNED NOT NULL,
    focus VARCHAR(100) NOT NULL DEFAULT '',
    equipment VARCHAR(200) NOT NULL DEFAULT '',
    equipment_other VARCHAR(200) NOT NULL DEFAULT '',
    session_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 45,
    limitations VARCHAR(500) NOT NULL DEFAULT '',
    training_days VARCHAR(50) NOT NULL DEFAULT '',
    home_training_days VARCHAR(50) NOT NULL DEFAULT '',
    updated_at DATETIME NOT NULL,
    CONSTRAINT profiles_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



CREATE TABLE IF NOT EXISTS onboarding (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    plan_mode ENUM('generate_plan','parse_plan') NOT NULL,
    covenant_version VARCHAR(30) NOT NULL,
    started_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    completed_at DATETIME NULL,
    CONSTRAINT onboarding_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS app_states (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    state_json MEDIUMTEXT NOT NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT app_states_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_media (
    user_id BIGINT UNSIGNED NOT NULL,
    media_id VARCHAR(80) NOT NULL,
    byte_size INT UNSIGNED NOT NULL,
    content_type VARCHAR(40) NOT NULL,
    version_file VARCHAR(140) NULL,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    PRIMARY KEY (user_id, media_id),
    CONSTRAINT user_media_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_seasons (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    slug VARCHAR(60) NOT NULL UNIQUE,
    title VARCHAR(80) NOT NULL,
    subtitle VARCHAR(160) NOT NULL DEFAULT '',
    official_note TEXT NOT NULL,
    rules_text TEXT NOT NULL,
    starts_on DATE NOT NULL,
    ends_on DATE NOT NULL,
    join_deadline DATE NOT NULL,
    status ENUM('draft','published','archived') NOT NULL DEFAULT 'draft',
    access_mode ENUM('included','iap') NOT NULL DEFAULT 'included',
    iap_product_id VARCHAR(120) NULL,
    capacity INT UNSIGNED NULL,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    INDEX club_seasons_active(status,starts_on,ends_on)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_tasks (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    season_id BIGINT UNSIGNED NOT NULL,
    title VARCHAR(80) NOT NULL,
    detail VARCHAR(200) NOT NULL DEFAULT '',
    metric ENUM('training_days','meal_days','weekly_reviews','meal_records','daily_reports','health_days') NOT NULL,
    target INT UNSIGNED NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL,
    CONSTRAINT fk_club_tasks_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE CASCADE,
    INDEX club_tasks_order(season_id,sort_order,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_reward_catalog (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    kind ENUM('badge','title','physical') NOT NULL,
    name VARCHAR(80) NOT NULL,
    detail VARCHAR(200) NOT NULL DEFAULT '',
    icon VARCHAR(40) NOT NULL DEFAULT 'seal',
    image_path VARCHAR(180) NULL,
    sku VARCHAR(80) NULL,
    default_inventory INT UNSIGNED NULL,
    max_per_user INT UNSIGNED NOT NULL DEFAULT 1,
    claim_deadline DATE NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    INDEX club_reward_catalog_kind(active,kind),
    INDEX club_reward_catalog_name(name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_rewards (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    season_id BIGINT UNSIGNED NOT NULL,
    task_id BIGINT UNSIGNED NOT NULL,
    catalog_id BIGINT UNSIGNED NULL,
    title VARCHAR(80) NOT NULL,
    detail VARCHAR(200) NOT NULL DEFAULT '',
    reward_type ENUM('badge','title','physical') NOT NULL,
    icon VARCHAR(40) NOT NULL DEFAULT 'seal',
    image_path VARCHAR(180) NULL,
    sku VARCHAR(80) NULL,
    inventory INT UNSIGNED NULL,
    max_per_user INT UNSIGNED NOT NULL DEFAULT 1,
    claim_deadline DATE NULL,
    sort_order INT NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL,
    CONSTRAINT fk_club_rewards_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE CASCADE,
    CONSTRAINT fk_club_rewards_task FOREIGN KEY(task_id) REFERENCES club_tasks(id) ON DELETE RESTRICT,
    CONSTRAINT fk_club_rewards_catalog FOREIGN KEY(catalog_id) REFERENCES club_reward_catalog(id) ON DELETE SET NULL,
    INDEX club_rewards_order(season_id,sort_order,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_enrollments (
    season_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    access_source ENUM('included','iap','admin') NOT NULL DEFAULT 'included',
    rules_version VARCHAR(40) NOT NULL,
    joined_at DATETIME NOT NULL,
    PRIMARY KEY(season_id,user_id),
    CONSTRAINT fk_club_enrollments_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE RESTRICT,
    CONSTRAINT fk_club_enrollments_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_reward_claims (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    season_id BIGINT UNSIGNED NOT NULL,
    reward_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    status ENUM('pending','confirmed','packing','shipped','delivered','problem','cancelled') NOT NULL DEFAULT 'pending',
    recipient VARCHAR(40) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    region VARCHAR(100) NOT NULL,
    address VARCHAR(240) NOT NULL,
    size_value VARCHAR(20) NULL,
    tracking_company VARCHAR(60) NULL,
    tracking_number VARCHAR(100) NULL,
    operator_note VARCHAR(500) NOT NULL DEFAULT '',
    reviewed_at DATETIME NULL,
    reviewed_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE KEY club_reward_once(reward_id,user_id),
    CONSTRAINT fk_club_claims_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE RESTRICT,
    CONSTRAINT fk_club_claims_reward FOREIGN KEY(reward_id) REFERENCES club_rewards(id) ON DELETE RESTRICT,
    CONSTRAINT fk_club_claims_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX club_claims_status(status,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_virtual_grants (
    user_id BIGINT UNSIGNED NOT NULL,
    reward_id BIGINT UNSIGNED NOT NULL,
    season_id BIGINT UNSIGNED NOT NULL,
    granted_at DATETIME NOT NULL,
    PRIMARY KEY(user_id,reward_id),
    CONSTRAINT fk_club_grants_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_club_grants_reward FOREIGN KEY(reward_id) REFERENCES club_rewards(id) ON DELETE RESTRICT,
    CONSTRAINT fk_club_grants_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE RESTRICT,
    INDEX club_grants_user(user_id,granted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_announcements (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    season_id BIGINT UNSIGNED NOT NULL,
    title VARCHAR(100) NOT NULL,
    body TEXT NOT NULL,
    published_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL,
    CONSTRAINT fk_club_announcements_season FOREIGN KEY(season_id) REFERENCES club_seasons(id) ON DELETE RESTRICT,
    INDEX club_announcements_order(season_id,published_at,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notification_templates (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    category ENUM('training','daily_report','weekly_review','reward','shipping','membership','system') NOT NULL,
    name VARCHAR(80) NOT NULL,
    title VARCHAR(120) NOT NULL,
    body VARCHAR(300) NOT NULL,
    deeplink VARCHAR(160) NOT NULL DEFAULT '',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    default_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sound BOOLEAN NOT NULL DEFAULT TRUE,
    badge BOOLEAN NOT NULL DEFAULT FALSE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE KEY notification_template_name(name),
    INDEX notification_template_category(active,category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notification_plans (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    template_id BIGINT UNSIGNED NOT NULL,
    name VARCHAR(80) NOT NULL,
    category ENUM('training','daily_report','weekly_review','reward','shipping','membership','system') NOT NULL,
    weekdays VARCHAR(30) NOT NULL DEFAULT '',
    hour TINYINT UNSIGNED NOT NULL DEFAULT 19,
    minute TINYINT UNSIGNED NOT NULL DEFAULT 30,
    timezone VARCHAR(60) NOT NULL DEFAULT 'Asia/Shanghai',
    trigger_type ENUM('weekday','event','relative') NOT NULL DEFAULT 'weekday',
    threshold TINYINT UNSIGNED NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT fk_notification_plan_template FOREIGN KEY(template_id) REFERENCES notification_templates(id) ON DELETE CASCADE,
    INDEX notification_plan_active(active,category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notification_deliveries (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    template_id BIGINT UNSIGNED NULL,
    user_id BIGINT UNSIGNED NULL,
    category ENUM('training','daily_report','weekly_review','reward','shipping','membership','system') NOT NULL,
    title VARCHAR(120) NOT NULL,
    body VARCHAR(300) NOT NULL,
    status ENUM('queued','sent','delivered','clicked','failed','muted') NOT NULL DEFAULT 'queued',
    provider VARCHAR(40) NOT NULL DEFAULT 'local',
    error VARCHAR(200) NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL,
    sent_at DATETIME NULL,
    CONSTRAINT fk_notification_delivery_template FOREIGN KEY(template_id) REFERENCES notification_templates(id) ON DELETE SET NULL,
    CONSTRAINT fk_notification_delivery_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE SET NULL,
    INDEX notification_delivery_status(status,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS revenuecat_events (
    event_id VARCHAR(191) NOT NULL PRIMARY KEY,
    event_type VARCHAR(60) NOT NULL,
    user_id BIGINT UNSIGNED NULL,
    app_user_id VARCHAR(191) NOT NULL DEFAULT '',
    product_id VARCHAR(191) NOT NULL DEFAULT '',
    transaction_id VARCHAR(255) NULL,
    original_transaction_id VARCHAR(255) NULL,
    expires_at DATETIME NULL,
    payload_hash CHAR(64) NOT NULL,
    received_at DATETIME NOT NULL,
    INDEX revenuecat_events_user (user_id, received_at),
    INDEX revenuecat_events_type (event_type, received_at),
    CONSTRAINT revenuecat_events_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS revenuecat_subscriptions (
 original_transaction_id VARCHAR(255) NOT NULL PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 product_id VARCHAR(191) NOT NULL,
 status ENUM('active','expired','revoked') NOT NULL,
 starts_at DATETIME NOT NULL,
 expires_at DATETIME NOT NULL,
 event_timestamp_ms BIGINT UNSIGNED NOT NULL,
 last_transaction_id VARCHAR(255) NOT NULL,
 CONSTRAINT rc_subscriptions_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX rc_subscriptions_user_expiry(user_id,expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS deleted_media (
 user_id BIGINT UNSIGNED NOT NULL,
 media_id VARCHAR(80) NOT NULL,
 deleted_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,media_id),
 CONSTRAINT deleted_media_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Upgrade existing installations after all tables exist.
ALTER TABLE users MODIFY COLUMN phone VARCHAR(20) NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_subject VARCHAR(255) NULL UNIQUE AFTER phone;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS training_days VARCHAR(50) NOT NULL DEFAULT '' AFTER limitations;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS equipment_other VARCHAR(200) NOT NULL DEFAULT '' AFTER equipment;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS home_training_days VARCHAR(50) NOT NULL DEFAULT '' AFTER training_days;
ALTER TABLE club_tasks MODIFY metric ENUM('training_days','meal_days','weekly_reviews','meal_records','daily_reports','health_days') NOT NULL;
ALTER TABLE club_rewards ADD COLUMN IF NOT EXISTS image_path VARCHAR(180) NULL AFTER icon;
ALTER TABLE club_rewards ADD COLUMN IF NOT EXISTS max_per_user INT UNSIGNED NOT NULL DEFAULT 1 AFTER inventory;
ALTER TABLE club_rewards ADD COLUMN IF NOT EXISTS claim_deadline DATE NULL AFTER max_per_user;
ALTER TABLE club_rewards ADD COLUMN IF NOT EXISTS catalog_id BIGINT UNSIGNED NULL AFTER task_id;

ALTER TABLE ai_user_jobs ADD COLUMN IF NOT EXISTS completed_at DATETIME NULL AFTER kind;

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
 subject_hash CHAR(64) NULL,
 status ENUM('queued','retrying','completed','failed') NOT NULL,
 job_ids MEDIUMTEXT NOT NULL,
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 last_error_code VARCHAR(40) NULL,
 next_attempt DATETIME NOT NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 INDEX account_deletions_due(status,next_attempt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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

CREATE TABLE IF NOT EXISTS apple_auth_nonces (
    nonce_hash CHAR(64) PRIMARY KEY,
    expires_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL,
    INDEX apple_auth_nonces_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS apple_tokens (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 client_id VARCHAR(191) NOT NULL,
 token_cipher TEXT NOT NULL,
 checked_at DATETIME NOT NULL,
 CONSTRAINT apple_tokens_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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


CREATE TABLE IF NOT EXISTS club_automation (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
 enabled TINYINT(1) NOT NULL DEFAULT 0,
 paused TINYINT(1) NOT NULL DEFAULT 0,
 paused_reason VARCHAR(200) NULL,
 retry_count INT UNSIGNED NOT NULL DEFAULT 0,
 preferences_json MEDIUMTEXT NOT NULL,
 coverage_json MEDIUMTEXT NOT NULL,
 cloud_revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
 next_run DATETIME NOT NULL,
 last_status VARCHAR(100) NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT club_automation_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX club_automation_due(enabled,next_run)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- FIX-009/021: execution log used by the scheduler, admin statistics and recovery.
CREATE TABLE IF NOT EXISTS club_automation_runs (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
 outcome ENUM('running','submitted','checked','needs_record_check','retry_pending','failed','skipped') NOT NULL DEFAULT 'running',
 tasks_submitted INT UNSIGNED NOT NULL DEFAULT 0,
 vendor_attempts INT UNSIGNED NOT NULL DEFAULT 0,
 error_summary VARCHAR(200) NULL,
 started_at DATETIME NOT NULL,
 finished_at DATETIME NULL,
 CONSTRAINT club_automation_runs_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX club_automation_runs_started(started_at),
 INDEX club_automation_runs_user_time(user_id,started_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_push_settings (
 setting_key VARCHAR(80) NOT NULL PRIMARY KEY,
 setting_value VARCHAR(200) NOT NULL,
 updated_at DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT IGNORE INTO club_push_settings(setting_key,setting_value,updated_at) VALUES('proactive_daily_limit','1',UTC_TIMESTAMP());

CREATE TABLE IF NOT EXISTS club_push_account_blocks (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 reason VARCHAR(200) NOT NULL,
 blocked_by BIGINT UNSIGNED NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT club_push_account_blocks_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS club_push_budget (
 user_id BIGINT UNSIGNED NOT NULL,
 budget_day DATE NOT NULL,
 semantic_key VARCHAR(120) NOT NULL,
 kind VARCHAR(40) NOT NULL,
 budget_class ENUM('proactive','account','report','reminder') NOT NULL DEFAULT 'proactive',
 status ENUM('reserved','sent','skipped','failed') NOT NULL DEFAULT 'reserved',
 device_id CHAR(36) NULL,
 client_job_id CHAR(36) NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,budget_day,semantic_key),
 INDEX club_push_budget_day(budget_day,status),
 INDEX club_push_budget_owner(user_id,budget_day,budget_class,status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS data_operations (
 operation_id CHAR(36) PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 actor ENUM('user','ai','system','admin') NOT NULL,
 command_type VARCHAR(60) NOT NULL,
 payload_hash CHAR(64) NOT NULL,
 aggregate_type VARCHAR(40) NOT NULL,
 aggregate_id VARCHAR(80) NOT NULL,
 before_version VARCHAR(40) NULL,
 after_version VARCHAR(40) NOT NULL,
 diff_json MEDIUMTEXT NULL,
 status ENUM('succeeded','failed','compensated') NOT NULL DEFAULT 'succeeded',
 created_at DATETIME NOT NULL,
 CONSTRAINT data_operations_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX data_ops_user_time(user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS domain_outbox (
 event_id CHAR(36) PRIMARY KEY,
 operation_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 aggregate_type VARCHAR(40) NOT NULL,
 aggregate_id VARCHAR(80) NOT NULL,
 aggregate_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
 trace_id CHAR(32) NULL,
 event_type VARCHAR(60) NOT NULL,
 payload MEDIUMTEXT NOT NULL,
 status ENUM('pending','processing','published','dead_letter') NOT NULL DEFAULT 'pending',
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 next_attempt DATETIME NOT NULL,
 lease_token CHAR(36) NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT domain_outbox_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX outbox_due(status, next_attempt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- M-1 (Phase 2 §2.3, 2026-10-24): server-side conversation storage.
-- Expand-only: old clients never read these tables; dropping them is a safe rollback.
CREATE TABLE IF NOT EXISTS ai_conversations (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 conversation_id VARCHAR(64) NOT NULL,
 message_count INT UNSIGNED NOT NULL DEFAULT 0,
 first_message_at DATETIME NOT NULL,
 last_message_at DATETIME NOT NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY ai_conversations_user_conv (user_id, conversation_id),
 INDEX ai_conversations_user_recent (user_id, last_message_at),
 CONSTRAINT ai_conversations_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_messages (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 conversation_row_id BIGINT UNSIGNED NOT NULL,
 job_client_id CHAR(36) NULL,
 role ENUM('user','assistant') NOT NULL,
 content TEXT NOT NULL,
 payload_json MEDIUMTEXT NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY ai_messages_turn (user_id, job_client_id, role),
 INDEX ai_messages_conv_page (conversation_row_id, id),
 CONSTRAINT ai_messages_conversation_fk FOREIGN KEY (conversation_row_id) REFERENCES ai_conversations(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_message_cards (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 message_id BIGINT UNSIGNED NOT NULL,
 card_id VARCHAR(64) NOT NULL,
 card_type VARCHAR(32) NOT NULL,
 schema_version INT UNSIGNED NOT NULL,
 title VARCHAR(120) NOT NULL,
 payload_json MEDIUMTEXT NOT NULL,
 created_at DATETIME NOT NULL,
 UNIQUE KEY ai_message_cards_card (message_id, card_id),
 INDEX ai_message_cards_type (card_type),
 CONSTRAINT ai_message_cards_message_fk FOREIGN KEY (message_id) REFERENCES ai_messages(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- M-2 (Phase 3 §4.1, 2026-10-25): AI action proposal state machine.
-- Expand-only: the proposals tables carry awaiting_confirmation etc.; the
-- data_operations audit stream stays authoritative for every executed write.
-- Rollback = stop using the proposal paths; old commands.php semantics remain.
CREATE TABLE IF NOT EXISTS ai_action_proposals (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 proposal_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 kind ENUM('meal_draft','weight_entry','plan_change_proposal','exercise_swap','plan_activation') NOT NULL,
 status ENUM('draft','validated','awaiting_confirmation','executing','succeeded','rejected','expired','conflict','failed','cancelled') NOT NULL DEFAULT 'draft',
 payload_json MEDIUMTEXT NOT NULL,
 evidence_refs_json TEXT NOT NULL,
 conversation_id VARCHAR(64) NULL,
 idempotency_key CHAR(64) NOT NULL,
 expires_at DATETIME NULL,
 confirmed_command_id CHAR(36) NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY ai_action_proposals_pid (proposal_id),
 UNIQUE KEY ai_action_proposals_idem (user_id, idempotency_key),
 INDEX ai_action_proposals_user_status (user_id, status, updated_at),
 CONSTRAINT ai_action_proposals_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_action_executions (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 proposal_row_id BIGINT UNSIGNED NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 command_id CHAR(36) NOT NULL,
 idempotency_key CHAR(64) NOT NULL,
 status ENUM('succeeded','failed','conflict') NOT NULL,
 detail_json MEDIUMTEXT NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY ai_action_executions_cmd (command_id),
 UNIQUE KEY ai_action_executions_prop (proposal_row_id, idempotency_key),
 CONSTRAINT ai_action_executions_prop_fk FOREIGN KEY (proposal_row_id) REFERENCES ai_action_proposals(id) ON DELETE CASCADE,
 CONSTRAINT ai_action_executions_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- M-3 (Phase 4 §5.1, 2026-10-25): long-term memory store (D-10).
-- Data minimisation: contents are derived, non-sensitive statements (counts,
-- categories, preferences) — never raw health measurements. User corrections,
-- suspensions and withdrawals survive re-extraction via stable idempotency keys.
CREATE TABLE IF NOT EXISTS user_memory_items (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 memory_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 kind ENUM('fact','habit','preference','goal','constraint','correction') NOT NULL,
 content VARCHAR(300) NOT NULL,
 confidence TINYINT UNSIGNED NOT NULL DEFAULT 60,
 status ENUM('active','corrected','withdrawn','suspended') NOT NULL DEFAULT 'active',
 origin ENUM('extracted','user') NOT NULL DEFAULT 'extracted',
 evidence_json TEXT NOT NULL,
 idempotency_key CHAR(64) NOT NULL,
 source_revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
 supersedes CHAR(36) NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY user_memory_items_mid (memory_id),
 UNIQUE KEY user_memory_items_idem (user_id, idempotency_key),
 INDEX user_memory_items_user (user_id, status, updated_at),
 CONSTRAINT user_memory_items_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Phase 4 §5.5 / Phase 5 §6.2-3 (2026-10-25): feedback loop + metrics events
-- (曝光→接受→执行→结果 chain; client metric events use the same table) + the
-- per-request AI usage ledger (latency now; token counts nullable for the
-- worker to extend). Expand-only; user FK cascade keeps deletion clean.
CREATE TABLE IF NOT EXISTS ai_feedback_events (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 kind VARCHAR(40) NOT NULL,
 name VARCHAR(60) NULL,
 target_id VARCHAR(80) NULL,
 action VARCHAR(30) NULL,
 detail_json MEDIUMTEXT NULL,
 created_at DATETIME NOT NULL,
 INDEX ai_feedback_events_user (user_id, kind, created_at),
 INDEX ai_feedback_events_name (name, created_at),
 CONSTRAINT ai_feedback_events_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_usage_ledger (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 server_job_id CHAR(36) NULL,
 kind VARCHAR(30) NOT NULL,
 status VARCHAR(20) NOT NULL,
 latency_ms INT UNSIGNED NULL,
 prompt_tokens INT UNSIGNED NULL,
 completion_tokens INT UNSIGNED NULL,
 provider VARCHAR(30) NULL,
 created_at DATETIME NOT NULL,
 INDEX ai_usage_ledger_user (user_id, created_at),
 INDEX ai_usage_ledger_kind (kind, created_at),
 CONSTRAINT ai_usage_ledger_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
-- Additive repair: durable per-consumer event deduplication.
CREATE TABLE IF NOT EXISTS domain_consumer_inbox (
 consumer VARCHAR(64) NOT NULL,
 event_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 processed_at DATETIME NOT NULL,
 PRIMARY KEY (consumer,event_id),
 INDEX domain_consumer_user (user_id),
 CONSTRAINT domain_consumer_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Phase 1: single active workout session invariant (DB level).
-- Expand-only; see migrations/20261025-training-commands.sql for the rollout note.
CREATE TABLE IF NOT EXISTS active_workout_sessions (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 session_id CHAR(36) NOT NULL,
 date_key CHAR(10) NOT NULL,
 started_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT active_workout_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Phase 1: semantic idempotency key for proposal-free direct commands.
ALTER TABLE data_operations ADD COLUMN IF NOT EXISTS idempotency_key CHAR(64) NULL AFTER payload_hash;
ALTER TABLE data_operations ADD UNIQUE KEY IF NOT EXISTS data_ops_idem (user_id, idempotency_key);
-- Phase 2: inverse payload for action.undo (direct records only).
ALTER TABLE data_operations ADD COLUMN IF NOT EXISTS undo_json MEDIUMTEXT NULL AFTER diff_json;

-- Phase 4: per-consumer projection freshness (lag visibility + reconciliation).
CREATE TABLE IF NOT EXISTS domain_projection_state (
 user_id BIGINT UNSIGNED NOT NULL,
 consumer VARCHAR(64) NOT NULL,
 last_event_id CHAR(36) NULL,
 last_event_at DATETIME NULL,
 processed_events BIGINT UNSIGNED NOT NULL DEFAULT 0,
 updated_at DATETIME NOT NULL,
 PRIMARY KEY (user_id, consumer),
 CONSTRAINT domain_projection_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_action_preferences (
 user_id BIGINT UNSIGNED PRIMARY KEY, fast_records BOOLEAN NOT NULL DEFAULT FALSE,
 time_zone VARCHAR(80) NOT NULL DEFAULT 'Asia/Shanghai', weight_unit VARCHAR(8) NOT NULL DEFAULT 'kg',
 proactive_learning BOOLEAN NOT NULL DEFAULT TRUE,
 updated_at DATETIME NOT NULL, CONSTRAINT action_preferences_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS ai_action_calls (
 user_id BIGINT UNSIGNED NOT NULL, call_id CHAR(36) NOT NULL, message_id VARCHAR(80) NOT NULL,
 conversation_id VARCHAR(80) NULL, trace_id CHAR(32) NULL, capability VARCHAR(80) NOT NULL, input_hash CHAR(64) NOT NULL, input_json MEDIUMTEXT NOT NULL,
 status VARCHAR(40) NOT NULL, result_json MEDIUMTEXT NULL, lifecycle_json MEDIUMTEXT NOT NULL,
 lease_until DATETIME NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,call_id), INDEX action_message(user_id,message_id),
 CONSTRAINT action_calls_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS ai_action_jobs (
 execution_id CHAR(36) PRIMARY KEY, user_id BIGINT UNSIGNED NOT NULL,
 server_job_id CHAR(36) NOT NULL, request_json MEDIUMTEXT NOT NULL, result_json MEDIUMTEXT NULL,
 status VARCHAR(30) NOT NULL, attempts INT NOT NULL DEFAULT 0, lease_token CHAR(36) NULL,
 next_attempt DATETIME NOT NULL, error_code VARCHAR(80) NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
 INDEX action_jobs_pending(status,next_attempt),
 CONSTRAINT action_jobs_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS domain_notification_jobs (
 event_id CHAR(36) NOT NULL, user_id BIGINT UNSIGNED NOT NULL, device_id CHAR(36) NOT NULL,
 kind VARCHAR(40) NOT NULL, date_key CHAR(10) NOT NULL, title VARCHAR(120) NOT NULL, body VARCHAR(300) NOT NULL,
 status VARCHAR(20) NOT NULL DEFAULT 'pending', attempts INT NOT NULL DEFAULT 0,
 next_attempt DATETIME NOT NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
 PRIMARY KEY(event_id,device_id), INDEX domain_notify_pending(status,next_attempt),
 CONSTRAINT domain_notify_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE domain_outbox CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE ai_action_proposals MODIFY COLUMN kind ENUM('meal_draft','weight_entry','plan_change_proposal','exercise_swap','plan_activation','training_finish') NOT NULL;

CREATE TABLE IF NOT EXISTS ai_action_messages (
 user_id BIGINT UNSIGNED NOT NULL,message_id CHAR(36) NOT NULL,conversation_id VARCHAR(80) NULL,trace_id CHAR(32) NULL,
 status VARCHAR(30) NOT NULL DEFAULT 'accepted',created_at DATETIME NOT NULL,updated_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,message_id),CONSTRAINT action_messages_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE domain_projection_state ADD COLUMN IF NOT EXISTS aggregate_version BIGINT UNSIGNED NOT NULL DEFAULT 0;

-- Phase 2 (2026-10-25): durable AI Run + SSE event log (expand-only).
CREATE TABLE IF NOT EXISTS ai_runs (
 id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 conversation_id VARCHAR(64) NOT NULL,
 client_message_id CHAR(36) NOT NULL,
 server_job_id CHAR(36) NOT NULL,
 message_id CHAR(36) NOT NULL,
 trace_id CHAR(32) NOT NULL,
 status VARCHAR(16) NOT NULL,
 last_seq INT UNSIGNED NOT NULL DEFAULT 0,
 event_floor INT UNSIGNED NOT NULL DEFAULT 1,
 request_hash CHAR(64) NOT NULL,
 request_json MEDIUMTEXT NOT NULL,
 result_json MEDIUMTEXT NULL,
 error_code VARCHAR(64) NULL,
 lease_owner VARCHAR(80) NULL,
 lease_expires_at DATETIME NULL,
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 PRIMARY KEY (id),
 UNIQUE KEY ai_runs_client (user_id, client_message_id),
 KEY ai_runs_claim (status, lease_expires_at),
 KEY ai_runs_conversation (user_id, conversation_id, created_at),
 KEY ai_runs_cleanup (status, updated_at),
 CONSTRAINT ai_runs_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ai_run_events (
 run_id CHAR(36) NOT NULL,
 seq INT UNSIGNED NOT NULL,
 event_id CHAR(36) NOT NULL,
 type VARCHAR(40) NOT NULL,
 data_json MEDIUMTEXT NOT NULL,
 created_at DATETIME NOT NULL,
 PRIMARY KEY (run_id, seq),
 UNIQUE KEY ai_run_events_event (event_id),
 CONSTRAINT ai_run_events_run_fk FOREIGN KEY (run_id) REFERENCES ai_runs(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE ai_usage_ledger ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER provider;
ALTER TABLE ai_action_proposals ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER conversation_id;
ALTER TABLE data_operations ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER idempotency_key;

ALTER TABLE ai_action_messages ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER conversation_id;
ALTER TABLE ai_action_calls ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER conversation_id;
ALTER TABLE domain_outbox ADD COLUMN IF NOT EXISTS trace_id CHAR(32) NULL AFTER aggregate_version;

ALTER TABLE ai_runs ADD COLUMN IF NOT EXISTS event_floor INT UNSIGNED NOT NULL DEFAULT 1 AFTER last_seq;
ALTER TABLE ai_runs ADD KEY IF NOT EXISTS ai_runs_cleanup (status, updated_at);

ALTER TABLE user_action_preferences ADD COLUMN IF NOT EXISTS proactive_learning BOOLEAN NOT NULL DEFAULT TRUE AFTER weight_unit;

-- AI onboarding V2 (2026-10-26): server-derived purpose on jobs makes the
-- polling and SSE paths agree; old rows stay NULL.
ALTER TABLE ai_user_jobs ADD COLUMN IF NOT EXISTS purpose VARCHAR(30) NULL AFTER kind;
ALTER TABLE ai_user_jobs ADD COLUMN IF NOT EXISTS onboarding_session_id CHAR(36) NULL AFTER purpose;

CREATE TABLE IF NOT EXISTS member_feedback_tickets (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 category ENUM('problem','suggestion','other') NOT NULL,
 status ENUM('open','replied','closed') NOT NULL DEFAULT 'open',
 title VARCHAR(100) NOT NULL,
 metadata_json TEXT NOT NULL,
 last_message_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
 user_read_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 INDEX feedback_owner(user_id,updated_at), INDEX feedback_queue(status,updated_at),
 CONSTRAINT feedback_ticket_owner FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_feedback_messages (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 ticket_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 client_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 author ENUM('member','admin') NOT NULL,
 admin_id BIGINT UNSIGNED NULL,
 body TEXT NOT NULL,
 request_hash CHAR(64) CHARACTER SET ascii NOT NULL,
 created_at DATETIME NOT NULL,
 UNIQUE KEY feedback_message_once(ticket_id,client_id),
 INDEX feedback_thread(ticket_id,id),
 CONSTRAINT feedback_message_ticket FOREIGN KEY(ticket_id) REFERENCES member_feedback_tickets(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_feedback_attachments (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 message_id BIGINT UNSIGNED NULL,
 kind ENUM('image','video') NOT NULL,
 mime VARCHAR(40) NOT NULL,
 storage_name VARCHAR(90) CHARACTER SET ascii NOT NULL,
 original_sha256 CHAR(64) CHARACTER SET ascii NOT NULL,
 content_sha256 CHAR(64) CHARACTER SET ascii NOT NULL,
 byte_size BIGINT UNSIGNED NOT NULL,
 duration_seconds DECIMAL(8,3) NULL,
 created_at DATETIME NOT NULL,
 INDEX feedback_media_owner(user_id,created_at), INDEX feedback_media_message(message_id),
 CONSTRAINT feedback_attachment_owner FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 CONSTRAINT feedback_attachment_message FOREIGN KEY(message_id) REFERENCES member_feedback_messages(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ai_guard_buckets131 (
 bucket_key CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 window_start BIGINT NOT NULL,
 hits INT UNSIGNED NOT NULL DEFAULT 0,
 PRIMARY KEY(bucket_key,window_start),
 INDEX ai_guard_buckets131_expiry(window_start)
) ENGINE=InnoDB;

-- Statistics retain the complete snapshot; no unmeasured updated_at cutoff is applied.
