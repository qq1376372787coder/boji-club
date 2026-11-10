<?php
declare(strict_types=1);
/**
 * Build 112 compatibility migration (FIX-009 / FIX-021 / AUD-021).
 *
 * Adds only missing tables/columns and never narrows an enum or deletes rows.
 * Safe to run repeatedly. Run after schema.sql; see deploy.sh. Use --check in a
 * release gate to report drift without changing the database.
 */
if (PHP_SAPI !== 'cli') exit(1);
$config = require __DIR__ . '/config.php';
if (getenv('BOJI_MIGRATION_ROOT') === '1') {
    if (!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/', $config['dsn'], $match)) throw new RuntimeException('Database name missing');
    $socket = getenv('BOJI_MYSQL_SOCKET') ?: '/run/mysqld/mysqld.sock';
    if (!str_starts_with($socket, '/') || str_contains($socket, ';')) throw new RuntimeException('Invalid database socket path');
    $config['dsn'] = 'mysql:unix_socket=' . $socket . ';dbname=' . $match[1] . ';charset=utf8mb4';
    $config['db_user'] = 'root'; $config['db_password'] = '';
}
$check = in_array('--check', $argv, true);
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$changes = [];
$missing = [];
function columnExists(PDO $db, string $table, string $column): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?');
    $q->execute([$table, $column]); return (bool)$q->fetchColumn();
}
function tableExists(PDO $db, string $table): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');
    $q->execute([$table]); return (bool)$q->fetchColumn();
}
$columns = [
    'club_automation' => [
        'paused' => "TINYINT(1) NOT NULL DEFAULT 0",
        'paused_reason' => "VARCHAR(200) NULL",
        'retry_count' => "INT UNSIGNED NOT NULL DEFAULT 0",
    ],
    'user_media' => [
        'version_file' => "VARCHAR(140) NULL",
    ],
];
foreach ($columns as $table => $definitions) {
    if (!tableExists($db, $table)) { $missing[] = "table $table"; continue; }
    foreach ($definitions as $column => $definition) {
        if (!columnExists($db, $table, $column)) {
            $missing[] = "$table.$column";
            if (!$check) { $db->exec("ALTER TABLE `$table` ADD COLUMN `$column` $definition"); $changes[] = "$table.$column"; }
        }
    }
}
$tables = [
'club_automation_runs' => "CREATE TABLE IF NOT EXISTS club_automation_runs (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 user_id BIGINT UNSIGNED NOT NULL,
 revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
 outcome ENUM('running','submitted','checked','needs_record_check','retry_pending','failed','skipped') NOT NULL DEFAULT 'running',
 tasks_submitted INT UNSIGNED NOT NULL DEFAULT 0,
 vendor_attempts INT UNSIGNED NOT NULL DEFAULT 0,
 error_summary VARCHAR(200) NULL,
 started_at DATETIME NOT NULL,
 finished_at DATETIME NULL,
 CONSTRAINT club_automation_runs_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
 INDEX club_automation_runs_started(started_at),
 INDEX club_automation_runs_user_time(user_id,started_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
'club_push_settings' => "CREATE TABLE IF NOT EXISTS club_push_settings (
 setting_key VARCHAR(80) NOT NULL PRIMARY KEY,
 setting_value VARCHAR(200) NOT NULL,
 updated_at DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
'club_push_account_blocks' => "CREATE TABLE IF NOT EXISTS club_push_account_blocks (
 user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
 reason VARCHAR(200) NOT NULL,
 blocked_by BIGINT UNSIGNED NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 CONSTRAINT club_push_account_blocks_user FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
'club_push_budget' => "CREATE TABLE IF NOT EXISTS club_push_budget (
 user_id BIGINT UNSIGNED NOT NULL,
 budget_day DATE NOT NULL,
 semantic_key VARCHAR(120) NOT NULL,
 kind VARCHAR(40) NOT NULL,
 budget_class ENUM('proactive','account','report','reminder') NOT NULL DEFAULT 'proactive',
 status ENUM('reserved','sent','skipped','failed') NOT NULL DEFAULT 'reserved',
 device_id CHAR(36) NULL,
 client_job_id CHAR(36) NULL,
 created_at DATETIME NOT NULL,
 updated_at DATETIME NOT NULL,
 PRIMARY KEY(user_id,budget_day,semantic_key),
 INDEX club_push_budget_day(budget_day,status),
 INDEX club_push_budget_owner(user_id,budget_day,budget_class,status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
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
];
foreach ($tables as $table => $sql) {
    if (!tableExists($db, $table)) {
        $missing[] = "table $table";
        if (!$check) { $db->exec($sql); $changes[] = "table $table"; }
    }
}
if (!$check) {
    $db->exec("INSERT IGNORE INTO club_push_settings(setting_key,setting_value,updated_at) VALUES('proactive_daily_limit','1',UTC_TIMESTAMP())");
}
// Preserve every existing AI task kind and add the runtime-required set.
$kindColumn = $db->query("SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ai_user_jobs' AND COLUMN_NAME='kind'")->fetchColumn();
if (is_string($kindColumn)) {
    preg_match_all("/'((?:[^']|'')*)'/", $kindColumn, $matches);
    $existing = array_map(static fn(string $value): string => str_replace("''", "'", $value), $matches[1] ?? []);
    $required = ['generate_plan', 'parse_plan', 'food', 'report', 'weekly_review', 'coach'];
    if (array_diff($required, $existing)) {
        $missing[] = 'ai_user_jobs.kind coach';
        if (!$check) {
            $kinds = array_values(array_unique(array_merge($existing, $required)));
            $quoted = implode(',', array_map(static fn(string $kind): string => "'" . str_replace("'", "''", $kind) . "'", $kinds));
            $db->exec("ALTER TABLE ai_user_jobs MODIFY kind ENUM($quoted) NOT NULL");
            $changes[] = 'ai_user_jobs.kind union';
        }
    }
}
// R10: Dynamic migration check for account_deletions.status including 'failed'
if (tableExists($db, 'account_deletions')) {
    $statusCol = $db->query("SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='account_deletions' AND COLUMN_NAME='status'")->fetchColumn();
    if (is_string($statusCol)) {
        preg_match_all("/'((?:[^']|'')*)'/", $statusCol, $matches);
        $existingStatus = array_map(static fn(string $value): string => str_replace("''", "'", $value), $matches[1] ?? []);
        if (!in_array('failed', $existingStatus, true)) {
            $missing[] = 'account_deletions.status failed';
            if (!$check) {
                $statuses = array_values(array_unique(array_merge($existingStatus, ['queued', 'retrying', 'completed', 'failed'])));
                $quotedStatus = implode(',', array_map(static fn(string $s): string => "'" . str_replace("'", "''", $s) . "'", $statuses));
                $db->exec("ALTER TABLE account_deletions MODIFY status ENUM($quotedStatus) NOT NULL");
                $changes[] = 'account_deletions.status failed';
            }
        }
    }
}
// R04/R10: Dynamic migration check for club_push_budget.budget_class including 'reminder'
if (tableExists($db, 'club_push_budget')) {
    $budgetCol = $db->query("SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='club_push_budget' AND COLUMN_NAME='budget_class'")->fetchColumn();
    if (is_string($budgetCol)) {
        preg_match_all("/'((?:[^']|'')*)'/", $budgetCol, $matches);
        $existingBudget = array_map(static fn(string $value): string => str_replace("''", "'", $value), $matches[1] ?? []);
        $requiredBudget = ['proactive', 'account', 'report', 'reminder'];
        if (array_diff($requiredBudget, $existingBudget)) {
            $missing[] = 'club_push_budget.budget_class reminder';
            if (!$check) {
                $classes = array_values(array_unique(array_merge($existingBudget, $requiredBudget)));
                $quotedBudget = implode(',', array_map(static fn(string $c): string => "'" . str_replace("'", "''", $c) . "'", $classes));
                $db->exec("ALTER TABLE club_push_budget MODIFY budget_class ENUM($quotedBudget) NOT NULL DEFAULT 'proactive'");
                $changes[] = 'club_push_budget.budget_class reminder';
            }
        }
    }
}
if ($check) {
    echo $missing ? "DRIFT\n" . implode("\n", $missing) . "\n" : "SCHEMA_OK\n";
    exit($missing ? 2 : 0);
}
echo "BUILD112_MIGRATION_OK changes=" . count($changes) . "\n";
foreach ($changes as $change) echo "APPLIED $change\n";
