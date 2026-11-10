<?php
declare(strict_types=1);
/**
 * Phase 3 §4.1 / M-2: proposal state machine + proposal-anchored command
 * execution contract tests.
 *
 * Covers: payload validators, lifecycle transitions, idempotent creation,
 * expiry sweep, cross-account isolation, and the three confirm commands
 * (PlanReschedule.Confirm / Meal.Create / BodyWeight.Create) including CAS
 * guards, proposal-status transitions, data_operations audit and outbox rows.
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
    // 行锁的真实实现在 index.php（读 users 行 FOR UPDATE）；夹具用户均为 active，
    // 测试内无并发写同一账号，no-op 即可。
    function lockActiveUser(PDO $db, int $uid): void {}
}
if (!function_exists('respond')) {
    function respond(int $status, array $payload): never {
        if ($status >= 400) throw new RuntimeException((string)($payload['error'] ?? 'http'), $status);
        throw new httpRespondOK($payload);
    }
}
class httpRespondOK extends RuntimeException {
    public function __construct(public readonly array $payload) { parent::__construct('respond'); }
}

$db = bojiTestDatabase('bojiclub_ai_conversations_test');
// 409 conflict paths inside the command handler call respond(409, ...) which
// must roll back AND mark the proposal conflict — emulated above by throwing.

function check(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}

function propDate(string $fixture): string {
    $offset = (int)(new DateTimeImmutable('2026-10-24'))->diff(new DateTimeImmutable($fixture))->format('%r%a');
    return (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify("+$offset days")->format('Y-m-d');
}

function propUserRow(PDO $db, string $phoneSuffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['137000000' . $phoneSuffix]);
    return (int)$db->lastInsertId();
}
function propStateRow(PDO $db, int $userId, array $days): void {
    $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')
        ->execute([$userId, json_encode(['days' => $days], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)]);
}
function propDay(string $date, array $exercises): array {
    return ['exercises' => $exercises, 'meals' => []];
}
function propExercise(string $name, int $sets): array {
    return ['id' => strtoupper(commandUUID()), 'name' => $name, 'muscle' => '腿', 'sets' => array_map(fn($i) => ['id' => strtoupper(commandUUID()), 'weight' => 20, 'reps' => 10, 'completed' => false], range(1, $sets))];
}

// Fixture DB shared with other AI suites: clean our prefix first.
$db->exec("DELETE FROM users WHERE phone LIKE '137%'");
$userA = propUserRow($db, '1');
$userB = propUserRow($db, '2');

// State: plan on 2026-10-26 and 2026-10-27 (future, unprotected), nothing on 10-28.
propStateRow($db, $userA, [
    propDate('2026-10-26') => propDay(propDate('2026-10-26'), [propExercise('杠铃卧推', 3)]),
    propDate('2026-10-27') => propDay(propDate('2026-10-27'), [propExercise('杠铃深蹲', 4)]),
]);

// 1. Payload validators.
check(aiProposalPayloadValid('meal_draft', ['date' => propDate('2026-10-25'), 'meals' => [['name' => '燕麦碗', 'category' => '早餐', 'calories' => 320]]]) !== null, 'valid meal draft');
check(aiProposalPayloadValid('meal_draft', ['date' => propDate('2026-10-25'), 'meals' => [['name' => 'x', 'category' => '宵夜']]]) === null, 'unknown category rejected');
check(aiProposalPayloadValid('meal_draft', ['date' => 'bad', 'meals' => [['name' => 'x', 'category' => '加餐']]]) === null, 'bad date rejected');
check(aiProposalPayloadValid('weight_entry', ['date' => propDate('2026-10-25'), 'kilograms' => 72.5]) !== null, 'valid weight entry');
check(aiProposalPayloadValid('weight_entry', ['date' => propDate('2026-10-25'), 'kilograms' => 500]) === null, 'absurd weight rejected');
check(aiProposalPayloadValid('plan_change_proposal', ['moves' => [['from' => propDate('2026-10-26'), 'to' => propDate('2026-10-28')]]]) !== null, 'valid moves');
check(aiProposalPayloadValid('plan_change_proposal', ['moves' => [['from' => propDate('2026-10-26'), 'to' => propDate('2026-10-26')]]]) === null, 'same-day move rejected');

// 2. Create: awaiting_confirmation + idempotency.
$idem = hash_hmac('sha256', 'p', 'test');
$created = aiProposalCreate($db, $userA, 'plan_change_proposal',
    ['moves' => [['from' => propDate('2026-10-26'), 'to' => propDate('2026-10-28')]]],
    ['day/2026-10-26'], 'conv-1', $idem);
check($created['status'] === 'awaiting_confirmation' && $created['idempotent'] === false, 'created as awaiting_confirmation');
$again = aiProposalCreate($db, $userA, 'plan_change_proposal',
    ['moves' => [['from' => propDate('2026-10-26'), 'to' => propDate('2026-10-28')]]],
    ['day/2026-10-26'], 'conv-1', $idem);
check($again['idempotent'] === true && $again['proposal_id'] === $created['proposal_id'], 'same idempotency key returns the same proposal');
$pid = $created['proposal_id'];
check((int)$db->query('SELECT COUNT(*) FROM ai_action_proposals')->fetchColumn() === 1, 'no duplicate rows');

// 3. Cross-account: user B cannot see user A's proposal.
check(aiProposalFetch($db, $userB, $pid) === null, 'foreign proposal invisible');

// 4. Confirm through the command handler: full transaction path.
$commandId = '11111111-2222-3333-4444-555555555555';
$stateBefore = (int)$db->query('SELECT revision FROM app_states WHERE user_id=' . $userA)->fetchColumn();
$result = handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => $commandId, 'type' => 'PlanReschedule.Confirm',
    'payload' => ['proposalId' => $pid], 'expectedVersions' => [], 'actor' => 'user',
], $commandId);
check($result['status'] === 'succeeded', 'confirm command succeeds');
$state = json_decode($db->query("SELECT state_json FROM app_states WHERE user_id=$userA")->fetchColumn(), true);
check(empty($state['days'][propDate('2026-10-26')]['exercises']) && !empty($state['days'][propDate('2026-10-28')]['exercises']), 'exercises moved to the target day');
check((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE operation_id='$commandId'")->fetchColumn() === 1, 'audit row written');
check((int)$db->query("SELECT COUNT(*) FROM domain_outbox WHERE event_type='PlanRescheduled' AND user_id=$userA")->fetchColumn() === 1, 'outbox event written');
check($db->query("SELECT status FROM ai_action_proposals WHERE proposal_id='$pid'")->fetchColumn() === 'succeeded', 'proposal succeeded');
check((int)$db->query('SELECT COUNT(*) FROM ai_action_executions')->fetchColumn() === 1, 'execution row written');
check((int)$db->query('SELECT revision FROM app_states WHERE user_id=' . $userA)->fetchColumn() === $stateBefore + 1, 'document revision bumped');

// 5. Idempotent replay of the same commandId.
$replay = handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => $commandId, 'type' => 'PlanReschedule.Confirm',
    'payload' => ['proposalId' => $pid], 'expectedVersions' => [], 'actor' => 'user',
]);
check($replay['idempotent'] === true, 'command replay is idempotent');
check((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE operation_id='$commandId'")->fetchColumn() === 1, 'replay does not duplicate audit');

// 6. A lost response can be recovered even when the caller regenerated its command UUID.
$recovery = handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => '11111111-2222-3333-4444-555555555556', 'type' => 'PlanReschedule.Confirm',
    'payload' => ['proposalId' => $pid], 'expectedVersions' => [], 'actor' => 'user',
]);
check($recovery['idempotent'] === true, 'completed proposal recovers success without a second write');

// 7. Meal.Create appends to the day and satisfies the day schema.
$meal = aiProposalCreate($db, $userA, 'meal_draft',
    ['date' => propDate('2026-10-25'), 'meals' => [['name' => '燕麦碗', 'category' => '早餐', 'calories' => 320, 'protein' => 14]]],
    [], null, null);
handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => '11111111-2222-3333-4444-555555555557', 'type' => 'Meal.Create',
    'payload' => ['proposalId' => $meal['proposal_id']], 'expectedVersions' => [], 'actor' => 'user',
]);
$state = json_decode($db->query("SELECT state_json FROM app_states WHERE user_id=$userA")->fetchColumn(), true);
check(count($state['days'][propDate('2026-10-25')]['meals']) === 1, 'meal appended');
check($state['days'][propDate('2026-10-25')]['meals'][0]['sourceAIJobID'] === $meal['proposal_id'], 'meal carries the proposal provenance');
check(isset($state['days'][propDate('2026-10-25')]['exercises']), 'meal-only day still satisfies the day schema');
cloudValidate($state['days'][propDate('2026-10-25')], 'day', 'days.2026-10-25');

// 8. BodyWeight.Create.
$weight = aiProposalCreate($db, $userA, 'weight_entry',
    ['date' => propDate('2026-10-25'), 'kilograms' => 72.5, 'bodyFatPercentage' => 18.2], [], null, null);
handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => '11111111-2222-3333-4444-555555555558', 'type' => 'BodyWeight.Create',
    'payload' => ['proposalId' => $weight['proposal_id']], 'expectedVersions' => [], 'actor' => 'user',
]);
$state = json_decode($db->query("SELECT state_json FROM app_states WHERE user_id=$userA")->fetchColumn(), true);
check(abs(($state['days'][propDate('2026-10-25')]['bodyWeight']['kilograms'] ?? 0) - 72.5) < 0.001, 'weight recorded');
// The document contract is a reference-epoch number; Swift Date encodes a
// Double (sub-second), so an integer-only assertion was too strict.
$updatedAt = $state['days'][propDate('2026-10-25')]['bodyWeight']['updatedAt'];
check((is_int($updatedAt) || is_float($updatedAt)) && $updatedAt > 0, 'updatedAt is a reference-epoch number');
cloudValidate($state['days'][propDate('2026-10-25')], 'day', 'days.2026-10-25');

// 9. Conflict: document changed after the preview (target day occupied) -> 409 + proposal conflict.
$stale = aiProposalCreate($db, $userA, 'plan_change_proposal',
    ['moves' => [['from' => propDate('2026-10-27'), 'to' => propDate('2026-10-29')]]], [], null, null);
$state = json_decode($db->query("SELECT state_json FROM app_states WHERE user_id=$userA")->fetchColumn(), true);
$state['days'][propDate('2026-10-29')]['exercises'] = [propExercise('冲突占用', 2)]; // occupy the target AFTER preview
$db->prepare('UPDATE app_states SET state_json=?,revision=revision+1 WHERE user_id=?')
    ->execute([json_encode($state, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), $userA]);
$conflicted = false;
try { handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => '11111111-2222-3333-4444-555555555559', 'type' => 'PlanReschedule.Confirm',
    'payload' => ['proposalId' => $stale['proposal_id']], 'expectedVersions' => [], 'actor' => 'user',
]); } catch (httpRespondOK $r) { $conflicted = $r->payload['conflict'] ?? false; } catch (RuntimeException $e) { $conflicted = $e->getCode() === 409; }
check($conflicted, 'stale preview conflicts');
check($db->query("SELECT status FROM ai_action_proposals WHERE proposal_id='{$stale['proposal_id']}'")->fetchColumn() === 'conflict', 'conflict terminal state recorded');
check((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE command_type='PlanReschedule.Confirm' AND aggregate_id LIKE '%2026-10-27%'")->fetchColumn() === 0, 'conflicted write never lands');

// 10. Expiry sweep: due proposals cannot be confirmed.
$expired = aiProposalCreate($db, $userA, 'meal_draft',
    ['date' => propDate('2026-10-25'), 'meals' => [['name' => '过期餐', 'category' => '加餐']]], [], null, null);
$db->exec("UPDATE ai_action_proposals SET expires_at=DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 HOUR) WHERE proposal_id='{$expired['proposal_id']}'");
$expiredRejected = false;
try { handleBusinessCommandCore($db, ['id' => $userA], [
    'commandId' => '11111111-2222-3333-4444-555555555560', 'type' => 'Meal.Create',
    'payload' => ['proposalId' => $expired['proposal_id']], 'expectedVersions' => [], 'actor' => 'user',
]); } catch (RuntimeException $e) { $expiredRejected = $e->getCode() === 409; }
check($expiredRejected, 'expired proposal cannot be confirmed');
check($db->query("SELECT status FROM ai_action_proposals WHERE proposal_id='{$expired['proposal_id']}'")->fetchColumn() === 'expired', 'sweep marks expired');

// 11. Partitioned account uses the same atomic command semantics.
$meta = ['profile' => []];
cloudPartPut($db, $userB, 'meta', $meta);
cloudPartPut($db, $userB, 'd/' . propDate('2026-10-26'), propDay(propDate('2026-10-26'), [propExercise('卧推', 3)]));
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')
    ->execute([$userB, json_encode(cloudPartMetadata($meta))]);
$partProp = aiProposalCreate($db, $userB, 'plan_change_proposal',
    ['moves' => [['from' => propDate('2026-10-26'), 'to' => propDate('2026-10-28')]]], [], null, null);
$partResult = handleBusinessCommandCore($db, ['id' => $userB], [
    'commandId' => '11111111-2222-3333-4444-555555555561', 'type' => 'PlanReschedule.Confirm',
    'payload' => ['proposalId' => $partProp['proposal_id']], 'expectedVersions' => [], 'actor' => 'user',
]);
check($partResult['status'] === 'succeeded', 'partitioned write succeeds');
check(!empty(cloudPartGet($db, $userB, 'd/' . propDate('2026-10-28'))['exercises']), 'partitioned target contains moved exercises');
check((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE user_id=$userB")->fetchColumn() === 1, 'partitioned write is audited');

$db->exec("DELETE FROM users WHERE id IN ($userA,$userB)");
echo "ai proposals contract passed\n";
