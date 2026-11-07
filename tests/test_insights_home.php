<?php
declare(strict_types=1);
/**
 * Phase 2 §2.5 / D-09: server-owned home insight contract tests.
 *
 * Covers: weekly-review follow-up requires server verification, training
 * rhythm counting (club progress semantics), fact field validation, priority
 * picking, and per-account scoping (verified rows belong to one user).
 *
 * Run: tests/run_php_suite.sh (PHP 8.3 + pdo_mysql + disposable MySQL).
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/insights.php';

// 隔离的伪服务配置：未核验复盘会走 legacy weekly 路径（weeklyAiJobID 需要
// otp_secret）；base_url 指向黑洞端口，绝不触碰本机真实 AI worker。
$GLOBALS['config'] = ['otp_secret' => 'test-only-otp-secret-0123456789abcdef',
                      'ai_proxy_base_url' => 'http://127.0.0.1:9',
                      'ai_proxy_token' => 'test-token-0123456789abcdef'];

$db = bojiTestDatabase('bojiclub_ai_conversations_test');

function check(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}

function insightUserRow(PDO $db, string $phoneSuffix): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['138000000' . $phoneSuffix]);
    return (int)$db->lastInsertId();
}
// 按手机号前缀清理本套件夹具（前一次失败退出时也能重跑），再插入新行；
// user id 用 lastInsertId（其他套件可能已消耗自增序号，不能硬编码）。
$db->exec("DELETE FROM users WHERE phone LIKE '138%'");
$userA = insightUserRow($db, '1');
$userB = insightUserRow($db, '2');

const TODAY = '2026-10-24';
$conv = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

// Fixture: a verified weekly review on 2026-10-22 + confirmed training on 10-22/10-23.
$state = [
    'days' => [
        '2026-10-22' => [
            'exercises' => [['sets' => [['completed' => true, 'reps' => 10]], 'workoutSessionID' => 'aaaaaaaa-bbbb-cccc-dddd-000000000001']],
            'workoutSavedAt' => '2026-10-22T10:00:00Z',
            'workoutSessions' => [['id' => 'aaaaaaaa-bbbb-cccc-dddd-000000000001', 'savedAt' => 1]],
            'weeklyReview' => ['jobID' => 'aaaaaaaa-bbbb-cccc-dddd-000000000009', 'result' => ['summary' => 'ok']],
        ],
        '2026-10-23' => [
            'exercises' => [['sets' => [['completed' => true, 'reps' => 8]], 'workoutSessionID' => 'aaaaaaaa-bbbb-cccc-dddd-000000000002']],
            'workoutSavedAt' => '2026-10-23T10:00:00Z',
            'workoutSessions' => [['id' => 'aaaaaaaa-bbbb-cccc-dddd-000000000002', 'savedAt' => 2]],
        ],
        '2026-10-30' => [ // future date must be ignored
            'exercises' => [['sets' => [['completed' => true, 'reps' => 5]]]],
            'workoutSavedAt' => '2026-10-30T10:00:00Z',
        ],
    ],
];

// Pre-verify the weekly job FOR USER 1 ONLY (user 2 gets no verification row).
$db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,completed_at,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
    ->execute([$userA, 'aaaaaaaa-bbbb-cccc-dddd-000000000009', 'bbbbbbbb-cccc-dddd-eeee-000000000001', 'weekly_review']);

// 1. User 1: weekly review wins (priority 108 > 104).
$pick = insightHomePick($db, $userA, $state, TODAY);
check(is_array($pick) && $pick['priority'] === 108, 'verified weekly review becomes the top fact');
check($pick['kind'] === 'workout' && $pick['title'] === '训练复盘已生成', 'weekly review fact shape');
check(in_array('job/aaaaaaaa-bbbb-cccc-dddd-000000000009', $pick['evidence_refs'], true), 'carries job evidence ref');
check(in_array('day/2026-10-22', $pick['evidence_refs'], true), 'carries day evidence ref');

// 2. Without verification the weekly review is not claimed (no fact for user 2's copy).
$pick2 = insightHomePick($db, $userB, $state, TODAY);
check(is_array($pick2) && $pick2['priority'] === 104, 'unverified review is not claimed; training rhythm remains');
check($pick2['kind'] === 'training' && $pick2['title'] === '最近 7 天已确认 2 次训练', 'training rhythm counts confirmed days only');

// 3. Future days never count.
check(!str_contains(json_encode($pick2), 'day/2026-10-30'), 'future date excluded from evidence refs');

// 4. Empty state -> null (client keeps local rules).
check(insightHomePick($db, $userA, ['days' => []], TODAY) === null, 'empty state yields no insight');

// 5. Malformed facts are dropped by the validator.
check(insightHomeFact(['id' => '', 'kind' => 'training', 'title' => 'x', 'detail' => 'x', 'evidence' => 'x', 'priority' => 1, 'evidence_refs' => []]) === null, 'empty id rejected');
check(insightHomeFact(['id' => 'a', 'kind' => 'unknown', 'title' => 'x', 'detail' => 'x', 'evidence' => 'x', 'priority' => 1, 'evidence_refs' => []]) === null, 'unknown kind rejected');
check(insightHomeFact(['id' => 'a', 'kind' => 'training', 'title' => 'x', 'detail' => 'x', 'evidence' => 'x', 'priority' => 1, 'evidence_refs' => [['bad']]]) === null, 'non-string ref rejected');
$ok = insightHomeFact(['id' => 'a', 'kind' => 'training', 'title' => 'x', 'detail' => 'x', 'evidence' => 'x', 'priority' => 1, 'evidence_refs' => ['day/2026-10-24']]);
check(is_array($ok) && $ok['evidence_refs'] === ['day/2026-10-24'], 'valid fact passes');

// 6. Unconfirmed training (no savedAt) does not count toward the rhythm.
$partial = ['days' => ['2026-10-24' => ['exercises' => [['sets' => [['completed' => true, 'reps' => 5]]]]]]];
$pick3 = insightHomePick($db, $userA, $partial, TODAY);
check($pick3 === null, 'unconfirmed sets are not claimed as training days');

// 7. Consistency with the club progress source of truth (same fixture, same window).
require_once __DIR__ . '/../account-server/public/club-progress.php';
$GLOBALS['bojiClubProgressWindow'] = ['2026-10-18', TODAY];
$refs = [];
foreach ($state['days'] as $date => $day) {
    if (is_array($day['weeklyReview'] ?? null) && is_string($day['weeklyReview']['jobID'] ?? null)) $refs[] = ['id' => $day['weeklyReview']['jobID'], 'kind' => 'weekly_review'];
}
$verified = verifiedAICompletions($db, $userA, $refs);
$index = clubBuildProgressIndex($state, TODAY, fn($id, $kind) => $verified[strtolower((string)$id)] ?? false);
$windowCount = clubProgressRange($index, '2026-10-18', TODAY)['training_days'];
check($windowCount === 2, 'club progress index agrees on the confirmed count');

$db->exec('DELETE FROM users WHERE id IN (1,2)');
echo "insights home contract passed\n";
