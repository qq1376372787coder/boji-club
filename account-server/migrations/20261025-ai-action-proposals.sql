-- M-2 (Phase 3 §4.1, 2026-10-25): AI action proposal state machine.
-- Expand-only: the proposals tables carry awaiting_confirmation etc.; the
-- data_operations audit stream stays authoritative for every executed write.
-- Rollback = stop using the proposal paths; old commands.php semantics remain.
CREATE TABLE IF NOT EXISTS ai_action_proposals (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 proposal_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 kind ENUM('meal_draft','weight_entry','plan_change_proposal') NOT NULL,
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
