<?php
declare(strict_types=1);
/**
 * Durable Run + SSE for the non-coach kinds (report / weekly_review).
 *
 * Phase 3: the Run path must share the polling path's Python job identity, be
 * flag-gated, be idempotent per client_job_id, and hand the worker a payload it
 * can submit unchanged.
 *
 * Run only against a disposable MySQL/MariaDB:
 *   BOJI_TEST_DSN_BASE="mysql:host=127.0.0.1;port=3306" bash tests/run_action_checks.sh
 */
require __DIR__ . '/php_test_bootstrap.php';
define('BOJI_AI_RUN_WORKER_LIBRARY', true);
require __DIR__ . '/../account-server/process-ai-runs.php';

function fail(string $message, int $code = 400): never { throw new RuntimeException($message, $code); }
function lockActiveUser(PDO $db, int $uid): void {
    $query = $db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");
    $query->execute([$uid]);
    if (!$query->fetchColumn()) throw new RuntimeException('inactive_account');
}
function respond(int $status, array $body = []): never { throw new RuntimeException('respond:' . $status, $status); }
function check(bool $condition, string $message): void {
    $GLOBALS['audit_kinds_checks']=($GLOBALS['audit_kinds_checks']??0)+1;
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}
function expectCode(int $code, callable $operation, string $message): void {
    try { $operation(); }
    catch (RuntimeException $error) { check($error->getCode() === $code, $message . ' (got ' . $error->getCode() . ')'); return; }
    check(false, $message . ' (no exception)');
}

$database = 'bojiclub_audit_kinds_test';
$base = new PDO(getenv('BOJI_TEST_DSN_BASE'), getenv('BOJI_TEST_DB_USER') ?: 'root',
    getenv('BOJI_TEST_DB_PASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS ' . $database);
$base->exec('CREATE DATABASE ' . $database . ' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db = bojiTestDatabase($database);
bojiTestSchema($db, __DIR__ . '/../account-server');

$db->exec('SET FOREIGN_KEY_CHECKS=0');
foreach (['ai_run_events','ai_runs','ai_user_jobs','ai_usage_ledger','users','app_config','membership_entitlements'] as $table) {
    try { $db->exec('DELETE FROM ' . $table); } catch (Throwable) {}
}
$db->exec('SET FOREIGN_KEY_CHECKS=1');
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13920000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$user = ['id' => (int)$db->lastInsertId(), 'status' => 'active'];
$db->prepare("INSERT INTO membership_entitlements(user_id,status,source,starts_at,expires_at,created_at,updated_at)
              VALUES(?,'active','admin',UTC_TIMESTAMP(),'2099-12-31 23:59:59',UTC_TIMESTAMP(),UTC_TIMESTAMP())")
   ->execute([$user['id']]);
$config = ['otp_secret' => str_repeat('s', 64), 'ai_proxy_token' => str_repeat('t', 32),
           'membership_enforcement' => false, 'ai_max_active_runs' => 6];

function publishFlags(PDO $db, bool $enabled, string $kinds): void {
    $published = appConfigDefaults();
    $published['ai_enabled'] = true;
    $published['ai_run_v2_enabled'] = $enabled;
    $published['ai_run_v2_kinds'] = $kinds;
    $db->prepare('INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at)
                  VALUES(\'app\',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())
                  ON DUPLICATE KEY UPDATE draft_json=VALUES(draft_json),published_json=VALUES(published_json),updated_at=UTC_TIMESTAMP()')
       ->execute([json_encode($published), json_encode($published)]);
    appConfigFeatureSnapshot($db, true);
}

function reportRequest(string $date): array {
    return ['kind' => 'report', 'date' => $date,
            'payload' => ['timeZone' => 'Asia/Shanghai', '_routing_version' => 2,
                          'exercises' => [], 'meals' => [], 'coaching_version' => 1,
                          'analysis_version' => 2, 'meals_complete' => false, 'training_confirmed' => false]];
}

function eventTypes(PDO $db, string $runId): array {
    return array_column(aiRunEvents($db, $runId, 0, 200), 'type');
}

// --- string flags survive config normalization ----------------------------
check(appConfigNormalize(['ai_run_v2_kinds' => 'report,weekly_review'])['ai_run_v2_kinds'] === 'report,weekly_review',
      'string flags normalize without being dropped');
check(appConfigNormalize(['ai_run_v2_enabled' => true])['ai_run_v2_enabled'] === true,
      'bool flags normalize');

// --- flag off: the client must fall back, never half-create ----------------
publishFlags($db, false, '');
$db->exec('DELETE FROM ai_guard_buckets131');
$offClient = actionUUID('kinds-client/off');
expectCode(503, fn() => aiRunCreateForKind($db, $user, $config, 'report',
    ['client_job_id' => $offClient, 'kind' => 'report', 'request' => reportRequest('2026-11-07')], $offClient),
    'run path is 503 while the flag is off');
$leftover = $db->prepare('SELECT COUNT(*) FROM ai_runs')->fetchColumn();
check((int)$leftover === 0, 'a refused create persists nothing');

// --- flag on: create, idempotency, shared job identity --------------------
publishFlags($db, true, 'report');
$db->exec('DELETE FROM ai_guard_buckets131');
$client = actionUUID('kinds-client/report');
$request = reportRequest('2026-11-07');
$created = aiRunCreateForKind($db, $user, $config, 'report',
    ['client_job_id' => $client, 'kind' => 'report', 'request' => $request], $client);
check($created['status'] === 'queued' && ($created['kind'] ?? '') === 'report', 'report run created');
check($created['stream_url'] === '/me/ai/runs/' . $created['run_id'] . '/events', 'stream url points at the run');
check(strlen($created['trace_id']) === 32, 'run has a trace id');

$runQuery = $db->prepare('SELECT * FROM ai_runs WHERE id=?'); $runQuery->execute([$created['run_id']]);
$run = $runQuery->fetch(PDO::FETCH_ASSOC);
check(is_array($run) && $run['status'] === 'queued' && $run['conversation_id'] === '', 'run row persisted for a non-coach kind');

$jobQuery = $db->prepare('SELECT * FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');
$jobQuery->execute([$user['id'], $client]);
$job = $jobQuery->fetch(PDO::FETCH_ASSOC);
check(is_array($job) && $job['kind'] === 'report', 'durable job row exists before any network call');
check(($job['server_job_id'] ?? '') === aiJobID($user, $client, $config), 'same server job id as the polling path');
check(eventTypes($db, $created['run_id']) === ['run.created'], 'first event is run.created');

$again = aiRunCreateForKind($db, $user, $config, 'report',
    ['client_job_id' => $client, 'kind' => 'report', 'request' => $request], $client);
check($again['run_id'] === $created['run_id'] && $again['idempotent'] === true, 'replay returns the same run');

// --- kind allowlist --------------------------------------------------------
publishFlags($db, true, 'weekly_review');
$db->exec('DELETE FROM ai_guard_buckets131');
$notAllowed = actionUUID('kinds-client/not-allowed');
expectCode(503, fn() => aiRunCreateForKind($db, $user, $config, 'report',
    ['client_job_id' => $notAllowed, 'kind' => 'report', 'request' => $request], $notAllowed),
    'kind outside the allowlist is 503');

// --- phase 1 scope ---------------------------------------------------------
expectCode(400, fn() => aiRunCreateForKind($db, $user, $config, 'food',
    ['client_job_id' => actionUUID('kinds-client/food'), 'kind' => 'food', 'request' => $request],
    actionUUID('kinds-client/food')),
    'phase 1 rejects food');

// --- worker request builder: payload passes through unchanged --------------
publishFlags($db, true, 'report,weekly_review');
$fixture = ['id' => $created['run_id'], 'user_id' => $user['id'],
            'server_job_id' => $job['server_job_id'], 'message_id' => $client,
            'trace_id' => $run['trace_id'], 'status' => 'running',
            'request_json' => json_encode($request), 'lease_owner' => 'test', 'attempts' => 1];
$built = aiRunWorkerRequest($db, $fixture, $config);
check(($built['payload']['_routing_version'] ?? null) === 2, 'worker keeps the routing consent');
check(($built['payload']['_router_v3'] ?? null) === true, 'worker injects the router flag');
check(($built['id'] ?? '') === $job['server_job_id'], 'worker targets the shared python job');
check(($built['_trace_id'] ?? '') === $run['trace_id'], 'worker carries the trace id');
check(!isset($built['payload']['memory']), 'non-coach runs inject no conversation memory');

echo "ai_runs_kinds: " . ($GLOBALS['audit_kinds_checks'] ?? 0) . " checks passed\n";
