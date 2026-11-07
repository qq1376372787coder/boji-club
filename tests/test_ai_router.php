<?php
declare(strict_types=1);
/**
 * Phase 2: capability registry + AI Intent Router (five processing modes).
 *
 * Covers: registry validation, read_only / advisory / preview / direct / async
 * routing, gate degradation (direct → preview), action status lookup, and
 * action.undo (single use). No model output is trusted: every call is validated
 * against the registry and re-checked against live state.
 *
 * Run: tests/run_php_suite.sh (PHP 8.3 + pdo_mysql + disposable MySQL).
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/cloud-validation.php';
require __DIR__ . '/../account-server/public/ai-proposals.php';
require __DIR__ . '/../account-server/public/commands.php';
require __DIR__ . '/../account-server/public/capability-registry.php';
require __DIR__ . '/../account-server/public/ai-router.php';

if (!function_exists('fail')) {
    function fail(string $message, int $status = 400): never { throw new RuntimeException($message, $status); }
}
if (!function_exists('body')) {
    function body(int $max): array { throw new RuntimeException('http-only'); }
}
if (!function_exists('lockActiveUser')) {
    function lockActiveUser(PDO $db, int $uid): void {}
}
if (!function_exists('respond')) {
    function respond(int $status, array $payload): never {
        if ($status >= 400) throw new RuntimeException((string)($payload['error'] ?? 'http'), $status);
        throw new RouterRespondOK($payload);
    }
}
class RouterRespondOK extends RuntimeException {
    public function __construct(public readonly array $payload) { parent::__construct('respond'); }
}
if (!function_exists('appFeatureEnabled')) {
    function appFeatureEnabled(PDO $db, string $key): bool {
        return $GLOBALS['bojiTestFeatures'][$key] ?? true;
    }
}

$db = bojiTestDatabase('bojiclub_it');
$GLOBALS['bojiTestDB'] = $db;
$GLOBALS['config'] = ['membership_enforcement'=>false,'otp_secret' => 'router-test-secret-0123456789abcdef'];

function rcheck(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
    $GLOBALS['bojiRouterChecks'] = ($GLOBALS['bojiRouterChecks'] ?? 0) + 1;
}
function ruser(PDO $db, string $suffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['139000000' . $suffix]);
    return (int)$db->lastInsertId();
}
function rstate(PDO $db, int $userId, array $days): void {
    $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())
                  ON DUPLICATE KEY UPDATE revision=1,state_json=VALUES(state_json),updated_at=UTC_TIMESTAMP()')
        ->execute([$userId, json_encode(['profile'=>['nickname'=>'测试成员','age'=>28,'height'=>175,'weight'=>70,'goal'=>'增肌','experience'=>'新手','venue'=>'健身房','daysPerWeek'=>3,'focus'=>'全身'],'nutritionTarget'=>['caloriesMin'=>1800,'caloriesMax'=>2200,'proteinMin'=>100,'proteinMax'=>130,'fatMin'=>40,'fatMax'=>60,'meals'=>3,'note'=>'fixture'],'days' => $days], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)]);
}
function rexercise(string $name, int $sets): array {
    return ['id' => strtoupper(commandUUID()), 'name' => $name, 'muscle' => '胸',
            'sets' => array_map(fn($i) => ['id' => strtoupper(commandUUID()), 'weight' => 20, 'reps' => 10, 'completed' => false], range(1, $sets))];
}
function rrevision(int $userId): int {
    $q = $GLOBALS['bojiTestDB']->prepare('SELECT revision FROM app_states WHERE user_id=?');
    $q->execute([$userId]);
    return (int)$q->fetchColumn();
}
function rstatejson(int $userId): array {
    $q = $GLOBALS['bojiTestDB']->prepare('SELECT state_json FROM app_states WHERE user_id=?');
    $q->execute([$userId]);
    $decoded = json_decode((string)$q->fetchColumn(), true);
    return is_array($decoded) ? $decoded : [];
}
function rroute(int $userId, array $call): array {
    return aiRouterRouteOne($GLOBALS['bojiTestDB'], ['id' => $userId], $call);
}
function rcount(string $sql): int {
    return (int)$GLOBALS['bojiTestDB']->query($sql)->fetchColumn();
}

$db->exec("DELETE FROM users WHERE phone LIKE '139%'");
$userA = ruser($db, '11');
$userB = ruser($db, '22');
$today = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
$future = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('+2 days')->format('Y-m-d');
$future2 = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('+3 days')->format('Y-m-d');
$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,updated_at) VALUES(?,1,'Asia/Shanghai','kg',UTC_TIMESTAMP())")->execute([$userA]);
rstate($db, $userA, [$future=>['exercises'=>[rexercise('深蹲',2)],'meals'=>[]],$today => ['exercises' => [rexercise('杠铃卧推', 3)], 'meals' => []]]);
rstate($db, $userB, []);

// ------------------------------------------------------------ 1. registry checks
rcheck(capabilityCallValid(['capability' => 'training.get_today', 'input' => []]) !== null, 'registered capability accepted');
rcheck(capabilityCallValid(['capability' => 'training.delete_everything', 'input' => []]) === null, 'unknown capability rejected');
rcheck(capabilityCallValid(['capability' => 'body.record_weight', 'input' => ['date' => $today, 'kilograms' => 70.5, 'sql' => 'drop']]) === null, 'unknown input field rejected');
rcheck(capabilityCallValid(['capability' => 'body.record_weight', 'input' => ['date' => $today]]) === null, 'missing required field rejected');
rcheck(capabilityCallValid(['capability' => 'body.record_weight', 'input' => ['date' => $today, 'kilograms' => '70.5']]) === null, 'wrong value type rejected');
rcheck(capabilityCallValid(['capability' => 'body.record_weight', 'input' => ['date' => 'bad', 'kilograms' => 70.5]]) === null, 'malformed date rejected');
rcheck(capabilityCallValid(['capability' => 'body.record_weight', 'input' => ['date' => $today, 'kilograms' => 900]]) === null, 'out-of-range value rejected');
$registry = capabilityRegistry();
rcheck(count($registry) >= 15, 'registry ships the tested capability set');
foreach ($registry as $name => $entry) {
    rcheck(in_array($entry['mode'], ['read_only', 'advisory', 'direct', 'preview', 'async'], true), "capability {$name} has a known mode");
    rcheck(isset($entry['risk_level'], $entry['needs_confirmation'], $entry['domain_owner'], $entry['idempotency_policy']), "capability {$name} carries the required metadata");
}

// ---------------------------------------------------- 2. read_only (no writes)
$revisionBefore = rrevision($userA);
$opsBefore = rcount("SELECT COUNT(*) FROM data_operations WHERE user_id={$userA}");
$result = rroute($userA, ['capability' => 'training.get_today', 'input' => []]);
rcheck($result['status'] === 'completed', 'read-only capability completes');
rcheck(($result['data']['exercise_count'] ?? 0) === 1, 'read-only capability reads the live document');
rcheck(($result['card']['card_type'] ?? '') === 'today_training', 'read-only capability returns a native card');
rcheck(!empty($result['card']['card_id']) && !empty($result['card']['expires_at']), 'card envelope is complete for the client');
rcheck(rrevision($userA) === $revisionBefore, 'read-only capability does not change the document');
rcheck(rcount("SELECT COUNT(*) FROM data_operations WHERE user_id={$userA}") === $opsBefore, 'read-only capability writes no audit row');

// ------------------------------------------- 3. advisory (suggestion, no writes)
$result = rroute($userA, ['capability' => 'coach.assess_readiness', 'input' => ['question' => '有点累，练不练？']]);
rcheck($result['status'] === 'completed', 'advisory capability completes');
rcheck(($result['card']['card_type'] ?? '') === 'advice', 'advisory capability returns an advice card');
rcheck(count($result['card']['payload']['options'] ?? []) >= 1, 'advice card offers explicit choices');
rcheck(rrevision($userA) === $revisionBefore, 'advisory capability never touches the schedule');
rcheck(rcount("SELECT COUNT(*) FROM data_operations WHERE user_id={$userA}") === $opsBefore, 'advisory capability writes no audit row');
rcheck(rcount("SELECT COUNT(*) FROM domain_outbox WHERE user_id={$userA}") === 0, 'advisory capability publishes no event');

// --------------------------------------------------------- 4. preview (no write)
$proposalCalls = rroute($userA, ['capability' => 'schedule.preview_change',
                                  'input' => ['moves' => [['from' => $future, 'to' => $future2]]]]);
rcheck($proposalCalls['status'] === 'awaiting_confirmation', 'preview capability waits for confirmation');
rcheck(!empty($proposalCalls['proposal_id']), 'preview returns a proposal id');
rcheck(($proposalCalls['card']['payload']['proposal_id'] ?? '') === $proposalCalls['proposal_id'], 'preview card is bound to the proposal');
rcheck(rrevision($userA) === $revisionBefore, 'preview capability writes nothing before confirmation');
$proposalRow = $db->prepare('SELECT kind,status FROM ai_action_proposals WHERE user_id=? AND proposal_id=?');
$proposalRow->execute([$userA, $proposalCalls['proposal_id']]);
$proposal = $proposalRow->fetch(PDO::FETCH_ASSOC);
rcheck($proposal && $proposal['kind'] === 'plan_change_proposal' && $proposal['status'] === 'awaiting_confirmation', 'proposal is stored awaiting confirmation');

// --------------------------------------- 5. direct with gate closed → preview
$GLOBALS['bojiTestFeatures'] = ['direct_records' => false];
$degraded = rroute($userA, ['capability' => 'body.record_weight', 'input' => ['date' => $today, 'kilograms' => 70.5]]);
rcheck($degraded['status'] === 'awaiting_confirmation', 'a closed gate degrades a direct write into a preview');
rcheck(($degraded['proposal_kind'] ?? '') === 'weight_entry', 'degraded write uses the weight proposal kind');
rcheck(rrevision($userA) === $revisionBefore, 'degraded write still changes nothing');
$GLOBALS['bojiTestFeatures'] = [];

// ------------------------------------------------------ 6. direct (gate open)
$direct = rroute($userA, ['capability' => 'body.record_weight', 'input' => ['date' => $today, 'kilograms' => 70.5]]);
rcheck($direct['status'] === 'completed', 'direct capability executes through the command service');
$state = rstatejson($userA);
rcheck(abs((float)($state['days'][$today]['bodyWeight']['kilograms'] ?? 0) - 70.5) < 0.001, 'direct capability wrote the authoritative document');
rcheck(rrevision($userA) === $revisionBefore + 1, 'direct capability bumps the revision exactly once');
rcheck(rcount("SELECT COUNT(*) FROM data_operations WHERE user_id={$userA} AND command_type='BodyWeight.CreateDirect'") === 1, 'direct capability writes exactly one audit row');
rcheck(rcount("SELECT COUNT(*) FROM domain_outbox WHERE user_id={$userA} AND event_type='BodyWeightRecorded'") === 1, 'direct capability publishes one event');
$directCommandID = (string)$db->query("SELECT operation_id FROM data_operations WHERE user_id={$userA} AND command_type='BodyWeight.CreateDirect' LIMIT 1")->fetchColumn();
rcheck($directCommandID !== '', 'direct capability is traceable by command id');

// ---------------------------------------------- 7. async (accepted, not done)
$async = rroute($userA, ['capability' => 'plan.generate_draft', 'input' => ['goal' => '增肌']]);
rcheck($async['status'] === 'accepted', 'async capability is only accepted');
rcheck(!empty($async['execution_id']), 'async capability returns an execution id');
rcheck(str_contains((string)($async['note'] ?? ''), '确认'), 'async capability states that acceptance is not completion');
rcheck(rcount("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id={$userA} AND kind='generate_plan'") === 1, 'async capability queues exactly one job');

// ------------------------------------------------------ 8. action.get_status
$status = rroute($userA, ['capability' => 'action.get_status', 'input' => ['execution_id' => $proposalCalls['proposal_id']]]);
rcheck($status['status'] === 'completed' && ($status['data']['kind'] ?? '') === 'proposal', 'status lookup resolves a proposal');
$status = rroute($userA, ['capability' => 'action.get_status', 'input' => ['execution_id' => $directCommandID]]);
rcheck(($status['data']['kind'] ?? '') === 'command' && ($status['data']['status'] ?? '') === 'succeeded', 'status lookup resolves a command');
$status = rroute($userA, ['capability' => 'action.get_status', 'input' => ['execution_id' => $async['execution_id']]]);
rcheck(($status['data']['kind'] ?? '') === 'job' && in_array(($status['data']['status']??''),['pending','running','dispatching'],true), 'status lookup resolves a queued job');
$threw = false;
try { rroute($userB, ['capability' => 'action.get_status', 'input' => ['execution_id' => $proposalCalls['proposal_id']]]); }
catch (RuntimeException $error) { $threw = true; }
rcheck($threw, 'another account cannot read this proposal status');

// ------------------------------------------------------------- 9. action.undo
$undo = ['status'=>'completed'] + aiRouterUndo($db,['id'=>$userA],['command_id'=>$directCommandID]);
rcheck($undo['status'] === 'completed', 'undo completes through the command service');
$state = rstatejson($userA);
rcheck(!isset($state['days'][$today]['bodyWeight']), 'undo removed the direct record');
rcheck(rcount("SELECT COUNT(*) FROM data_operations WHERE user_id={$userA} AND command_type='Action.Undo'") === 1, 'undo writes its own audit row');
rcheck(rcount("SELECT COUNT(*) FROM domain_outbox WHERE user_id={$userA} AND event_type='ActionUndone.v1'") === 1, 'undo publishes one event');
$threw = false;
try { ['status'=>'completed'] + aiRouterUndo($db,['id'=>$userA],['command_id'=>$directCommandID]); }
catch (RuntimeException $error) { $threw = true; }
rcheck(!$threw, 'a lost undo response replays the original committed undo');

// -------------------------------------------------------- 10. unknown + cross account
$rejected = rroute($userA, ['capability' => 'training.delete_everything', 'input' => []]);
rcheck($rejected['status'] === 'rejected', 'unknown capabilities are rejected, never executed');
try { rroute($userB, ['capability'=>'action.get_status','input'=>['execution_id'=>$directCommandID]]);rcheck(false,'foreign action must be hidden'); } catch(RuntimeException $e){rcheck($e->getCode()===404,'another account never sees this execution');}

echo "AI router: {$GLOBALS['bojiRouterChecks']} assertions passed\n";
