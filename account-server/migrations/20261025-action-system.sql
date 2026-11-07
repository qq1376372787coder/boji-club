CREATE TABLE IF NOT EXISTS user_action_preferences (
 user_id BIGINT UNSIGNED PRIMARY KEY, fast_records BOOLEAN NOT NULL DEFAULT FALSE,
 time_zone VARCHAR(80) NOT NULL DEFAULT 'Asia/Shanghai', weight_unit VARCHAR(8) NOT NULL DEFAULT 'kg',
 updated_at DATETIME NOT NULL, CONSTRAINT action_preferences_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS ai_action_calls (
 user_id BIGINT UNSIGNED NOT NULL, call_id CHAR(36) NOT NULL, message_id VARCHAR(80) NOT NULL,
 conversation_id VARCHAR(80) NULL, capability VARCHAR(80) NOT NULL, input_hash CHAR(64) NOT NULL, input_json MEDIUMTEXT NOT NULL,
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
 user_id BIGINT UNSIGNED NOT NULL,message_id CHAR(36) NOT NULL,conversation_id VARCHAR(80) NULL,
 status VARCHAR(30) NOT NULL DEFAULT 'accepted',created_at DATETIME NOT NULL,updated_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,message_id),CONSTRAINT action_messages_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE domain_projection_state ADD COLUMN IF NOT EXISTS aggregate_version BIGINT UNSIGNED NOT NULL DEFAULT 0;
