CREATE TABLE IF NOT EXISTS apple_auth_nonces (
    nonce_hash CHAR(64) PRIMARY KEY,
    expires_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL,
    INDEX apple_auth_nonces_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
