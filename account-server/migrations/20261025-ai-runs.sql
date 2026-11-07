-- Phase 2 (2026-10-25): durable AI Run + SSE event log.
-- Expand-only. No business document is duplicated: runs reference the same
-- ai_user_jobs row and the same ai_messages turn the polling path uses.
-- Idempotency: one run per (user, client_message_id); retries return that run.

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
