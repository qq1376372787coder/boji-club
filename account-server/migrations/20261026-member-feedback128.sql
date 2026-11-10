CREATE TABLE IF NOT EXISTS member_feedback_tickets (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 category ENUM('problem','suggestion','other') NOT NULL,
 status ENUM('open','replied','closed') NOT NULL DEFAULT 'open',
 title VARCHAR(100) NOT NULL,
 metadata_json TEXT NOT NULL,
 last_message_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
 user_read_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 INDEX feedback_owner(user_id,updated_at), INDEX feedback_queue(status,updated_at),
 CONSTRAINT feedback_ticket_owner FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_feedback_messages (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 ticket_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 client_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 author ENUM('member','admin') NOT NULL,
 admin_id BIGINT UNSIGNED NULL,
 body TEXT NOT NULL,
 request_hash CHAR(64) CHARACTER SET ascii NOT NULL,
 created_at DATETIME NOT NULL,
 UNIQUE KEY feedback_message_once(ticket_id,client_id),
 INDEX feedback_thread(ticket_id,id),
 CONSTRAINT feedback_message_ticket FOREIGN KEY(ticket_id) REFERENCES member_feedback_tickets(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS member_feedback_attachments (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 message_id BIGINT UNSIGNED NULL,
 kind ENUM('image','video') NOT NULL,
 mime VARCHAR(40) NOT NULL,
 storage_name VARCHAR(90) CHARACTER SET ascii NOT NULL,
 original_sha256 CHAR(64) CHARACTER SET ascii NOT NULL,
 content_sha256 CHAR(64) CHARACTER SET ascii NOT NULL,
 byte_size BIGINT UNSIGNED NOT NULL,
 duration_seconds DECIMAL(8,3) NULL,
 created_at DATETIME NOT NULL,
 INDEX feedback_media_owner(user_id,created_at), INDEX feedback_media_message(message_id),
 CONSTRAINT feedback_attachment_owner FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 CONSTRAINT feedback_attachment_message FOREIGN KEY(message_id) REFERENCES member_feedback_messages(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
