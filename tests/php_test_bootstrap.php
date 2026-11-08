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
    require_once $accountServer . '/schema-runtime.php';
    bojiApplySchema($db, $accountServer);
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

/**
 * Publish app_config overrides in an isolated test database.
 *
 * 默认关闭的开关（P2 coach 休眠的 coach_enabled 等）在测其功能时必须显式打开，
 * 这与生产后台发布配置等价；不改默认值，只改这一个测试库的 published_json。
 * 覆盖后立即刷新该连接的配置快照，后续请求即时生效。
 */
function bojiPublishAppConfig(PDO $db, array $overrides): void {
    $row = $db->query("SELECT published_json FROM app_config WHERE config_key='app'")->fetch(PDO::FETCH_ASSOC);
    $current = [];
    if ($row && is_string($row['published_json'])) {
        $decoded = json_decode($row['published_json'], true);
        if (is_array($decoded)) $current = $decoded;
    }
    // 只合并给定键；缺失的其余键由 appConfigNormalize 补默认值。
    $published = array_replace($current, $overrides);
    $json = json_encode($published, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    if ($row) {
        $db->prepare("UPDATE app_config SET published_json=?,published_version=published_version+1,published_at=UTC_TIMESTAMP() WHERE config_key='app'")->execute([$json]);
    } else {
        $db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$json, $json]);
    }
    if (function_exists('appConfigFeatureSnapshot')) appConfigFeatureSnapshot($db, true);
}
