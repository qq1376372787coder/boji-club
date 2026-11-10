-- BOJI CLUB AI onboarding V2 (additive only; safe to apply repeatedly).
-- Authoritative profile facts + onboarding session/head + proposals + daily
-- assist budget + bounded onboarding transcript. Every table cascades from
-- users(id) so account deletion keeps working without a second cleanup list.

CREATE TABLE IF NOT EXISTS user_profile_documents (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    schema_version TINYINT UNSIGNED NOT NULL DEFAULT 1,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    facts_json MEDIUMTEXT NOT NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT profile_documents_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_onboarding_sessions (
    id CHAR(36) NOT NULL PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    schema_version TINYINT UNSIGNED NOT NULL DEFAULT 1,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    task_kind VARCHAR(30) NOT NULL,
    status VARCHAR(30) NOT NULL,
    draft_json MEDIUMTEXT NOT NULL,
    conversation_id VARCHAR(80) NULL,
    first_job_id VARCHAR(80) NULL,
    first_proposal_id CHAR(36) NULL,
    first_command_id CHAR(36) NULL,
    covenant_version VARCHAR(40) NULL,
    covenant_accepted_at DATETIME NULL,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    deferred_at DATETIME NULL,
    completed_at DATETIME NULL,
    KEY onboarding_sessions_user (user_id, updated_at),
    CONSTRAINT onboarding_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_onboarding_heads (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    active_session_id CHAR(36) NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT onboarding_heads_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_onboarding_proposals (
    proposal_id CHAR(36) NOT NULL PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    session_id CHAR(36) NULL,
    kind VARCHAR(30) NOT NULL DEFAULT 'profile',
    status VARCHAR(30) NOT NULL DEFAULT 'awaiting_confirmation',
    changes_json MEDIUMTEXT NOT NULL,
    before_json MEDIUMTEXT NOT NULL,
    plan_start_date DATE NULL,
    profile_revision BIGINT UNSIGNED NOT NULL,
    session_revision BIGINT UNSIGNED NULL,
    idempotency_key VARCHAR(120) NOT NULL,
    expires_at DATETIME NOT NULL,
    confirmed_at DATETIME NULL,
    command_id CHAR(36) NULL,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE KEY onboarding_proposal_idem (user_id, idempotency_key),
    KEY onboarding_proposal_user (user_id, status, expires_at),
    CONSTRAINT onboarding_proposal_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_onboarding_requests (
    user_id BIGINT UNSIGNED NOT NULL,
    operation VARCHAR(60) NOT NULL,
    idempotency_key VARCHAR(120) NOT NULL,
    payload_hash CHAR(64) NOT NULL,
    result_json MEDIUMTEXT NOT NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (user_id, operation, idempotency_key),
    CONSTRAINT onboarding_requests_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_onboarding_messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    session_id CHAR(36) NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    role ENUM('user','assistant') NOT NULL,
    content VARCHAR(4000) NOT NULL,
    created_at DATETIME NOT NULL,
    KEY onboarding_messages_session (session_id, id),
    CONSTRAINT onboarding_messages_session FOREIGN KEY (session_id) REFERENCES user_onboarding_sessions(id) ON DELETE CASCADE,
    CONSTRAINT onboarding_messages_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS onboarding_assist_usage (
    user_id BIGINT UNSIGNED NOT NULL,
    usage_day DATE NOT NULL,
    turns INT UNSIGNED NOT NULL DEFAULT 0,
    updated_at DATETIME NOT NULL,
    PRIMARY KEY (user_id, usage_day),
    CONSTRAINT onboarding_assist_usage_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_profile_tombstones (
 user_id BIGINT UNSIGNED NOT NULL, field_name VARCHAR(60) NOT NULL,
 revision BIGINT UNSIGNED NOT NULL, deleted_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,field_name),
 CONSTRAINT profile_tombstones_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Shared intake progress only. Personal information remains in user_profile_documents.
CREATE TABLE IF NOT EXISTS user_onboarding_checkpoints (
    user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    basic_profile_status VARCHAR(20) NOT NULL DEFAULT 'pending',
    updated_at DATETIME NOT NULL,
    CONSTRAINT onboarding_checkpoints_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
