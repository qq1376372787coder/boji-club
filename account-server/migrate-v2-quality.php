<?php
declare(strict_types=1);
/**
 * V2.0 quality migration: roles, published app config, one-time Apple nonces,
 * and account-scoped RevenueCat transaction ids. Additive only; safe to rerun.
 * Use --check in a release gate to report drift without changing data.
 */
if (PHP_SAPI !== 'cli') exit(1);
$config = require __DIR__ . '/config.php';
// Isolated migration tests may point at a disposable database without
// writing a production config. The DSN is still validated by PDO.
if (($dsn = getenv('BOJI_MIGRATION_DSN')) !== false && $dsn !== '') {
    $config['dsn'] = $dsn;
    if (($user = getenv('BOJI_MIGRATION_USER')) !== false && $user !== '') $config['db_user'] = $user;
    if (($password = getenv('BOJI_MIGRATION_PASSWORD')) !== false) $config['db_password'] = $password;
}
if (getenv('BOJI_MIGRATION_ROOT') === '1') {
    if (!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/', $config['dsn'], $match)) throw new RuntimeException('Database name missing');
    $socket = getenv('BOJI_MYSQL_SOCKET') ?: '/run/mysqld/mysqld.sock';
    if (!str_starts_with($socket, '/') || str_contains($socket, ';')) throw new RuntimeException('Invalid database socket path');
    $config['dsn'] = 'mysql:unix_socket=' . $socket . ';dbname=' . $match[1] . ';charset=utf8mb4';
    $config['db_user'] = 'root'; $config['db_password'] = '';
}
$check = in_array('--check', $argv, true);
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$drift = []; $changes = [];

function tableExists(PDO $db, string $table): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');
    $q->execute([$table]); return (bool)$q->fetchColumn();
}
function columnExists(PDO $db, string $table, string $column): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?');
    $q->execute([$table, $column]); return (bool)$q->fetchColumn();
}
function uniqueIndexes(PDO $db, string $table, string $column): array {
    $q = $db->prepare("SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=? AND NON_UNIQUE=0 AND INDEX_NAME<>'PRIMARY'");
    $q->execute([$table, $column]); return $q->fetchAll(PDO::FETCH_COLUMN);
}

if (!tableExists($db, 'admin_accounts')) {
    $drift[] = 'table admin_accounts';
} else {
    $addRoles = !columnExists($db, 'admin_accounts', 'role');
    if ($addRoles) {
        $drift[] = 'admin_accounts.role';
        if (!$check) {
            $db->exec("ALTER TABLE admin_accounts ADD COLUMN role ENUM('super_admin','operator','content','support','readonly') NOT NULL DEFAULT 'readonly' AFTER password_hash");
            // Existing admins had unrestricted access before roles existed.
            $db->exec("UPDATE admin_accounts SET role='super_admin' WHERE role='readonly'");
            $changes[] = 'admin_accounts.role';
        }
    }
    if (!columnExists($db, 'admin_accounts', 'status')) {
        $drift[] = 'admin_accounts.status';
        if (!$check) {
            $db->exec("ALTER TABLE admin_accounts ADD COLUMN status ENUM('active','disabled') NOT NULL DEFAULT 'active' AFTER role");
            $changes[] = 'admin_accounts.status';
        }
    }
}

$newTables = [
    'app_config' => "CREATE TABLE IF NOT EXISTS app_config (
        config_key VARCHAR(64) PRIMARY KEY,
        draft_json TEXT NOT NULL,
        published_json TEXT NULL,
        draft_version INT UNSIGNED NOT NULL DEFAULT 0,
        published_version INT UNSIGNED NOT NULL DEFAULT 0,
        updated_by BIGINT UNSIGNED NULL,
        updated_at DATETIME NOT NULL,
        published_at DATETIME NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'app_config_versions' => "CREATE TABLE IF NOT EXISTS app_config_versions (
        id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        config_key VARCHAR(64) NOT NULL,
        version INT UNSIGNED NOT NULL,
        value_json TEXT NOT NULL,
        action ENUM('draft','publish','rollback') NOT NULL,
        admin_id BIGINT UNSIGNED NULL,
        note VARCHAR(300) NOT NULL DEFAULT '',
        created_at DATETIME NOT NULL,
        INDEX app_config_versions_key (config_key,version)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",

    'data_operations' => "CREATE TABLE IF NOT EXISTS data_operations (
        operation_id CHAR(36) PRIMARY KEY,
        user_id BIGINT UNSIGNED NOT NULL,
        actor ENUM('user','ai','system','admin') NOT NULL,
        command_type VARCHAR(60) NOT NULL,
        payload_hash CHAR(64) NOT NULL,
        aggregate_type VARCHAR(40) NOT NULL,
        aggregate_id VARCHAR(80) NOT NULL,
        before_version VARCHAR(40) NULL,
        after_version VARCHAR(40) NOT NULL,
        diff_json MEDIUMTEXT NULL,
        status ENUM('succeeded','failed','compensated') NOT NULL DEFAULT 'succeeded',
        created_at DATETIME NOT NULL,
        CONSTRAINT data_operations_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
        INDEX data_ops_user_time(user_id, created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
    'domain_outbox' => "CREATE TABLE IF NOT EXISTS domain_outbox (
        event_id CHAR(36) PRIMARY KEY,
        operation_id CHAR(36) NOT NULL,
        user_id BIGINT UNSIGNED NOT NULL,
        aggregate_type VARCHAR(40) NOT NULL,
        aggregate_id VARCHAR(80) NOT NULL,
        aggregate_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
        event_type VARCHAR(60) NOT NULL,
        payload MEDIUMTEXT NOT NULL,
        status ENUM('pending','processing','published','dead_letter') NOT NULL DEFAULT 'pending',
        attempts INT UNSIGNED NOT NULL DEFAULT 0,
        next_attempt DATETIME NOT NULL,
        lease_token CHAR(36) NULL,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        CONSTRAINT domain_outbox_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
        INDEX outbox_due(status, next_attempt)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    'apple_auth_nonces' => "CREATE TABLE IF NOT EXISTS apple_auth_nonces (
        nonce_hash CHAR(64) PRIMARY KEY,
        expires_at DATETIME NOT NULL,
        created_at DATETIME NOT NULL,
        INDEX apple_auth_nonces_expiry (expires_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",

    // M-1 (Phase 2 §2.3): server-side conversation storage. Expand-only.
    'ai_conversations' => "CREATE TABLE IF NOT EXISTS ai_conversations (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_messages' => "CREATE TABLE IF NOT EXISTS ai_messages (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_message_cards' => "CREATE TABLE IF NOT EXISTS ai_message_cards (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_action_proposals' => "CREATE TABLE IF NOT EXISTS ai_action_proposals (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_action_executions' => "CREATE TABLE IF NOT EXISTS ai_action_executions (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'user_memory_items' => "CREATE TABLE IF NOT EXISTS user_memory_items (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_feedback_events' => "CREATE TABLE IF NOT EXISTS ai_feedback_events (
        id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT UNSIGNED NOT NULL,
        kind VARCHAR(40) NOT NULL,
        name VARCHAR(60) NULL,
        target_id VARCHAR(80) NULL,
        action VARCHAR(30) NULL,
        detail_json MEDIUMTEXT NULL,
        created_at DATETIME NOT NULL,
        INDEX ai_feedback_events_user (user_id, kind, created_at),
        INDEX ai_feedback_events_name (name, created_at),
        CONSTRAINT ai_feedback_events_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    'ai_usage_ledger' => "CREATE TABLE IF NOT EXISTS ai_usage_ledger (
        id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT UNSIGNED NOT NULL,
        server_job_id CHAR(36) NULL,
        kind VARCHAR(30) NOT NULL,
        status VARCHAR(20) NOT NULL,
        latency_ms INT UNSIGNED NULL,
        prompt_tokens INT UNSIGNED NULL,
        completion_tokens INT UNSIGNED NULL,
        provider VARCHAR(30) NULL,
        created_at DATETIME NOT NULL,
        INDEX ai_usage_ledger_user (user_id, created_at),
        INDEX ai_usage_ledger_kind (kind, created_at),
        CONSTRAINT ai_usage_ledger_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
];
foreach ($newTables as $table => $sql) {
    if (!tableExists($db, $table)) {
        $drift[] = "table $table";
        if (!$check) { $db->exec($sql); $changes[] = "table $table"; }
    }
}

if (tableExists($db, 'membership_entitlements')) {
    $unique = uniqueIndexes($db, 'membership_entitlements', 'last_transaction_id');
    if ($unique) {
        $drift[] = 'membership_entitlements.last_transaction_id UNIQUE';
        if (!$check) {
            foreach ($unique as $index) {
                if (!preg_match('/^[A-Za-z0-9_]+$/D', (string)$index)) throw new RuntimeException('Unexpected index name');
                $db->exec("ALTER TABLE membership_entitlements DROP INDEX `" . $index . "`");
            }
            if (!uniqueIndexes($db, 'membership_entitlements', 'last_transaction_id')) {
                $db->exec('ALTER TABLE membership_entitlements ADD INDEX membership_entitlements_transaction (last_transaction_id)');
            }
            $changes[] = 'membership_entitlements transaction index';
        }
    }
}

if ($check) {
    if ($drift) { echo "SCHEMA_DRIFT\n" . implode("\n", $drift) . "\n"; exit(2); }
    echo "SCHEMA_OK\n"; exit(0);
}
echo $changes ? ('APPLIED ' . implode(', ', $changes) . "\n") : "SCHEMA_OK\n";
