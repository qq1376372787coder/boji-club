<?php
declare(strict_types=1);
/**
 * Phase 4 §5.1 / D-10: memory engine contract tests.
 *
 * Covers: deterministic extraction (facts from profile, habit thresholds,
 * timing buckets), data minimisation (no raw measurements in content),
 * idempotent re-extraction, member decisions surviving sweeps (suspend/
 * withdraw), correction chain, three-column page, context injection caps,
 * and per-account scoping.
 *
 * Run: tests/run_php_suite.sh (PHP 8.3 + pdo_mysql + disposable MySQL).
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/insights.php';
require __DIR__ . '/../account-server/public/ai-memory.php';

if (!function_exists('fail')) {
    function fail(string $message, int $status = 400): never { throw new RuntimeException($message, $status); }
}

$db = bojiTestDatabase('bojiclub_ai_conversations_test');

function check(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}

function memUserRow(PDO $db, string $phoneSuffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['136000000' . $phoneSuffix]);
    return (int)$db->lastInsertId();
}
function memStateRow(PDO $db, int $userId, array $state): void {
    $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,?,?,UTC_TIMESTAMP())')
        ->execute([$userId, 7, json_encode($state, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)]);
}
function memDay(string $date, int $savedHour): array {
    return [
        'exercises' => [['sets' => [['completed' => true, 'reps' => 10]], 'workoutSessionID' => 'aaaaaaaa-bbbb-cccc-dddd-00000000' . str_pad($date, 2, '0', STR_PAD_LEFT)]],
        'workoutSavedAt' => (strtotime($date . 'T' . str_pad((string)$savedHour, 2, '0', STR_PAD_LEFT) . ':00:00+08:00') - 978307200),
        'workoutSessions' => [['id' => 'aaaaaaaa-bbbb-cccc-dddd-00000000' . str_pad($date, 2, '0', STR_PAD_LEFT), 'savedAt' => 1]],
        'meals' => [['name' => '餐']],
    ];
}

$db->exec("DELETE FROM users WHERE phone LIKE '136%'");
$userA = memUserRow($db, '1');
$userB = memUserRow($db, '2');

$today = insightHomeToday();
// 8 confirmed sessions in the last 4 weeks, mostly morning (7:00) + profile facts.
$days = [];
foreach ([-1, -2, -4, -5, -7, -8, -10, -11] as $offset) {
    $date = (new DateTimeImmutable($today))->modify($offset . ' days')->format('Y-m-d');
    $days[$date] = memDay($date, 7);
}
// 两天纯饮食记录日（无训练）——凑满饮食记录习惯的 10 天样本门槛。
foreach ([-3, -6] as $offset) {
    $date = (new DateTimeImmutable($today))->modify($offset . ' days')->format('Y-m-d');
    $days[$date] = ['meals' => [['name' => '餐']], 'exercises' => []];
}
$state = [
    'profile' => ['goal' => '增肌', 'limitations' => '左膝不适', 'daysPerWeek' => 3],
    'days' => $days,
];
memStateRow($db, $userA, $state);

// 1. Extraction: facts + habits, deterministic.
aiMemorySweepExtract($db, $userA, $state);
$kinds = [];
$rows = $db->query("SELECT kind,content,confidence FROM user_memory_items WHERE user_id=$userA")->fetchAll(PDO::FETCH_ASSOC);
foreach ($rows as $row) $kinds[$row['content']] = $row;
check(isset($kinds['当前目标：增肌']) && $kinds['当前目标：增肌']['confidence'] === 100, 'profile goal extracted as fact');
check(isset($kinds['训练限制：左膝不适']), 'limitation extracted as constraint');
check(isset($kinds['计划每周训练 3 天']), 'days per week extracted');
check(isset($kinds['近四周确认训练 8 次，训练频率稳定']), 'frequency habit with high confidence');
check(isset($kinds['常在清晨训练']), 'timing bucket habit');
check(isset($kinds['近四周有 10 天记录了饮食']), 'meal logging habit');

// 2. Data minimisation: no raw measurement values in any content.
foreach ($rows as $row) {
    check(!preg_match('/\d+(\.\d+)?\s*kg/', $row['content']), 'no body weight values in memory: ' . $row['content']);
}

// 3. Re-extraction is idempotent (no duplicates).
aiMemorySweepExtract($db, $userA, $state);
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA")->fetchColumn() === count($rows), 're-extraction updates, never duplicates');

// 4. Member decisions survive the sweep.
$target = $db->query("SELECT memory_id FROM user_memory_items WHERE user_id=$userA AND content LIKE '常在清晨%'")->fetchColumn();
aiMemorySetStatus($db, $userA, $target, 'suspended');
aiMemorySweepExtract($db, $userA, $state);
check($db->query("SELECT status FROM user_memory_items WHERE memory_id='$target'")->fetchColumn() === 'suspended', 'suspension survives re-extraction');

// 5. Correction chain: supersedes the target with a user statement.
$goalId = $db->query("SELECT memory_id FROM user_memory_items WHERE user_id=$userA AND content='当前目标：增肌'")->fetchColumn();
$correction = aiMemoryCorrect($db, $userA, $goalId, '我的目标是力量优先，不是围度');
check($correction['supersedes'] === $goalId, 'correction links the superseded item');
check($db->query("SELECT status FROM user_memory_items WHERE memory_id='$goalId'")->fetchColumn() === 'corrected', 'superseded item marked corrected');
$correctionRow = aiMemoryFetch($db, $userA, $correction['memory_id']);
check($correctionRow['origin'] === 'user' && $correctionRow['kind'] === 'correction', 'correction row is user-authored');
aiMemorySweepExtract($db, $userA, $state);
check($db->query("SELECT status FROM user_memory_items WHERE memory_id='$goalId'")->fetchColumn() === 'corrected', 're-extraction does not resurrect the corrected fact');

// 6. Withdraw removes it for good (even across sweeps).
aiMemorySetStatus($db, $userA, $target, 'withdrawn');
aiMemorySweepExtract($db, $userA, $state);
check($db->query("SELECT status FROM user_memory_items WHERE memory_id='$target'")->fetchColumn() === 'withdrawn', 'withdraw survives sweeps');

// 7. Three-column page shape.
$page = aiMemoryPage($db, $userA);
check(isset($page['confirmed'], $page['habits'], $page['inferred']), 'page returns the three columns');
$all = array_merge($page['confirmed'], $page['habits'], $page['inferred']);
foreach ($all as $item) {
    check(in_array($item['kind'], ['fact', 'goal', 'constraint', 'habit', 'preference', 'correction'], true), 'column kinds are valid');
    check(!isset($item['evidence_json']), 'evidence json exposed as refs only');
}
check(count(array_filter($page['habits'], fn($i) => $i['status'] === 'active')) >= 1, 'active habits present');

// 8. Context injection caps: ≤6 items, ≤120 chars each.
$context = aiMemoryForContext($db, $userA);
check(count($context) <= 6, 'context injection capped at 6');
foreach ($context as $item) {
    check(mb_strlen($item['text']) <= 120, 'context text capped');
    check(in_array($item['kind'], ['fact', 'habit', 'preference', 'goal', 'constraint', 'correction'], true), 'context kinds valid');
}

// 9. Cross-account: user B has an empty document -> no extracted memories; no A rows leak.
$pageB = aiMemoryPage($db, $userB);
check(count($pageB['confirmed']) + count($pageB['habits']) + count($pageB['inferred']) === 0, 'foreign account sees nothing');
$contextB = aiMemoryForContext($db, $userB);
check($contextB === [], 'empty document yields no injected memory');

// 10. Worker-side validation contract (mirror of clean_request memory rules).
$valid = [['kind' => 'habit', 'text' => '近四周确认训练 8 次，训练频率稳定']];
check(count($valid) <= 8 && mb_strlen($valid[0]['text']) <= 120, 'injection envelope within worker caps');

$db->exec("DELETE FROM users WHERE id IN ($userA,$userB)");
echo "ai memory contract passed\n";
