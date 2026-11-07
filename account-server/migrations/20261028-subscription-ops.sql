-- Forward-only factual evidence. Historical rows are deliberately NOT backfilled.
-- No amount in this table is an accounting total or proof of settlement/refund.
CREATE TABLE IF NOT EXISTS revenuecat_event_facts (
 event_id VARCHAR(191) NOT NULL PRIMARY KEY,
 source VARCHAR(40) NOT NULL DEFAULT 'authenticated_webhook',
 environment VARCHAR(32) NULL,
 store_name VARCHAR(60) NULL,
 cancel_reason VARCHAR(100) NULL,
 evidence_json JSON NOT NULL,
 processing_result VARCHAR(40) NOT NULL,
 recorded_at DATETIME NOT NULL,
 CONSTRAINT rc_event_facts_event FOREIGN KEY(event_id) REFERENCES revenuecat_events(event_id) ON DELETE CASCADE,
 INDEX rc_event_facts_environment(environment,recorded_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS revenuecat_check_facts (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 observed_at_ms BIGINT UNSIGNED NOT NULL,
 source VARCHAR(40) NOT NULL,
 environment_scope VARCHAR(32) NULL,
 project_id VARCHAR(64) NULL,
 verified_status VARCHAR(16) NOT NULL,
 recorded_at DATETIME NOT NULL,
 CONSTRAINT rc_check_facts_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
