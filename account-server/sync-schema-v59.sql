CREATE TABLE IF NOT EXISTS cloud_parts (
 user_id BIGINT UNSIGNED NOT NULL,
 part_key VARCHAR(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 payload_json LONGTEXT NOT NULL,
 content_hash CHAR(64) CHARACTER SET ascii NOT NULL,
 date_key CHAR(10) CHARACTER SET ascii NULL,
 byte_size INT UNSIGNED NOT NULL,
 PRIMARY KEY(user_id,part_key), INDEX cloud_parts_date(user_id,date_key),
 CONSTRAINT cloud_parts_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS cloud_meal_sources (
 user_id BIGINT UNSIGNED NOT NULL,
 source_hash CHAR(64) CHARACTER SET ascii NOT NULL,
 date_key CHAR(10) CHARACTER SET ascii NOT NULL,
 PRIMARY KEY(user_id,source_hash,date_key), INDEX cloud_sources_date(user_id,date_key),
 CONSTRAINT cloud_sources_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS cloud_media_refs (
 user_id BIGINT UNSIGNED NOT NULL,
 media_id VARCHAR(80) CHARACTER SET ascii NOT NULL,
 date_key CHAR(10) CHARACTER SET ascii NOT NULL,
 PRIMARY KEY(user_id,media_id,date_key), INDEX cloud_refs_date(user_id,date_key),
 CONSTRAINT cloud_refs_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS cloud_uploads (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 base_revision BIGINT UNSIGNED NOT NULL,
 expected_parts INT UNSIGNED NOT NULL,
 status ENUM('uploading','committed') NOT NULL DEFAULT 'uploading',
 committed_revision BIGINT UNSIGNED NULL,
 updated_at DATETIME NOT NULL,
 INDEX cloud_upload_user(user_id,updated_at),
 CONSTRAINT cloud_upload_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS cloud_upload_parts (
 upload_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 part_key VARCHAR(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 payload_json LONGTEXT NULL,
 PRIMARY KEY(upload_id,part_key),
 CONSTRAINT cloud_upload_parts_fk FOREIGN KEY(upload_id) REFERENCES cloud_uploads(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS storage_settings (
 setting_key VARCHAR(60) CHARACTER SET ascii NOT NULL PRIMARY KEY,
 setting_value BIGINT UNSIGNED NOT NULL,
 updated_at DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS cloud_upload_meal_sources (
 upload_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 source_hash CHAR(64) CHARACTER SET ascii NOT NULL,
 date_key CHAR(10) CHARACTER SET ascii NOT NULL,
 PRIMARY KEY(upload_id,source_hash,date_key), INDEX cloud_upload_sources_date(upload_id,date_key),
 CONSTRAINT cloud_upload_sources_fk FOREIGN KEY(upload_id) REFERENCES cloud_uploads(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT IGNORE INTO storage_settings(setting_key,setting_value,updated_at) VALUES
 ('media_storage_limit_bytes',0,UTC_TIMESTAMP()),('media_file_limit',0,UTC_TIMESTAMP()),
 ('media_uploads_per_minute',120,UTC_TIMESTAMP());
CREATE TABLE IF NOT EXISTS media_upload_events (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 uploaded_at DATETIME NOT NULL,
 INDEX media_upload_user_time(user_id,uploaded_at), INDEX media_upload_expiry(uploaded_at),
 CONSTRAINT media_upload_events_user_fk FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
