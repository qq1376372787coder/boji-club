<?php
declare(strict_types=1);
/**
 * Shared PHP fixture bootstrap (AUD-016 / FIX-016).
 *
 * The archived tests hard-coded a Debian socket and root credentials. CI and
 * local isolated runs can now use:
 *   BOJI_TEST_DSN_BASE=mysql:host=127.0.0.1;port=13306
 *   BOJI_TEST_DB_USER=boji
 *   BOJI_TEST_DB_PASSWORD=...
 * and a per-suite database name. Each suite is still responsible for creating
 * its own empty database; these helpers never touch a production schema.
 */
function bojiTestDatabase(string $database): PDO {
    if (!preg_match('/^[A-Za-z0-9_]+$/D', $database)) throw new RuntimeException('Invalid test database name');
    $base = getenv('BOJI_TEST_DSN_BASE') ?: '';
    if ($base === '') {
        $socket = getenv('BOJI_TEST_MYSQL_SOCKET') ?: '/run/mysqld/mysqld.sock';
        $base = is_file($socket) || file_exists($socket)
            ? 'mysql:unix_socket=' . $socket
            : 'mysql:host=127.0.0.1;port=3306';
    }
    $dsn = rtrim($base, ';') . ';dbname=' . $database . ';charset=utf8mb4';
    return new PDO($dsn,
        getenv('BOJI_TEST_DB_USER') ?: 'root',
        getenv('BOJI_TEST_DB_PASSWORD') ?: '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
         PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
         PDO::ATTR_EMULATE_PREPARES => false]);
}

function bojiTestSchema(PDO $db, string $accountServer): void {
    $db->exec('SET FOREIGN_KEY_CHECKS=0');
    foreach (['schema.sql', 'admin-schema.sql', 'sync-schema-v59.sql', 'migrations/20261026-onboarding-v2.sql'] as $file) {
        $lines = file($accountServer . '/' . $file, FILE_IGNORE_NEW_LINES) ?: [];
        $sql = implode("\n", array_filter($lines, fn(string $line): bool => !preg_match('/^\s*--/', $line)));
        $sql = preg_replace('/(ALTER TABLE [^\n;]*?) ADD COLUMN IF NOT EXISTS/', '$1 ADD COLUMN', $sql);
        $sql = preg_replace('/(ALTER TABLE [^\n;]*?) ADD UNIQUE KEY IF NOT EXISTS/', '$1 ADD UNIQUE KEY', $sql);
        $sql = preg_replace('/(ALTER TABLE [^\n;]*?) ADD (?:KEY|INDEX) IF NOT EXISTS/', '$1 ADD KEY', $sql);
        foreach (array_filter(array_map('trim', explode(';', $sql))) as $statement) {
            try { $db->exec($statement); }
            catch (PDOException $error) {
                // MySQL lacks MariaDB's ADD COLUMN IF NOT EXISTS. On a fresh
                // isolated schema duplicate columns/indexes are already present.
                if (!in_array((int)($error->errorInfo[1] ?? 0), [1060, 1061, 1091], true)) throw $error;
            }
        }
    }
    $db->exec('SET FOREIGN_KEY_CHECKS=1');
}

/**
 * Run the real migration CLI against an isolated test database. Tests must not
 * re-implement migration SQL: that is how IA-01 drifted from production.
 * Returns [exitCode, stdout, stderr].
 */
function bojiTestRunMigration(string $database, array $args = ['--check'], string $script = 'migrate-v2-repair.php'): array {
    if (!in_array($script,['migrate-v2-repair.php','migrate-ai-context.php'],true)) throw new RuntimeException('Invalid test migration');
    if (!preg_match('/^[A-Za-z0-9_]+$/D', $database)) throw new RuntimeException('Invalid test database name');
    $base = getenv('BOJI_TEST_DSN_BASE') ?: '';
    if ($base === '') throw new RuntimeException('BOJI_TEST_DSN_BASE is required');
    $base = preg_replace('/;?dbname=[^;]*/i', '', $base);
    $dsn = rtrim($base, ';') . ';dbname=' . $database . ';charset=utf8mb4';
    $root = dirname(__DIR__);
    $command = array_merge([PHP_BINARY, $root . '/account-server/' . $script], $args);
    $env = array_merge($_ENV, [
        'BOJI_MIGRATION_DSN' => $dsn,
        'BOJI_MIGRATION_USER' => getenv('BOJI_TEST_DB_USER') ?: 'root',
        'BOJI_MIGRATION_PASSWORD' => getenv('BOJI_TEST_DB_PASSWORD') ?: '',
    ]);
    $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $process = proc_open($command, $descriptors, $pipes, $root, $env);
    if (!is_resource($process)) throw new RuntimeException('cannot start migration');
    $stdout = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]); fclose($pipes[2]);
    return [proc_close($process), (string)$stdout, (string)$stderr];
}
