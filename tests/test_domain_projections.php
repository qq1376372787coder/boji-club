<?php
declare(strict_types=1);
/**
 * Phase 4/5: event consumers, projection freshness, reconciliation and the
 * memory feedback loop.
 *
 * Covers: per-consumer dedup (a repeated delivery applies nothing), consumer
 * routing by event type, projection freshness rows, notification projection,
 * reconciliation of a missed event, and the memory feedback loop.
 *
 * Run: tests/run_php_suite.sh (PHP 8.3 + pdo_mysql + disposable MySQL).
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/cloud-validation.php';
require __DIR__ . '/../account-server/public/ai-proposals.php';
require __DIR__ . '/../account-server/public/commands.php';
require __DIR__ . '/../account-server/public/domain-consumers.php';

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
        throw new ProjectionRespondOK($payload);
    }
}
class ProjectionRespondOK extends RuntimeException {
    public function __construct(public readonly array $payload) { parent::__construct('respond'); }
}
if (!function_exists('appFeatureEnabled')) {
    function appFeatureEnabled(PDO $db, string $key): bool { return true; }
}

$db = bojiTestDatabase('bojiclub_it');

function pcheck(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
    $GLOBALS['bojiProjectionChecks'] = ($GLOBALS['bojiProjectionChecks'] ?? 0) + 1;
}
function puser(PDO $db, string $suffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['137100000' . $suffix]);
    return (int)$db->lastInsertId();
}
function pscalar(PDO $db, string $sql): int {
    return (int)$db->query($sql)->fetchColumn();
}

$db->exec("DELETE FROM users WHERE phone LIKE '1371%'");
$user = puser($db, '01');
$eventID = strtoupper(businessUUID());
$event = ['event_id' => $eventID, 'operation_id' => strtoupper(businessUUID()), 'user_id' => $user,
          'aggregate_type' => 'training', 'aggregate_id' => '2026-10-25', 'aggregate_version' => 2,
          'event_type' => 'WorkoutSessionFinished.v1', 'payload' => json_encode(['date' => '2026-10-25'])];

// 1. consumer routing by event type
pcheck(in_array('notifications-v1', outboxConsumersFor('WorkoutSessionFinished.v1'), true), 'training events reach the notification consumer');
pcheck(in_array('club-progress-v1', outboxConsumersFor('WorkoutSessionFinished.v1'), true), 'training events reach the club projection');
pcheck(!in_array('notifications-v1', outboxConsumersFor('ProfileUpdated'), true), 'unrelated events do not reach the notification consumer');
pcheck(in_array('personal-memory-v1', outboxConsumersFor('ProfileUpdated'), true), 'memory extraction sees every event');

// 2. dispatch applies every interested consumer exactly once
$applied = outboxDispatch($db, $event);
pcheck($applied === count(outboxConsumersFor('WorkoutSessionFinished.v1')), 'dispatch applies every interested consumer');
pcheck(pscalar($db, "SELECT COUNT(*) FROM domain_consumer_inbox WHERE event_id='{$eventID}'") === $applied, 'one receipt per consumer');
pcheck(pscalar($db, "SELECT COUNT(*) FROM domain_projection_state WHERE user_id={$user}") === $applied, 'projection freshness rows are written');
pcheck(pscalar($db, "SELECT COUNT(*) FROM notification_deliveries WHERE user_id={$user}") === 0, 'without an authorized device no notification is fabricated');

// 3. a repeated delivery applies nothing (idempotent consumer)
$appliedAgain = outboxDispatch($db, $event);
pcheck($appliedAgain === 0, 'a repeated delivery is a no-op');
pcheck(pscalar($db, "SELECT COUNT(*) FROM notification_deliveries WHERE user_id={$user}") === 0, 'a repeated delivery never duplicates a notification');
pcheck(pscalar($db, "SELECT COUNT(*) FROM domain_consumer_inbox WHERE event_id='{$eventID}'") === $applied, 'receipts are not duplicated');

// 4. reconciliation finds a missed event and requeues it
$missedEvent = strtoupper(businessUUID());
$db->prepare("INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,status,attempts,next_attempt,created_at,updated_at)
              VALUES(?,?,?,'training','2026-10-25',3,'WorkoutSetLogged.v1','{}','published',0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")
    ->execute([$missedEvent, strtoupper(businessUUID()), $user]);
$result = domainReconcile($db, ['club-progress-v1']);
pcheck($result['missing'] >= 1, 'reconciliation detects the missed event');
pcheck($result['requeued'] >= 1, 'reconciliation requeues the missed event');
$status = $db->prepare("SELECT status FROM domain_outbox WHERE event_id=?");
$status->execute([$missedEvent]);
pcheck($status->fetchColumn() === 'pending', 'the missed event is back in the queue');
outboxDispatch($db, ['event_id' => $missedEvent, 'user_id' => $user, 'event_type' => 'WorkoutSetLogged.v1', 'payload' => '{}']);
$after = domainReconcile($db, ['club-progress-v1']);
pcheck($after['missing'] === 0, 'reconciliation converges after the consumer ran');
pcheck(pscalar($db, "SELECT COUNT(*) FROM notification_deliveries WHERE user_id={$user}") === 0, 'set events never create training-completed notifications');

// 5. the memory feedback loop moves confidence, corrections still win
$memoryID = strtoupper(businessUUID());
$db->prepare("INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,source_revision,created_at,updated_at)
              VALUES(?,?,'habit','active','extracted','训练日偏好',60,'[]',?,0,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
    ->execute([$memoryID, $user, hash('sha256', 'memory-fixture')]);
$updated = aiMemoryApplyFeedback($db, $user, ['name' => 'memory_feedback', 'target_id' => $memoryID, 'action' => 'helpful']);
pcheck($updated !== null && $updated['confidence'] === 70, 'helpful feedback raises the memory confidence');
$updated = aiMemoryApplyFeedback($db, $user, ['name' => 'memory_feedback', 'target_id' => $memoryID, 'action' => 'wrong']);
pcheck($updated !== null && $updated['confidence'] === 40, 'wrong feedback lowers the memory confidence');
$updated = aiMemoryApplyFeedback($db, $user, ['name' => 'memory_feedback', 'target_id' => $memoryID, 'action' => 'unknown']);
pcheck($updated === null, 'an unknown feedback action changes nothing');
$updated = aiMemoryApplyFeedback($db, $user, ['name' => 'memory_feedback', 'target_id' => strtoupper(businessUUID()), 'action' => 'helpful']);
pcheck($updated === null, 'feedback for a foreign memory changes nothing');
aiMemoryCorrect($db, $user, $memoryID, '训练日不固定');
$corrected = aiMemoryFetch($db, $user, $memoryID);
pcheck($corrected['status'] === 'corrected', 'an explicit correction supersedes the derived memory');
$updated = aiMemoryApplyFeedback($db, $user, ['name' => 'memory_feedback', 'target_id' => $memoryID, 'action' => 'helpful']);
pcheck($updated === null, 'feedback never revives a corrected memory');

echo "Domain projections: {$GLOBALS['bojiProjectionChecks']} assertions passed\n";
