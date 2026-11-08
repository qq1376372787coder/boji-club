<?php
declare(strict_types=1);
/** IA-12: one trace links Run → message → action → proposal → command → Outbox. */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/app-config.php';
require __DIR__ . '/../account-server/public/action-support.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/ai-conversations.php';
require __DIR__ . '/../account-server/public/ai-entitlements.php';
require __DIR__ . '/../account-server/public/ai-memory.php';
require __DIR__ . '/../account-server/public/insights.php';
require __DIR__ . '/../account-server/public/cloud-parts.php';
require __DIR__ . '/../account-server/public/capability-registry.php';
require __DIR__ . '/../account-server/public/ai-router.php';
require __DIR__ . '/../account-server/public/ai-runs.php';
function fail(string $message, int $code = 400): never { throw new RuntimeException($message, $code); }
function lockActiveUser(PDO $db, int $uid): void { $q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn())throw new RuntimeException('inactive'); }
function respond(int $status, array $body = []): never { throw new RuntimeException('respond:' . $status, $status); }
function check(bool $condition, string $message): void { if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); } }

$base = new PDO(getenv('BOJI_TEST_DSN_BASE'), getenv('BOJI_TEST_DB_USER') ?: 'root', getenv('BOJI_TEST_DB_PASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS bojiclub_trace_chain_test');
$base->exec('CREATE DATABASE bojiclub_trace_chain_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db = bojiTestDatabase('bojiclub_trace_chain_test');
bojiTestSchema($db, __DIR__ . '/../account-server');
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13910000021','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$uid = (int)$db->lastInsertId();
$user = ['id' => $uid, 'status' => 'active'];
$published = appConfigDefaults(); $published['ai_enabled']=true; $published['ai_streaming_v2']=true; $published['action_system_enabled']=true; $published['coach_enabled']=true;
$db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([json_encode($published),json_encode($published)]);
$db->prepare("INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE state_json=VALUES(state_json)")->execute([$uid,json_encode(['days'=>[]])]);
$config = ['otp_secret'=>str_repeat('x',64),'membership_enforcement'=>false,'ai_max_active_runs'=>4];
$conversation = 'aaaaaaaa-bbbb-cccc-dddd-fffffffffff8';
$client = actionUUID('trace-client');
$run = aiRunCreate($db, $user, $config, $conversation, [
  'client_message_id'=>$client, 'message'=>['type'=>'text','text'=>'记录午餐'],
  'request'=>['kind'=>'coach','date'=>actionToday($db,$uid),'payload'=>['conversation_id'=>$conversation,'question'=>'记录午餐','days'=>[],'history'=>[]]],
], $client);
$trace = $run['trace_id'];
check(strlen($trace) === 32, 'run has a trace');

// A read-only action call inherits the message trace.
$GLOBALS['boji_trace_id'] = $trace;
$call = ['capability'=>'training.get_today','input'=>[]];
$result = actionCallResolve($db, $user, $call, $client, 0, $conversation);
check(($result['status'] ?? '') === 'completed', 'read action resolves');
$callRow = $db->prepare('SELECT trace_id FROM ai_action_calls WHERE user_id=? AND message_id=? LIMIT 1');
$callRow->execute([$uid, $client]);
check((string)$callRow->fetchColumn() === $trace, 'action call carries the run trace');
$messageRow = $db->prepare('SELECT trace_id FROM ai_action_messages WHERE user_id=? AND message_id=?');
$messageRow->execute([$uid, $client]);
check((string)$messageRow->fetchColumn() === $trace, 'action message carries the run trace');

// A user-confirmed meal proposal created under the same trace.
$GLOBALS['boji_trace_id'] = $trace;
$proposal = aiProposalCreate($db, $uid, 'meal_draft', [
  'date'=>actionToday($db,$uid),
  'meals'=>[['name'=>'米饭','category'=>'午餐','calories'=>232,'protein'=>5.2,'carbs'=>51.8,'fat'=>0.6,'estimated'=>false]],
], [], $conversation, null);
$confirmed = actionConfirmProposal($db, $user, $proposal['proposal_id']);
check(($confirmed['status'] ?? '') === 'succeeded', 'proposal confirms');
$proposalTrace = $db->prepare('SELECT trace_id FROM ai_action_proposals WHERE user_id=? AND proposal_id=?');
$proposalTrace->execute([$uid, $proposal['proposal_id']]);
check((string)$proposalTrace->fetchColumn() === $trace, 'proposal carries trace');
$command = $db->prepare('SELECT operation_id,trace_id FROM data_operations WHERE user_id=? AND trace_id=? ORDER BY created_at DESC LIMIT 1');
$command->execute([$uid, $trace]);
$commandRow = $command->fetch(PDO::FETCH_ASSOC);
check($commandRow !== false, 'command is linked by trace');
$outbox = $db->prepare('SELECT event_id FROM domain_outbox WHERE user_id=? AND trace_id=? LIMIT 1');
$outbox->execute([$uid, $trace]);
check($outbox->fetchColumn() !== false, 'outbox event is linked by trace');
echo json_encode(['trace'=>$trace,'run'=>$run['run_id'],'proposal'=>$proposal['proposal_id'],'command'=>$commandRow['operation_id']])."\n";
echo "TRACE_CHAIN_OK\n";
