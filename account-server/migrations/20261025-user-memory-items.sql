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
