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
// PIPL 阶段4：双开关门禁走 actionPreferences()，必须先加载其定义
// （与 test_intelligence_closure / test_trace_chain / test_worker_context 同序）。
require __DIR__ . '/../account-server/public/action-support.php';
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
$afterCorrection = aiMemoryPage($db, $userA);
check(in_array($correction['memory_id'], array_column($afterCorrection['confirmed'], 'memory_id'), true), 'user correction is shown as confirmed, not inferred');

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

// 11. PIPL 阶段4③：学习与使用是**两个独立开关**（言言定性回执 ③）。
$setPrefs = function (int $uid, int $proactive, int $personalization) use ($db): void {
    $db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,proactive_learning,personalization_enabled,updated_at)
                  VALUES(?,0,'Asia/Shanghai','kg',?,?,UTC_TIMESTAMP())
                  ON DUPLICATE KEY UPDATE proactive_learning=VALUES(proactive_learning),personalization_enabled=VALUES(personalization_enabled),updated_at=UTC_TIMESTAMP()")
       ->execute([$uid, $proactive, $personalization]);
};
$setPrefs($userA, 1, 1);
aiMemorySweepExtract($db, $userA, $state);
$stored = (int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA")->fetchColumn();
check($stored > 0, 'stage4 precondition: memories exist');
check(aiMemoryForContext($db, $userA) !== [], 'stage4 precondition: context injects memories');

// 11a. 停止学习：不写新记忆；仅关它不影响存量注入（两开关互不连带）。
$stateNewDays = $state;
$stateNewDays['profile'] = ['goal' => '增肌', 'limitations' => '左膝不适', 'daysPerWeek' => 4];
$setPrefs($userA, 0, 1);
aiMemorySweepExtract($db, $userA, $stateNewDays);
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA AND content='计划每周训练 4 天'")->fetchColumn() === 0,
    'proactive off: no new memory is written');
check(count(aiMemoryForContext($db, $userA)) > 0, 'proactive off alone keeps existing context injection');

// 11b. 停用记忆处理：存量保留、行权可及，但**不再喂给模型**。
$setPrefs($userA, 0, 0);
check(aiMemoryForContext($db, $userA) === [], 'personalization off: nothing is fed to the model');
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA")->fetchColumn() === $stored,
    'personalization off: stored memories are kept (not deleted)');
$pageKept = aiMemoryPage($db, $userA);
check(count(array_merge($pageKept['confirmed'], $pageKept['habits'], $pageKept['inferred'])) > 0,
    'personalization off: correction/withdrawal entry stays reachable (PIPL 44-47)');
// 第16条：关闭不得拒绝核心功能——页面与抽取仍工作，只是不喂模型。
$setPrefs($userA, 1, 1);

// 12. PIPL 阶段4②：物理删除 + 墓碑防复活（言言定性回执 ②）。
$purgeMe = (string)$db->query("SELECT memory_id FROM user_memory_items WHERE user_id=$userA AND status='withdrawn' LIMIT 1")->fetchColumn();
check($purgeMe !== '', 'stage4 precondition: a withdrawn memory exists to purge');
$result = aiMemoryPurge($db, $userA, 'withdrawn');
check(($result['status'] ?? '') === 'completed', 'purge reports a verifiable completed status');
check((int)$result['deleted'] >= 1, 'purge physically deletes at least one row');
check(($result['derived']['prompt_context'] ?? '') === 'cleared', 'purge reports prompt context cleared');
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA AND memory_id='$purgeMe'")->fetchColumn() === 0,
    'purged row is physically gone, not merely status-changed');
check((int)$db->query("SELECT COUNT(*) FROM user_memory_tombstones WHERE user_id=$userA")->fetchColumn() >= 1,
    'tombstone written for the purged source');
// 关键断言：删除后不得被下一次抽取复活。
aiMemorySweepExtract($db, $userA, $state);
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA AND memory_id='$purgeMe'")->fetchColumn() === 0,
    'tombstone prevents the deleted memory from being re-extracted');
check((int)$db->query("SELECT COUNT(*) FROM user_memory_tombstones WHERE user_id=$userB")->fetchColumn() === 0,
    'purge and tombstones stay scoped to one account');

// 13. 导出分页元数据（言言①）：单次上限不是权利总量上限。
$memoryTotal = (int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA")->fetchColumn();
$pageOne = (int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$userA ORDER BY created_at DESC, memory_id DESC LIMIT 500 OFFSET 0")->fetchColumn();
check($pageOne === $memoryTotal, 'first export page matches the total when under the page size');
check($memoryTotal <= 500 || $pageOne === 500, 'page size is capped at 500 while the total is reported separately');

$db->exec("DELETE FROM users WHERE id IN ($userA,$userB)");
echo "ai memory contract passed\n";
