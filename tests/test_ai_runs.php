<?php
declare(strict_types=1);
/**
 * Durable Run / SSE persistence contract (behaviour, not string checks).
 *
 * Self-contained: creates and drops its own database, applies the real
 * migration CLI, injects a real DB failure, and drives the production worker
 * functions with an explicit private-response fixture.
 *
 * Run only against a disposable MySQL/MariaDB:
 *   BOJI_TEST_DSN_BASE="mysql:unix_socket=/abs/test.sock" PHP=php bash tests/run_ai_runs.sh
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
    $GLOBALS['audit124_checks']=($GLOBALS['audit124_checks']??0)+1;
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}
function expectCode(int $code, callable $operation, string $message): void {
    try { $operation(); }
    catch (RuntimeException $error) { check($error->getCode() === $code, $message . ' (got ' . $error->getCode() . ')'); return; }
    check(false, $message . ' (no exception)');
}

$database = 'bojiclub_audit124_runs_test';
$base = new PDO(getenv('BOJI_TEST_DSN_BASE'), getenv('BOJI_TEST_DB_USER') ?: 'root',
    getenv('BOJI_TEST_DB_PASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS ' . $database);
$base->exec('CREATE DATABASE ' . $database . ' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db = bojiTestDatabase($database);
bojiTestSchema($db, __DIR__ . '/../account-server');
[$exit, $stdout, $stderr] = bojiTestRunMigration($database, ['--apply']);
check($exit === 0, 'real migration --apply must pass: ' . $stdout . $stderr);
[$exit, $stdout, $stderr] = bojiTestRunMigration($database, ['--check']);
check($exit === 0, 'real migration --check must pass: ' . $stdout . $stderr);
[$exit] = bojiTestRunMigration($database, ['--apply']);
check($exit === 0, 'repeated migration apply must be a no-op');
[$exit,$stdout,$stderr]=bojiTestRunMigration($database,['--apply'],'migrate-ai-context.php');
check($exit===0,'real context migration applies: '.$stdout.$stderr);

$db->exec('SET FOREIGN_KEY_CHECKS=0');
foreach (['ai_run_events','ai_runs','ai_action_messages','ai_messages','ai_conversations','ai_user_jobs','ai_action_calls','ai_action_jobs','user_action_preferences','domain_outbox','data_operations','ai_action_proposals','users','app_config'] as $table) {
    try { $db->exec('DELETE FROM ' . $table); } catch (Throwable) {}
}
$db->exec('SET FOREIGN_KEY_CHECKS=1');
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13910000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$userA = ['id' => (int)$db->lastInsertId(), 'status' => 'active'];
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13910000002','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$userB = ['id' => (int)$db->lastInsertId(), 'status' => 'active'];
$config = ['otp_secret' => str_repeat('s', 64), 'ai_proxy_token' => str_repeat('t', 32),
           'membership_enforcement' => false, 'ai_max_active_runs' => 6];
$published = appConfigDefaults();
$published['ai_enabled'] = true;
$published['ai_streaming_v2'] = true;
$published['action_system_enabled'] = true;
$db->prepare('INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at)
              VALUES(\'app\',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
   ->execute([json_encode($published), json_encode($published)]);

$conversation = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
function coachRequest(string $conversation, string $question): array {
    return ['kind' => 'coach', 'date' => (new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai')))->format('Y-m-d'),
            'payload' => ['conversation_id' => $conversation, 'question' => $question,
                          'history' => [], 'days' => [], 'timeZone' => 'Asia/Shanghai']];
}
function makeRun(PDO $db, array $user, array $config, string $conversation, string $question): array {
    // Independent fault scenarios use fresh rate windows; dedicated quota tests exercise 429.
    $db->exec('DELETE FROM ai_guard_buckets131');
    $client = actionUUID('audit-client/' . $question . '/' . random_int(1, 999999));
    return aiRunCreate($db, $user, $config, $conversation,
        ['client_message_id' => $client, 'message' => ['type' => 'text', 'text' => $question],
         'request' => coachRequest($conversation, $question)], $client);
}
function jobRow(PDO $db, string $runId): array {
    $query = $db->prepare('SELECT * FROM ai_runs WHERE id=?'); $query->execute([$runId]);
    return $query->fetch(PDO::FETCH_ASSOC);
}
function eventTypes(PDO $db, string $runId): array {
    return array_column(aiRunEvents($db, $runId, 0, 200), 'type');
}
function successResponse(string $answer): array {
    return ['status' => 'succeeded', 'provider' => 'fixture', 'model' => 'fixture',
            'result' => ['kind' => 'coach', 'notes' => [], 'coach' => [
                'answer' => $answer, 'sources' => [], 'actions' => [], 'cards' => []]]];
}

// --- create / idempotency / header binding --------------------------------
$created = makeRun($db, $userA, $config, $conversation, '今天练什么');
$convFail = 'aaaaaaaa-bbbb-cccc-dddd-fffffffffff1';
$convCancel = 'aaaaaaaa-bbbb-cccc-dddd-fffffffffff2';
$convOk = 'aaaaaaaa-bbbb-cccc-dddd-fffffffffff3';
check($created['status'] === 'queued' && strlen($created['trace_id']) === 32, 'run starts queued with trace');
$again = aiRunCreate($db, $userA, $config, $conversation,
    ['client_message_id' => $created['message_id'], 'message' => ['type' => 'text', 'text' => '今天练什么'],
     'request' => coachRequest($conversation, '今天练什么')], $created['message_id']);
check($again['run_id'] === $created['run_id'] && $again['idempotent'] === true, 'same identity returns same run');
expectCode(409, fn() => aiRunCreate($db, $userA, $config, $conversation,
    ['client_message_id' => $created['message_id'], 'message' => ['type' => 'text', 'text' => '换一个问题'],
     'request' => coachRequest($conversation, '换一个问题')], $created['message_id']), 'same key different payload is 409');
expectCode(409, fn() => aiRunCreate($db, $userA, $config, $conversation,
    ['client_message_id' => $created['message_id'], 'message' => ['type' => 'text', 'text' => '今天练什么'],
     'request' => coachRequest($conversation, '今天练什么')], actionUUID('different-header')), 'header must equal body message id');
check(aiRunFetch($db, $userB['id'], $created['run_id']) === null, 'another account cannot read the run');
aiRunCancel($db, $userA['id'], $created['run_id']); // release the first conversation slot for later fixtures

// --- IA-02: necessary persistence failure must not report completion ------
$failRun = makeRun($db, $userA, $config, $convFail, 'persistence failure fixture');
$claimed = aiRunWorkerClaim($db, 1);
check(count($claimed) === 1 && $claimed[0]['id'] === $failRun['run_id'], 'worker claims the queued run');
$row = $claimed[0];
// Exercise the exhausted retry budget; first-attempt recovery is tested below.
$row['attempts']=AI_RUN_MAX_ATTEMPTS;
$db->prepare('UPDATE ai_runs SET attempts=? WHERE id=?')->execute([AI_RUN_MAX_ATTEMPTS,$row['id']]);
$db->exec('DROP TRIGGER IF EXISTS audit_fail_assistant');
$db->exec("CREATE TRIGGER audit_fail_assistant BEFORE INSERT ON ai_messages FOR EACH ROW
           BEGIN IF NEW.role='assistant' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='injected assistant failure'; END IF; END");
$GLOBALS['boji_action_transport'] = function (string $method, string $path, ?array $body = null) use ($row) {
    if ($method === 'GET') return successResponse('persisted-or-not answer');
    return ['status' => 'queued'];
};
try { aiRunWorkerProcess($db, $row, $config); }
finally { $db->exec('DROP TRIGGER IF EXISTS audit_fail_assistant'); }
$failed = jobRow($db, $failRun['run_id']);
check($failed['status'] === 'failed', 'persistence failure marks run failed, not completed');
check(!in_array('run.completed', eventTypes($db, $failRun['run_id']), true), 'no completion event when message save fails');
$failedSnapshot = aiRunSnapshot($db, $userA['id'], $failRun['run_id']);
check($failedSnapshot['message'] === null, 'failed run exposes no assistant message');

// --- IA-03: cancellation fences the worker; completion is idempotent ------
$cancelRun = makeRun($db, $userA, $config, $convCancel, 'cancel fixture');
$claimed = aiRunWorkerClaim($db, 1);
check(count($claimed) === 1 && $claimed[0]['id'] === $cancelRun['run_id'], 'cancel run claimed');
$cancelRow = $claimed[0];
$db->prepare("UPDATE ai_runs SET lease_expires_at=DATE_ADD(UTC_TIMESTAMP(), INTERVAL 150 SECOND) WHERE id=?")->execute([$cancelRun['run_id']]);
aiRunCancel($db, $userA['id'], $cancelRun['run_id']);
$fenced = false;
try { aiRunWorkerComplete($db, $cancelRow, $config, successResponse('must not appear'), 5); }
catch (RuntimeException $error) { $fenced = in_array($error->getMessage(), ['run_terminal','lease_lost','lease_expired'], true); }
check($fenced || jobRow($db, $cancelRun['run_id'])['status'] === 'cancelled', 'completion after cancel is fenced');
$cancelled = jobRow($db, $cancelRun['run_id']);
check($cancelled['status'] === 'cancelled', 'cancelled state survives the late worker');
check(!in_array('run.completed', eventTypes($db, $cancelRun['run_id']), true), 'no completion event after cancel');
$snapshot = aiRunSnapshot($db, $userA['id'], $cancelRun['run_id']);
check($snapshot['run']['terminal'] === true && $snapshot['run']['status'] === 'cancelled', 'cancel is terminal');

$okRun = makeRun($db, $userA, $config, $convOk, 'duplicate completion fixture');
$claimed = aiRunWorkerClaim($db, 1);
check(count($claimed) === 1 && $claimed[0]['id'] === $okRun['run_id'], 'ok run claimed');
$okRow = $claimed[0];
$response = successResponse('one answer');
aiRunWorkerComplete($db, $okRow, $config, $response, 7);
try { aiRunWorkerComplete($db, $okRow, $config, $response, 7); } catch (Throwable $error) {
    check(in_array($error->getMessage(), ['run_terminal','lease_lost'], true), 'second completion is rejected');
}
$types = eventTypes($db, $okRun['run_id']);
check(count(array_filter($types, fn($t) => $t === 'run.completed')) === 1, 'exactly one completion event');
check(in_array('assistant.text.snapshot', $types, true), 'authoritative snapshot is emitted');
$okSnapshot = aiRunSnapshot($db, $userA['id'], $okRun['run_id']);
check(($okSnapshot['message']['coach']['answer'] ?? null) === 'one answer', 'snapshot contains the saved answer');

// Build124: real worker, real domain transaction, stable receipts before terminal SSE.
$today = (new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,updated_at) VALUES(?,1,'Asia/Shanghai','kg',UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE fast_records=1")->execute([$userA['id']]);
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$userA['id'],json_encode(['days'=>[$today=>['exercises'=>[],'meals'=>[]]]])]);
$writeRun=makeRun($db,$userA,$config,actionUUID('build124-write-conversation'),'记70公斤。');
$writeRow=aiRunWorkerClaim($db,1)[0];
$writeResponse=successResponse('按你的请求处理这次体重登记，请以服务端行动回执为准。');
$writeResponse['usage']=['prompt_tokens'=>13,'completion_tokens'=>21,'attempt_count'=>2];
$writeResponse['result']['coach']['capability_calls']=[['capability'=>'body.record_weight','input'=>['date'=>$today,'kilograms'=>70]]];
aiRunWorkerComplete($db,$writeRow,$config,$writeResponse,9);
$writeSnapshot=aiRunSnapshot($db,$userA['id'],$writeRun['run_id']);
check(($writeSnapshot['message']['coach']['action_results'][0]['status']??'')==='completed','worker obtains a real domain receipt before success');
check(actionMessageResults($db,$userA['id'],$writeRow['message_id'])['results'][0]['status']==='completed','HTTP receipt query sees worker result');
$state=$db->query('SELECT state_json FROM app_states WHERE user_id='.(int)$userA['id'])->fetchColumn();
check(count(json_decode($state,true)['days'][$today]['bodyMeasurements']??[])===1,'exactly one persisted measurement');
aiRunWorkerComplete($db,$writeRow,$config,$writeResponse,9);
$ops=$db->query("SELECT COUNT(*) FROM data_operations WHERE user_id=".(int)$userA['id']." AND command_type='BodyWeight.CreateDirect'")->fetchColumn();
check((int)$ops===1,'duplicate completion never repeats committed command');
$tokens=$db->query("SELECT prompt_tokens,completion_tokens FROM ai_usage_ledger WHERE server_job_id=".$db->quote($writeRow['server_job_id']))->fetch();
check((int)$tokens['prompt_tokens']===13 && (int)$tokens['completion_tokens']===21,'trusted transport usage persists');
// Cancelled and expired workers cannot launch later writes.
$cancelWrite=makeRun($db,$userA,$config,actionUUID('build124-cancel-conversation'),'记71公斤。');
$cancelWriteRow=aiRunWorkerClaim($db,1)[0];
aiRunCancel($db,$userA['id'],$cancelWrite['run_id']);
aiRunWorkerComplete($db,$cancelWriteRow,$config,$writeResponse,9);
check(actionMessageResults($db,$userA['id'],$cancelWriteRow['message_id'])['results']===[],'cancel before action produces no child');
$expired=makeRun($db,$userA,$config,actionUUID('build124-lease-conversation'),'记72公斤。');
$expiredRow=aiRunWorkerClaim($db,1)[0];
$db->prepare("UPDATE ai_runs SET lease_owner='replacement-worker' WHERE id=?")->execute([$expiredRow['id']]);
try { aiRunWorkerComplete($db,$expiredRow,$config,$writeResponse,9); check(false,'stale owner accepted'); }
catch(RuntimeException $e){check($e->getMessage()==='lease_lost','stale worker is fenced before command');}
check(actionMessageResults($db,$userA['id'],$expiredRow['message_id'])['results']===[],'stale worker has no action receipt');
aiRunCancel($db,$userA['id'],$expired['run_id']);
echo "PASS Build124 worker business receipts, duplicate replay, cancellation, lease fencing, usage\n";

$expiredTime=makeRun($db,$userA,$config,actionUUID('build124-expired-time'),'记录体重73公斤。');
$expiredTimeRow=aiRunWorkerClaim($db,1)[0];
$db->prepare("UPDATE ai_runs SET lease_expires_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 SECOND) WHERE id=?")->execute([$expiredTimeRow['id']]);
try{aiRunWorkerComplete($db,$expiredTimeRow,$config,$writeResponse,9);check(false,'expired lease revived');}
catch(RuntimeException $e){check($e->getMessage()==='lease_lost','expired unchanged owner cannot renew itself');}
check(actionMessageResults($db,$userA['id'],$expiredTimeRow['message_id'])['results']===[],'expired lease produces no writes');
aiRunCancel($db,$userA['id'],$expiredTimeRow['id']);
// Losing a lease inside action resolution must not settle the new owner's message.
$midLease=makeRun($db,$userA,$config,actionUUID('build124-mid-lease'),'记录体重73公斤。');
$midRow=aiRunWorkerClaim($db,1)[0];
$db->prepare("UPDATE ai_runs SET lease_owner='new-owner' WHERE id=?")->execute([$midRow['id']]);
try{actionWithParent($userA['id'],$midRow['message_id'],fn()=>actionResolveCompletedMessage($db,$userA,$midRow['message_id'],$writeResponse),$midRow['lease_owner']);check(false,'stale owner settled message');}
catch(BusinessActionError $e){check(($e->detail['code']??'')==='PARENT_LEASE_LOST','stale settle is fenced');}
$statusQuery=$db->prepare('SELECT status FROM ai_action_messages WHERE user_id=? AND message_id=?');$statusQuery->execute([$userA['id'],$midRow['message_id']]);
check($statusQuery->fetchColumn()==='accepted','new owner retains unresolved action');
aiRunCancel($db,$userA['id'],$midRow['id']);
// Crash after domain commit: replay the original call, not another operation.
$crash=makeRun($db,$userA,$config,actionUUID('build124-crash-conversation'),'记录体重71公斤。');
$crashRow=aiRunWorkerClaim($db,1)[0];$crashResponse=$writeResponse;
$crashResponse['result']['coach']['capability_calls'][0]['input']['kilograms']=71;
$resolved=actionWithParent($userA['id'],$crashRow['message_id'],fn()=>actionResolveCompletedMessage($db,$userA,$crashRow['message_id'],$crashResponse),$crashRow['lease_owner']);
check($resolved['results'][0]['status']==='completed','domain committed before simulated worker crash');
$crashRow['attempts']=2;$postCount=0;
$GLOBALS['boji_action_transport']=function($method,$path)use(&$postCount,$crashResponse){if($method==='POST'){$postCount++;throw new RuntimeException('changed_context_must_not_resubmit',409);}return $crashResponse;};
aiRunWorkerProcess($db,$crashRow,$config);unset($GLOBALS['boji_action_transport']);
check($postCount===0,'recovery reuses original private job without context resubmission');
check(jobRow($db,$crashRow['id'])['status']==='completed','whole worker recovers a committed action');
check((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE user_id=".(int)$userA['id']." AND command_type='BodyWeight.CreateDirect'")->fetchColumn()===2,'crash replay uses stable command identity');
// Consent withdrawn while the model was running fences actions before domain IO.
$revoked=makeRun($db,$userA,$config,actionUUID('build124-consent-withdrawn'),'记录体重74公斤。');
$revokedRow=aiRunWorkerClaim($db,1)[0];$revokedRequest=json_decode($revokedRow['request_json'],true);$revokedRequest['payload']['_routing_version']=3;
$revokedRow['request_json']=json_encode($revokedRequest);
$db->prepare('UPDATE ai_runs SET request_json=? WHERE id=?')->execute([$revokedRow['request_json'],$revokedRow['id']]);
$db->prepare("INSERT INTO ai_provider_consents(user_id,allowed,notice_version,updated_at) VALUES(?,0,'2026-10-26.deepseek-minimax-v1',UTC_TIMESTAMP())")->execute([$userA['id']]);
try{aiRunWorkerComplete($db,$revokedRow,$config,$writeResponse,9);check(false,'revoked consent executed');}
catch(RuntimeException $e){check($e->getCode()===403,'revocation checked before actions');}
check(actionMessageResults($db,$userA['id'],$revokedRow['message_id'])['results']===[],'no tool after consent withdrawal');
aiRunCancel($db,$userA['id'],$revokedRow['id']);
// Consent recovery is explicit; the previous scenario intentionally withdrew it.
aiProviderConsentSet($db,(int)$userA['id'],true);
// Real SQL fault must leave the run recoverable, without an early success.
$retry=makeRun($db,$userA,$config,actionUUID('build124-retry-conversation'),'记录体重72公斤。');
$retryRow=aiRunWorkerClaim($db,1)[0];$retryResponse=$writeResponse;
$retryResponse['result']['coach']['capability_calls'][0]['input']['kilograms']=72;
$db->exec("CREATE TRIGGER audit124_fail_call BEFORE INSERT ON ai_action_calls FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='isolated fixture fault'");
try { aiRunWorkerComplete($db,$retryRow,$config,$retryResponse,9); check(false,'SQL fault reported success'); }
catch(RuntimeException $e){check($e->getMessage()==='ACTIONS_PENDING','SQL fault remains retryable');}
check(!in_array('run.completed',eventTypes($db,$retryRow['id']),true),'no terminal success before business resolution');
$db->exec('DROP TRIGGER audit124_fail_call');
aiRunWorkerComplete($db,$retryRow,$config,$retryResponse,9);
check(actionMessageResults($db,$userA['id'],$retryRow['message_id'])['results'][0]['status']==='completed','same run recovers after SQL fault');
// Malformed upstream request is an input failure, never MODEL_UNAVAILABLE.
$invalid=makeRun($db,$userA,$config,actionUUID('build124-invalid-conversation'),'分析这些记录');
$invalidRow=aiRunWorkerClaim($db,1)[0];
$GLOBALS['boji_action_transport']=function(){throw new RuntimeException('private_service_unavailable',422);};
aiRunWorkerProcess($db,$invalidRow,$config);unset($GLOBALS['boji_action_transport']);
check(jobRow($db,$invalidRow['id'])['error_code']==='UPSTREAM_REQUEST_REJECTED','upstream 422 is not retried as provider outage');
check(aiDirectIntentAllowed('body.record_weight','记70公斤。'),'short explicit weight command accepted');
check(!aiDirectIntentAllowed('body.record_weight','先不记录70公斤'),'negative weight command rejected');
// Real training start/resume through the production worker and command service.
$exerciseID=businessUUID();$setID=businessUUID();
$current=json_decode($db->query('SELECT state_json FROM app_states WHERE user_id='.(int)$userA['id'])->fetchColumn(),true);
$current['days'][$today]['exercises']=[['id'=>$exerciseID,'name'=>'杠铃卧推','muscle'=>'胸','sets'=>[['id'=>$setID,'weight'=>40,'reps'=>8,'completed'=>false]]]];
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($current),$userA['id']]);
foreach(['开始今天训练','继续刚才训练'] as $question){
 $startRun=makeRun($db,$userA,$config,actionUUID('training-'.$question),$question);$startRow=aiRunWorkerClaim($db,1)[0];
 $startResponse=['status'=>'succeeded','provider'=>'deterministic'];
 // The worker request, not raw input, owns the whitelist.
 $startRequest=aiRunWorkerRequest($db,$startRow,$config);$startResponse['result']=aiFastIntent($startRequest);
 check(is_array($startResponse['result']),'deterministic training route available');
 aiRunWorkerComplete($db,$startRow,$config,$startResponse,4);
 check(actionMessageResults($db,$userA['id'],$startRow['message_id'])['results'][0]['status']==='completed','start/resume has domain receipt');
}
check((int)$db->query('SELECT COUNT(*) FROM active_workout_sessions WHERE user_id='.(int)$userA['id'])->fetchColumn()===1,'repeat start has one live session');
$finish=makeRun($db,$userA,$config,actionUUID('build124-finish-conversation'),'结束训练');$finishRow=aiRunWorkerClaim($db,1)[0];
$finishResponse=['status'=>'succeeded','provider'=>'deterministic','result'=>aiFastIntent(aiRunWorkerRequest($db,$finishRow,$config))];
aiRunWorkerComplete($db,$finishRow,$config,$finishResponse,4);
$finishResult=actionMessageResults($db,$userA['id'],$finishRow['message_id'])['results'][0];
check($finishResult['status']==='awaiting_confirmation','unfinished sets require explicit confirmation');
check((int)$db->query('SELECT COUNT(*) FROM active_workout_sessions WHERE user_id='.(int)$userA['id'])->fetchColumn()===1,'proposal never implicitly finishes training');
echo "PASS Build124 crash replay, SQL recovery, input-error classification, training start/resume/incomplete finish\n";

// A historic green conversation without a receipt must never look executed.
$legacyResult=json_decode(jobRow($db,$writeRow['id'])['result_json'],true);unset($legacyResult['coach']['action_results']);
$db->prepare('UPDATE ai_runs SET result_json=? WHERE id=?')->execute([json_encode($legacyResult),$writeRow['id']]);
$db->prepare('DELETE FROM ai_action_calls WHERE user_id=? AND message_id=?')->execute([$userA['id'],$writeRow['message_id']]);
check(actionMessageResults($db,$userA['id'],$writeRow['message_id'])['results'][0]['status']==='rejected','historic missing receipt is explicit, never silently replayed');
foreach(['记70公斤'=>70.0,'请记录今天早上体重72.3公斤'=>72.3,'今天早上体重70.2公斤，记录'=>70.2,'记录140斤'=>70.0,'登记体重154磅'=>69.9,'记录70.25公斤'=>70.3] as $input=>$expected)check(aiFastWeightValue($input)===$expected,'PHP weight parser units');
foreach(['记70','不要记录70公斤','昨天体重70公斤，记录','体重70公斤','如果记录70公斤','记录大概70公斤'] as $input)check(aiFastWeightValue($input)===null,'PHP ambiguous/negative weight rejected');
// Execute the actual notification selection query against mixed collations.
$db->exec("CREATE TEMPORARY TABLE domain_notification_jobs(device_id VARCHAR(100) COLLATE utf8mb4_unicode_ci,user_id BIGINT,status VARCHAR(30),next_attempt DATETIME,created_at DATETIME)");
$db->exec("CREATE TEMPORARY TABLE club_push_devices(device_id VARCHAR(100) COLLATE utf8mb4_general_ci,user_id BIGINT,token TEXT,environment VARCHAR(30),preferences_json TEXT,session_hash VARCHAR(100) COLLATE utf8mb4_general_ci,notify_after DATETIME,enabled TINYINT)");
$db->exec("CREATE TEMPORARY TABLE users(id BIGINT,status VARCHAR(30))");
$db->exec("CREATE TEMPORARY TABLE sessions(token_hash VARCHAR(100) COLLATE utf8mb4_unicode_ci,user_id BIGINT,expires_at DATETIME)");
$db->exec("ALTER TABLE club_push_devices MODIFY device_id VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL");
$source=file_get_contents(__DIR__.'/../account-server/process-domain-notifications.php');
preg_match('/\$q=\$db->query\("([^"\n]+)"\);/',$source,$match);
check(!empty($match[1]),'production notification selector located');
check($db->query($match[1])->fetchAll()===[],'mixed collation notification query succeeds without dispatch');
foreach(['domain_notification_jobs','club_push_devices','sessions','users'] as $table)$db->exec('DROP TEMPORARY TABLE '.$table);
echo "PASS Build124 historic missing receipts and mixed-collation notification query\n";

// --- IA-10: retention raises the event floor and requests resync ---------
$db->prepare('UPDATE ai_runs SET updated_at=DATE_SUB(UTC_TIMESTAMP(), INTERVAL 40 DAY) WHERE id=?')->execute([$okRun['run_id']]);
$pruned = aiRunPruneEvents($db, 30, 10);
$prunedRow = jobRow($db, $okRun['run_id']);
check($pruned['pruned_runs'] >= 1, 'terminal run is pruned');
check((int)$prunedRow['event_floor'] === (int)$prunedRow['last_seq'] + 1, 'event floor advances past deleted events');
check(aiRunResyncRequired($prunedRow, 0) === true, 'stale cursor requires resync');
check(aiRunResyncRequired($prunedRow, (int)$prunedRow['last_seq']) === false, 'current cursor does not resync');
check(count(aiRunEvents($db, $okRun['run_id'], 0, 10)) === 0, 'pruned events are gone, snapshot remains');
$snap = aiRunSnapshot($db, $userA['id'], $okRun['run_id']);
check(($snap['message']['coach']['answer'] ?? null) === 'one answer', 'snapshot survives event retention');

// --- IA-10: per-user/conversation concurrency caps -----------------------
$capped = $config; $capped['ai_max_active_runs'] = 2;
$convA = 'aaaaaaaa-bbbb-cccc-dddd-ffffffffffe1';
$convB = 'aaaaaaaa-bbbb-cccc-dddd-ffffffffffe2';
$convC = 'aaaaaaaa-bbbb-cccc-dddd-ffffffffffe3';
$activeA = makeRun($db, $userA, $capped, $convA, 'cap A');
$activeB = makeRun($db, $userA, $capped, $convB, 'cap B');
expectCode(429, fn() => makeRun($db, $userA, $capped, $convC, 'cap C'), 'third active run is rejected');
aiRunCancel($db, $userA['id'], $activeA['run_id']);
aiRunCancel($db, $userA['id'], $activeB['run_id']);

echo "AI_RUNS_OK checks=".$GLOBALS['audit124_checks']."\n";
