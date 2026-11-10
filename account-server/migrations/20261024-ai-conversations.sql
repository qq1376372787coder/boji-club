-- M-1 (Phase 2 §2.3, 2026-10-24): server-side AI conversation storage.
--
-- Expand-only. Old clients never read these tables; the current local-only
-- conversation path stays authoritative for them. Rollback = revert the
-- writing code (deploy-experience-sync.sh 哈希回滚即可停止写入); per plan §3
-- the tables themselves are kept (表保留不删) so history survives re-enable.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS — safe to re-run.
-- Backup before applying: mysqldump <db> (full; the tables are new, so the
-- restore point only needs to predate the first write).
-- Account deletion cleans these rows automatically via
-- ai_conversations_user_fk ON DELETE CASCADE (users.id).

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
