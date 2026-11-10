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
