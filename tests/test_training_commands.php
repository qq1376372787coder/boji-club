<?php
declare(strict_types=1);
/**
 * Phase 1: Domain Command integration tests.
 *
 * Covers the training lifecycle commands (Training.SessionStart / SessionFinish /
 * LogSet) with the DB-level single-active-session invariant, the proposal-free
 * direct records (BodyWeight.CreateDirect / Meal.CreateDirect) with semantic
 * idempotency, and the full-state sync guard (backfill / release / refuse).
 *
 * E2E matrix mapping (spec §11): #1 double-open, #2/#3 idempotent replay and
 * key reuse, #6 finished-day protection, #11 duplicate meal records,
 * #12 same-day weigh-ins, #17 proposal-adjacent conflict states.
 *
 * Run: tests/run_php_suite.sh (PHP 8.3 + pdo_mysql + disposable MySQL).
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/cloud-validation.php';
require __DIR__ . '/../account-server/public/ai-proposals.php';
require __DIR__ . '/../account-server/public/commands.php';

if (!function_exists('fail')) {
    function fail(string $message, int $status = 400): never { throw new RuntimeException($message, $status); }
}
if (!function_exists('body')) {
    function body(int $max): array { throw new RuntimeException('http-only'); }
}
if (!function_exists('lockActiveUser')) {
    // 行锁的真实实现在 index.php；夹具用户均为 active，测试内无并发，no-op 即可。
    function lockActiveUser(PDO $db, int $uid): void {}
}
if (!function_exists('respond')) {
    function respond(int $status, array $payload): never {
        if ($status >= 400) throw new RuntimeException((string)($payload['error'] ?? 'http'), $status);
        throw new TrainingRespondOK($payload);
    }
}
class TrainingRespondOK extends RuntimeException {
    public function __construct(public readonly array $payload) { parent::__construct('respond'); }
}
// Rollout gates are exercised explicitly through this stub (default: open).
if (!function_exists('appFeatureEnabled')) {
    function appFeatureEnabled(PDO $db, string $key): bool {
        return $GLOBALS['bojiTestFeatures'][$key] ?? true;
    }
}

$db = bojiTestDatabase('bojiclub_it');

function tcheck(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
    $GLOBALS['bojiTrainingChecks'] = ($GLOBALS['bojiTrainingChecks'] ?? 0) + 1;
}

function tdate(string $fixture): string {
    $offset = (int)(new DateTimeImmutable('2026-10-24'))->diff(new DateTimeImmutable($fixture))->format('%r%a');
    return (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify("+$offset days")->format('Y-m-d');
}
function tuser(PDO $db, string $suffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['138000000' . $suffix]);
    return (int)$db->lastInsertId();
}
function tstate(PDO $db, int $userId, array $days): void {
    $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())
                  ON DUPLICATE KEY UPDATE revision=1,state_json=VALUES(state_json),updated_at=UTC_TIMESTAMP()')
        ->execute([$userId, json_encode(['days' => $days], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)]);
}
function texercise(string $name, int $sets): array {
    return ['id' => strtoupper(commandUUID()), 'name' => $name, 'muscle' => '胸',
            'sets' => array_map(fn($i) => ['id' => strtoupper(commandUUID()), 'weight' => 20, 'reps' => 10, 'completed' => false], range(1, $sets))];
}
function tstamp(): int { static $stamp=null;return $stamp??=time()-978307200; }
function trun(array $cmd): array {
    try {
        return handleBusinessCommandCore($GLOBALS['bojiTestDB'], ['id' => $GLOBALS['bojiTestUser']], $cmd);
    } catch (TrainingRespondOK $ok) {
        return $ok->payload;
    }
}
function tconflict(array $cmd): RuntimeException {
    try {
        handleBusinessCommandCore($GLOBALS['bojiTestDB'], ['id' => $GLOBALS['bojiTestUser']], $cmd);
    } catch (RuntimeException $error) {
        return $error;
    }
    throw new RuntimeException('expected a conflict was not raised');
}
function tstateOf(int $userId): array {
    $q = $GLOBALS['bojiTestDB']->prepare('SELECT state_json FROM app_states WHERE user_id=?');
    $q->execute([$userId]);
    $decoded = json_decode((string)$q->fetchColumn(), true);
    return is_array($decoded) ? $decoded : [];
}

// Fixture DB shared with other AI suites: clean our prefix first.
$db->exec("DELETE FROM users WHERE phone LIKE '138%'");
$GLOBALS['bojiTestDB'] = $db;
$userA = tuser($db, '11');
$userB = tuser($db, '22');
$today = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
$yesterday = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('-1 day')->format('Y-m-d');
$tomorrow = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('+1 day')->format('Y-m-d');
$planned = texercise('杠铃卧推', 3);
tstate($db, $userA, [$today => ['exercises' => [$planned], 'meals' => []]]);
tstate($db, $userB, []);

// ---------------------------------------------------------------- 1. validators
tcheck(trainingStartPayloadValid(['date' => 'bad', 'session_id' => strtoupper(commandUUID())]) === null, 'start rejects a bad date');
tcheck(trainingStartPayloadValid(['date' => $today, 'session_id' => 'nope']) === null, 'start rejects a bad session id');
tcheck(trainingStartPayloadValid(['date' => $today, 'session_id' => strtoupper(commandUUID())]) !== null, 'start accepts a valid payload');
tcheck(trainingSetPayloadValid(['id' => commandUUID(), 'weight' => 20, 'reps' => 10, 'completed' => true]) !== null, 'completed set with reps accepted');
tcheck(trainingSetPayloadValid(['id' => commandUUID(), 'weight' => 20, 'reps' => 0, 'completed' => true]) === null, 'completed set without reps or duration rejected');
tcheck(trainingSetPayloadValid(['id' => commandUUID(), 'weight' => 20, 'reps' => 0, 'completed' => true, 'duration_seconds' => 30]) !== null, 'timed completed set accepted');
tcheck(trainingSetPayloadValid(['id' => commandUUID(), 'weight' => 99999, 'reps' => 10, 'completed' => true]) === null, 'out-of-range weight rejected');
tcheck(trainingSetPayloadValid(['id' => commandUUID(), 'weight' => 20, 'reps' => 10, 'completed' => true, 'duration_seconds' => 99999]) === null, 'out-of-range duration rejected');
tcheck(trainingDirectMealPayloadValid(['date' => $today, 'meals' => [['entry_id' => commandUUID(), 'name' => '燕麦碗', 'category' => '早餐']]]) !== null, 'direct meal accepts a minimal entry');
tcheck(trainingDirectMealPayloadValid(['date' => $today, 'meals' => [['entry_id' => commandUUID(), 'name' => '燕麦碗', 'category' => '宵夜']]]) === null, 'direct meal rejects an unknown category');
tcheck(trainingDirectWeightPayloadValid(['date' => $today, 'kilograms' => 72.5, 'recorded_at' => tstamp()]) !== null, 'direct weight accepts a sampling time');
tcheck(trainingDirectWeightPayloadValid(['date' => $today, 'kilograms' => 500]) === null, 'direct weight rejects an absurd value');

// ------------------------------------------------- 2. start claims + double-open
$sessionA = strtolower(commandUUID());
$sessionB = strtolower(commandUUID());
$GLOBALS['bojiTestUser'] = $userA;
$start = trun(['commandId' => commandUUID(), 'type' => 'Training.SessionStart',
               'payload' => ['date' => $today, 'session_id' => $sessionA], 'actor' => 'user']);
tcheck(($start['status'] ?? '') === 'succeeded' && empty($start['resume']), 'first start claims the session');
$claim = $db->prepare('SELECT session_id,date_key FROM active_workout_sessions WHERE user_id=?');
$claim->execute([$userA]);
$claimRow = $claim->fetch();
tcheck($claimRow && $claimRow['session_id'] === $sessionA && $claimRow['date_key'] === $today, 'claim row records the active session');
$stateA = tstateOf($userA);
$dayA = $stateA['days'][$today];
tcheck(!empty($dayA['workoutStartedAt']) && strtolower((string)$dayA['activeWorkoutSessionID']) === $sessionA, 'document marks the session started');
tcheck(count($dayA['workoutSessions'] ?? []) === 1, 'exactly one session entry exists');
$outboxCount = (int)$db->query("SELECT COUNT(*) FROM domain_outbox WHERE user_id=$userA AND event_type='WorkoutSessionStarted.v1'")->fetchColumn();
tcheck($outboxCount === 1, 'one start event published');

// 连点第二次（同一会话重试，不同 commandId）：恢复而非新建。
$again = trun(['commandId' => commandUUID(), 'type' => 'Training.SessionStart',
               'payload' => ['date' => $today, 'session_id' => $sessionA], 'actor' => 'user']);
tcheck(($again['resume'] ?? false) === true && $again['session_id'] === $sessionA, 'repeat start resumes instead of forking');
$claim->execute([$userA]);
tcheck($claim->fetch()['session_id'] === $sessionA, 'claim unchanged after a repeat start');

// 两台设备：不同会话 ID 的第二次开始 → 仍然恢复原会话（E2E #1）。
$otherDevice = trun(['commandId' => commandUUID(), 'type' => 'Training.SessionStart',
                     'payload' => ['date' => $today, 'session_id' => $sessionB], 'actor' => 'user']);
tcheck(($otherDevice['resume'] ?? false) === true && $otherDevice['session_id'] === $sessionA, 'a second device resumes the claimed session');
$stateA = tstateOf($userA);
tcheck(count($stateA['days'][$today]['workoutSessions'] ?? []) === 1, 'no parallel session created on the document');
$outboxCount = (int)$db->query("SELECT COUNT(*) FROM domain_outbox WHERE user_id=$userA AND event_type='WorkoutSessionStarted.v1'")->fetchColumn();
tcheck($outboxCount === 1, 'resume publishes no additional event');

// ---------------------------------------------------------- 3. log set + guards
$logSet = trun(['commandId' => commandUUID(), 'type' => 'Training.LogSet',
                'payload' => ['date' => $today, 'session_id' => $sessionA, 'exercise_id' => strtolower($planned['id']),
                              'set_id' => strtolower($planned['sets'][0]['id']), 'weight' => 22.5, 'reps' => 12, 'completed' => true],
                'actor' => 'user']);
tcheck(($logSet['status'] ?? '') === 'succeeded', 'log set into the active session succeeds');
$stateA = tstateOf($userA);
$logged = $stateA['days'][$today]['exercises'][0]['sets'][0];
tcheck(abs((float)$logged['weight'] - 22.5) < 0.001 && (int)$logged['reps'] === 12 && $logged['completed'] === true, 'the set is updated with the logged values');

$logWrongSession = tconflict(['commandId' => commandUUID(), 'type' => 'Training.LogSet',
    'payload' => ['date' => $today, 'session_id' => $sessionB, 'exercise_id' => strtolower($planned['id']),
                  'set_id' => strtolower($planned['sets'][1]['id']), 'weight' => 20, 'reps' => 10, 'completed' => true]]);
tcheck($logWrongSession->getCode() === 409, 'log set with a foreign session id conflicts');

$logUnknownExercise = tconflict(['commandId' => commandUUID(), 'type' => 'Training.LogSet',
    'payload' => ['date' => $today, 'session_id' => $sessionA, 'exercise_id' => strtolower(commandUUID()),
                  'set_id' => strtolower(commandUUID()), 'weight' => 20, 'reps' => 10, 'completed' => true]]);
tcheck($logUnknownExercise->getCode() === 422, 'log set for an unknown exercise is unprocessable');

// ------------------------------------------------------ 4. finish + protections
$finish = trun(['commandId' => commandUUID(), 'type' => 'Training.SessionFinish',
                'payload' => ['date' => $today, 'session_id' => $sessionA, 'started_at' => tstamp() - 1800,
                              'ended_at' => tstamp(), 'saved_at' => tstamp(),
                              'exercises' => [['id' => $planned['id'], 'name' => '杠铃卧推', 'muscle' => '胸',
                                               'sets' => [['id' => $planned['sets'][0]['id'], 'weight' => 22.5, 'reps' => 12, 'completed' => true],
                                                          ['id' => $planned['sets'][1]['id'], 'weight' => 22.5, 'reps' => 10, 'completed' => true],
                                                          ['id' => $planned['sets'][2]['id'], 'weight' => 22.5, 'reps' => 9, 'completed' => false]]]]],
                'actor' => 'user']);
tcheck(($finish['status'] ?? '') === 'succeeded', 'finish applies the session snapshot');
$stateA = tstateOf($userA);
$dayA = $stateA['days'][$today];
tcheck(!empty($dayA['workoutSavedAt']) && businessDayProtected($dayA), 'the finished day is protected');
$claim->execute([$userA]);
tcheck($claim->fetch() === false, 'the claim is released after finish');
$sessionEntry = $dayA['workoutSessions'][0];
tcheck(!empty($sessionEntry['savedAt']) && !empty($sessionEntry['startedAt']) && !empty($sessionEntry['endedAt']), 'session entry carries the full lifecycle stamps');
$audit = $db->prepare('SELECT COUNT(*) FROM data_operations WHERE user_id=? AND command_type=? AND status=\'succeeded\'');
$audit->execute([$userA, 'Training.SessionFinish']);
tcheck((int)$audit->fetchColumn() === 1, 'finish writes exactly one audit row');

// 重复确认（新 commandId）→ 409，不产生第二次完成事实（E2E #6/#18）。
$reconfirm = tconflict(['commandId' => commandUUID(), 'type' => 'Training.SessionFinish',
    'payload' => ['date' => $today, 'session_id' => $sessionA, 'saved_at' => tstamp() + 60]]);
tcheck($reconfirm->getCode() === 409, 'a second finish command is refused');
$stateA = tstateOf($userA);
tcheck((int)$stateA['days'][$today]['workoutSessions'][0]['savedAt'] === (int)$sessionEntry['savedAt'], 'the saved fact is untouched by the refused repeat');

// 同一 commandId 重放 → 幂等返回原结果，不二次执行（E2E #2）。
// 先在一个未开始的过去日用新命令完成，再原样（同载荷）重放。
$finishCommandID = commandUUID();
$freshDate = $yesterday;
tstate($db, $userA, array_merge(tstateOf($userA)['days'], [$freshDate => ['exercises' => [texercise('杠铃深蹲', 2)], 'meals' => []]]));
$freshExercise = tstateOf($userA)['days'][$freshDate]['exercises'][0];
$freshSession = strtolower(commandUUID());
trun(['commandId' => commandUUID(), 'type' => 'Training.SessionStart', 'payload' => ['date' => $freshDate, 'session_id' => $freshSession]]);
$freshPayload = ['date' => $freshDate, 'session_id' => $freshSession, 'saved_at' => tstamp(),
                 'exercises' => [['id' => $freshExercise['id'], 'name' => '杠铃深蹲', 'muscle' => '腿',
                                  'sets' => [['id' => $freshExercise['sets'][0]['id'], 'weight' => 40, 'reps' => 8, 'completed' => true]]]]];
$first = trun(['commandId' => $finishCommandID, 'type' => 'Training.SessionFinish', 'payload' => $freshPayload]);
tcheck(($first['status'] ?? '') === 'succeeded', 'fresh finish succeeds');
$replayResult = trun(['commandId' => $finishCommandID, 'type' => 'Training.SessionFinish', 'payload' => $freshPayload]);
tcheck(($replayResult['idempotent'] ?? false) === true, 'same commandId with the same payload replays');
$stateA = tstateOf($userA);
$freshSet = $stateA['days'][$freshDate]['exercises'][0]['sets'][0];
tcheck(abs((float)$freshSet['weight'] - 40) < 0.001, 'replay does not re-apply the mutation');
$audit->execute([$userA, 'Training.SessionFinish']);
tcheck((int)$audit->fetchColumn() === 2, 'replay writes no additional audit row');

// 同一 commandId 不同载荷 → 拒绝（E2E #3）。
$keyReuse = tconflict(['commandId' => $finishCommandID, 'type' => 'Training.SessionFinish',
    'payload' => ['date' => $freshDate, 'session_id' => $freshSession, 'saved_at' => tstamp(),
                  'exercises' => [['id' => $freshExercise['id'], 'name' => '杠铃深蹲', 'muscle' => '腿',
                                   'sets' => [['id' => $freshExercise['sets'][0]['id'], 'weight' => 55, 'reps' => 5, 'completed' => true]]]]]]);
tcheck($keyReuse->getCode() === 400, 'the same commandId with a different payload is rejected');

// -------------------------------------------- 5. offline start + adopt-and-finish
$offlineSession = strtolower(commandUUID());
$offlineDate = $yesterday;
tstate($db, $userB, [$offlineDate => ['exercises' => [texercise('俯卧撑', 2)], 'meals' => []]]);
$offlineExercise = tstateOf($userB)['days'][$offlineDate]['exercises'][0];
$GLOBALS['bojiTestUser'] = $userB;
// 模拟离线开始（无 claim 行，文档也未开始）后直接结束：adopt 路径。
$adopt = trun(['commandId' => commandUUID(), 'type' => 'Training.SessionFinish',
               'payload' => ['date' => $offlineDate, 'session_id' => $offlineSession,
                             'started_at' => tstamp() - 900, 'ended_at' => tstamp() - 60, 'saved_at' => tstamp() - 60,
                             'exercises' => [['id' => $offlineExercise['id'], 'name' => '俯卧撑', 'muscle' => '胸',
                                              'sets' => [['id' => $offlineExercise['sets'][0]['id'], 'weight' => 0, 'reps' => 15, 'completed' => true],
                                                         ['id' => $offlineExercise['sets'][1]['id'], 'weight' => 0, 'reps' => 12, 'completed' => true]]]]],
               'actor' => 'user']);
tcheck(($adopt['status'] ?? '') === 'succeeded', 'offline-started session finishes through the adopt path');
$stateB = tstateOf($userB);
tcheck(!empty($stateB['days'][$offlineDate]['workoutSavedAt']), 'adopted finish marks the day saved');
$claimB = $db->prepare('SELECT COUNT(*) FROM active_workout_sessions WHERE user_id=?');
$claimB->execute([$userB]);
tcheck((int)$claimB->fetchColumn() === 0, 'adopt path leaves no claim behind');
// B 的进行中会话不影响 A 的认领（跨账号隔离）。
$GLOBALS['bojiTestUser'] = $userA;
$claimA = $db->prepare('SELECT COUNT(*) FROM active_workout_sessions WHERE user_id=?');
$claimA->execute([$userA]);
tcheck((int)$claimA->fetchColumn() === 0, 'account claims stay isolated');

// ------------------------------------------------- 6. direct records + idempotency
$weightKey = hash('sha256', 'direct-weight-1');
$weight = trun(['commandId' => commandUUID(), 'type' => 'BodyWeight.CreateDirect',
                'payload' => ['idempotency_key' => $weightKey, 'date' => $yesterday, 'kilograms' => 70.5,
                              'bodyFatPercentage' => 18.2, 'recorded_at' => tstamp()], 'actor' => 'user']);
tcheck(($weight['status'] ?? '') === 'succeeded', 'direct weight record succeeds');
$stateB = tstateOf($userA);
$entryB = $stateB['days'][$yesterday]['bodyWeight'];
tcheck(abs((float)$entryB['kilograms'] - 70.5) < 0.001 && abs((float)$entryB['bodyFatPercentage'] - 18.2) < 0.001, 'direct weight entry written with source manual');
tcheck(($entryB['source'] ?? '') === 'manual', 'direct weight records the manual source');
// 同键同内容、新 commandId（客户端丢了队列）→ 幂等重放（E2E #12 重试半程）。
$weightRetry = trun(['commandId' => commandUUID(), 'type' => 'BodyWeight.CreateDirect',
                     'payload' => ['idempotency_key' => $weightKey, 'date' => $yesterday, 'kilograms' => 70.5,
                                   'bodyFatPercentage' => 18.2, 'recorded_at' => tstamp()], 'actor' => 'user']);
tcheck(($weightRetry['idempotent'] ?? false) === true, 'the same key with the same payload replays');
// 同键不同内容 → 409。
$weightReuse = tconflict(['commandId' => commandUUID(), 'type' => 'BodyWeight.CreateDirect',
    'payload' => ['idempotency_key' => $weightKey, 'date' => $yesterday, 'kilograms' => 88.8]]);
tcheck($weightReuse->getCode() === 409, 'the same key with a different payload is refused');
// 同日真实称重分开保存；旧 bodyWeight 仅是最新显示投影。
$weightSecond = trun(['commandId' => commandUUID(), 'type' => 'BodyWeight.CreateDirect',
                      'payload' => ['idempotency_key' => hash('sha256', 'direct-weight-2'), 'date' => $yesterday, 'kilograms' => 70.8], 'actor' => 'user']);
tcheck(($weightSecond['status'] ?? '') === 'succeeded', 'a second real weigh-in is accepted');
tcheck(count(tstateOf($userA)['days'][$yesterday]['bodyMeasurements'])===2,'both independent measurements remain available');
$stateB = tstateOf($userA);
tcheck(abs((float)$stateB['days'][$yesterday]['bodyWeight']['kilograms'] - 70.8) < 0.001, 'the same-day measurement converges to the newest value');

// 直接饮食：entry_id 去重，重放不产生第二餐（E2E #11）。
$mealEntry = strtolower(commandUUID());
$mealPayload = ['idempotency_key' => hash('sha256', 'direct-meal-1'), 'date' => $yesterday,
                'meals' => [['entry_id' => $mealEntry, 'name' => '香煎鸡胸肉', 'category' => '午餐', 'calories' => 650, 'protein' => 45, 'carbs' => 72, 'fat' => 19]]];
$meal = trun(['commandId' => commandUUID(), 'type' => 'Meal.CreateDirect', 'payload' => $mealPayload, 'actor' => 'user']);
tcheck(($meal['status'] ?? '') === 'succeeded' && ($meal['diff']['added'] ?? 0) === 1, 'direct meal record succeeds');
$mealReplay = trun(['commandId' => commandUUID(), 'type' => 'Meal.CreateDirect', 'payload' => $mealPayload, 'actor' => 'user']);
tcheck(($mealReplay['idempotent'] ?? false) === true, 'the same direct meal replays');
$stateB = tstateOf($userA);
tcheck(count($stateB['days'][$yesterday]['meals'] ?? []) === 1, 'a replayed meal does not duplicate');
$mealSecond = trun(['commandId' => commandUUID(), 'type' => 'Meal.CreateDirect',
                    'payload' => ['idempotency_key' => hash('sha256', 'direct-meal-2'), 'date' => $yesterday,
                                  'meals' => [['entry_id' => strtolower(commandUUID()), 'name' => '清蒸鱼', 'category' => '晚餐', 'calories' => 480]]], 'actor' => 'user']);
tcheck(($mealSecond['diff']['added'] ?? 0) === 1, 'a second real meal is recorded separately');
$stateB = tstateOf($userA);
tcheck(count($stateB['days'][$yesterday]['meals'] ?? []) === 2, 'two real meals coexist');

// ------------------------------------------------------- 7. feature flag gating
$GLOBALS['bojiTestFeatures'] = ['training_commands' => false, 'direct_records' => false];
$gated = tconflict(['commandId' => commandUUID(), 'type' => 'Training.SessionStart',
    'payload' => ['date' => $today, 'session_id' => strtolower(commandUUID())]]);
tcheck($gated->getCode() === 503, 'training commands are refused while the gate is closed');
$gatedWeight = tconflict(['commandId' => commandUUID(), 'type' => 'BodyWeight.CreateDirect',
    'payload' => ['idempotency_key' => hash('sha256', 'gated'), 'date' => $today, 'kilograms' => 70.5]]);
tcheck($gatedWeight->getCode() === 503, 'direct records are refused while the gate is closed');
$GLOBALS['bojiTestFeatures'] = [];

// ------------------------------------------- 8. full-state sync guard (PUT path)
function tguard(array $incoming, int $userId): ?string {
    return trainingGuardFullStateSync($GLOBALS['bojiTestDB'], $userId, ['days' => $incoming]);
}
$GLOBALS['bojiTestUser'] = $userA;
$claimA=$db->prepare('SELECT * FROM active_workout_sessions WHERE user_id=?');
// 8a. 空 claim + 文档中一个活跃会话 → 补领（旧客户端首次开始）。
$backfillDate = $tomorrow;
$backfillSession = strtolower(commandUUID());
tcheck(tguard([$backfillDate => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => $backfillSession]], $userA) === null, 'guard backfills a legacy document start');
$claimA->execute([$userA]);
$claimRow = $claimA->fetch();
tcheck($claimRow && $claimRow['session_id'] === $backfillSession && $claimRow['date_key'] === $backfillDate, 'backfilled claim matches the document session');
// 8b. 同一会话继续同步 → 放行。
tcheck(tguard([$backfillDate => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => $backfillSession]], $userA) === null, 'steady-state sync passes');
// 8c. 文档不再有活跃会话（已在别处结束）→ 释放。
tcheck(tguard([$backfillDate => ['workoutStartedAt' => tstamp(), 'workoutSavedAt' => tstamp(), 'activeWorkoutSessionID' => $backfillSession]], $userA) === null, 'guard releases the claim when the document finished');
$claimA->execute([$userA]);
tcheck($claimA->fetch() === false, 'claim released after a legacy finish');
// 8d. 不同会话的并行活跃 → 拒绝（防止 PUT 路径静默双开）。
$parallelSession = strtolower(commandUUID());
tguard([$backfillDate => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => $backfillSession]], $userA); // 重新补领
$refusal = tguard([$today => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => $parallelSession]], $userA);
tcheck($refusal !== null && str_contains($refusal, '其他设备'), 'a parallel active session is refused');
// 8e. 无活跃会话且无 claim → 直接放行（全新账号首次同步）。
tcheck(tguard([], $userB) === null, 'a document without active sessions passes');

// 8f. 文档内多个历史活跃会话（旧数据不一致）不得阻断同步。
$GLOBALS['bojiTestUser'] = $userA;
$db->prepare('DELETE FROM active_workout_sessions WHERE user_id=?')->execute([$userA]);
tcheck(tguard([$yesterday => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => strtolower(commandUUID())],
               $today => ['workoutStartedAt' => tstamp(), 'activeWorkoutSessionID' => strtolower(commandUUID())]], $userA) !== null,
       'a new upload cannot introduce multiple active sessions');

echo "Training commands: {$GLOBALS['bojiTrainingChecks']} assertions passed\n";
