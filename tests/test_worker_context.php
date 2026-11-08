<?php
declare(strict_types=1);
/** IA-06: the real CLI dependency set must inject confirmed memory. */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/app-config.php';
require __DIR__ . '/../account-server/public/action-support.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/ai-conversations.php';
require __DIR__ . '/../account-server/public/ai-memory.php';
require __DIR__ . '/../account-server/public/insights.php';
require __DIR__ . '/../account-server/public/cloud-parts.php';
require __DIR__ . '/../account-server/public/ai-entitlements.php';
require __DIR__ . '/../account-server/public/capability-registry.php';
require __DIR__ . '/../account-server/public/ai-runs.php';
require_once __DIR__ . '/../account-server/public/action-jobs.php';
function fail(string $message, int $code = 400): never { throw new RuntimeException($message, $code); }
function lockActiveUser(PDO $db, int $uid): void { $q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn())throw new RuntimeException('inactive'); }
function respond(int $status, array $body = []): never { throw new RuntimeException('respond:' . $status, $status); }
function check(bool $condition, string $message): void { if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); } }

$base = new PDO(getenv('BOJI_TEST_DSN_BASE'), getenv('BOJI_TEST_DB_USER') ?: 'root', getenv('BOJI_TEST_DB_PASSWORD') ?: '', [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS bojiclub_worker_context_test');
$base->exec('CREATE DATABASE bojiclub_worker_context_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db = bojiTestDatabase('bojiclub_worker_context_test');
bojiTestSchema($db, __DIR__ . '/../account-server');
$db->exec('SET FOREIGN_KEY_CHECKS=0');
foreach (['ai_run_events','ai_runs','ai_action_messages','ai_messages','ai_conversations','ai_user_jobs','user_action_preferences','users','app_config','user_memory_items'] as $t) { try { $db->exec('DELETE FROM ' . $t); } catch (Throwable) {} }
$db->exec('SET FOREIGN_KEY_CHECKS=1');
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13910000011','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$uid = (int)$db->lastInsertId();
$published = appConfigDefaults(); $published['ai_enabled']=true; $published['ai_streaming_v2']=true; $published['action_system_enabled']=true; $published['coach_enabled']=true;
$db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([json_encode($published),json_encode($published)]);
$memory = [
 ['preference','我更喜欢早上训练','pref-1',80],
 ['constraint','膝盖不适，避免跳跃动作','limit-1',100],
 ['correction','已纠正：目前不安排胸部训练','corr-1',100],
];
$insert = $db->prepare("INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,source_revision,created_at,updated_at) VALUES(?,?,?,'active','user',?,?,'[]',?,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())");
foreach ($memory as [$kind,$content,$slug,$confidence]) $insert->execute([actionUUID('memory/'.$slug),$uid,$kind,$content,$confidence,'mem-'.$slug]);
$conversation = 'aaaaaaaa-bbbb-cccc-dddd-fffffffffff9';
$client = actionUUID('worker-context');
$run = aiRunCreate($db, ['id'=>$uid], ['otp_secret'=>str_repeat('x',64),'membership_enforcement'=>false,'ai_max_active_runs'=>2],
    $conversation, ['client_message_id'=>$client,'message'=>['type'=>'text','text'=>'今天练什么'],
    'request'=>['kind'=>'coach','date'=>'2026-10-25','payload'=>['conversation_id'=>$conversation,'question'=>'今天练什么','days'=>[],'history'=>[]]]], $client);
define('BOJI_AI_RUN_WORKER_LIBRARY', true);
require __DIR__ . '/../account-server/process-ai-runs.php';
$claimed = aiRunWorkerClaim($db, 1);
check(count($claimed) === 1, 'worker claims the context fixture');
$request = aiRunWorkerRequest($db, $claimed[0], ['otp_secret'=>str_repeat('x',64)]);
$texts = array_column($request['payload']['memory'] ?? [], 'text');
check(in_array('我更喜欢早上训练', $texts, true), 'confirmed preference reaches the model context');
check(in_array('膝盖不适，避免跳跃动作', $texts, true), 'confirmed limitation reaches the model context');
check(in_array('已纠正：目前不安排胸部训练', $texts, true), 'confirmed correction reaches the model context');
check(($request['payload']['_context_status']['memory'] ?? '') === 'injected', 'memory injection is observable');
check(function_exists('cloudStoredState'), 'CLI dependency cloudStoredState is loaded');
check(function_exists('insightHomeToday'), 'CLI dependency insightHomeToday is loaded');
echo "WORKER_CONTEXT_OK\n";
