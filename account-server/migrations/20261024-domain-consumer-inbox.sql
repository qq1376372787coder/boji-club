-- Additive repair: durable per-consumer event deduplication.
CREATE TABLE IF NOT EXISTS domain_consumer_inbox (
 consumer VARCHAR(64) NOT NULL,
 event_id CHAR(36) NOT NULL,
 user_id BIGINT UNSIGNED NOT NULL,
 processed_at DATETIME NOT NULL,
 PRIMARY KEY (consumer,event_id),
 INDEX domain_consumer_user (user_id),
 CONSTRAINT domain_consumer_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
