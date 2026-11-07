CREATE TABLE IF NOT EXISTS notification_plan_settings (
 plan_id BIGINT UNSIGNED PRIMARY KEY,
 state ENUM('draft','enabled','paused') NOT NULL DEFAULT 'draft',
 revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
 audience_json TEXT NOT NULL,
 enabled_at DATETIME NULL,
 updated_by BIGINT UNSIGNED NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT scheduled_plan_owner FOREIGN KEY(plan_id) REFERENCES notification_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS notification_schedule_runs (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 plan_id BIGINT UNSIGNED NOT NULL,
 plan_revision BIGINT UNSIGNED NOT NULL,
 occurrence_date DATE NOT NULL,
 scheduled_for DATETIME NOT NULL,
 expires_at DATETIME NOT NULL,
 payload_json TEXT NOT NULL,
 recipient_count INT UNSIGNED NOT NULL DEFAULT 0,
 created_at DATETIME NOT NULL,
 UNIQUE KEY scheduled_plan_once_daily(plan_id,occurrence_date),
 INDEX scheduled_runs_time(scheduled_for),
 CONSTRAINT scheduled_run_plan FOREIGN KEY(plan_id) REFERENCES notification_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS notification_schedule_deliveries (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 run_id BIGINT UNSIGNED NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 status ENUM('pending','sending','sent','skipped','failed','uncertain') NOT NULL DEFAULT 'pending',
 attempts INT UNSIGNED NOT NULL DEFAULT 0,
 next_attempt DATETIME NOT NULL,
 lease_token CHAR(64) CHARACTER SET ascii NULL,
 lease_until DATETIME NULL,
 device_id VARCHAR(100) NULL,
 reason VARCHAR(100) NULL,
 receipt_id BIGINT UNSIGNED NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 UNIQUE KEY scheduled_user_once(run_id,user_id),
 INDEX scheduled_delivery_queue(status,next_attempt),
 CONSTRAINT scheduled_delivery_run FOREIGN KEY(run_id) REFERENCES notification_schedule_runs(id) ON DELETE CASCADE,
 CONSTRAINT scheduled_delivery_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
