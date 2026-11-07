-- Phase 4: event consumers, projection freshness and reconciliation.
-- Expand-only: the existing personal-memory-v1 consumer keeps working; new
-- consumers record their receipts in domain_consumer_inbox (already present).

-- 1. Per-consumer projection freshness (the UI can show "projection lag" and
--    the reconciler can find events a consumer never processed).
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
