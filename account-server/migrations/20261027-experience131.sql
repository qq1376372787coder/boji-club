CREATE TABLE IF NOT EXISTS ai_guard_buckets131 (
 bucket_key CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 window_start BIGINT NOT NULL,
 hits INT UNSIGNED NOT NULL DEFAULT 0,
 PRIMARY KEY(bucket_key,window_start),
 INDEX ai_guard_buckets131_expiry(window_start)
) ENGINE=InnoDB;
