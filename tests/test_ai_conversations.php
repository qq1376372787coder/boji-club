<?php
declare(strict_types=1);
/**
 * M-1 conversation storage contract tests (Phase 2 §2.3).
 *
 * Covers: migration idempotency, turn record/complete idempotency, history
 * injection envelope (worker validation shape), pagination, conversation
 * counters, and cross-account isolation (R-22 first batch).
 *
 * Runs like the other SQL suites: tests/run_php_suite.sh (needs PHP 8.3 +
 * pdo_mysql + a disposable MySQL/MariaDB). The migration file itself is
 * re-applied on top of the base schema to prove idempotency.
 */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/ai-conversations.php';

$db = bojiTestDatabase('bojiclub_ai_conversations_test');

function check(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}

// The base schema (bojiTestSchema) already created the M-1 tables via
// schema.sql; re-apply the migration file to prove idempotency. Comment lines
// are stripped before splitting so a leading comment cannot swallow the first
// CREATE TABLE.
$migrationLines = file(__DIR__ . '/../account-server/migrations/20261024-ai-conversations.sql', FILE_IGNORE_NEW_LINES);
check(is_array($migrationLines), 'migration file readable');
$migrationSql = implode("\n", array_filter($migrationLines, fn(string $line): bool => !preg_match('/^\s*--/', $line)));
foreach (array_filter(array_map('trim', explode(';', $migrationSql))) as $statement) {
    if ($statement === '') continue;
    $db->exec($statement);
}

function userRow(PDO $db, int $id): int {
    $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,\'active\',UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute(['1390000000' . (string)$id]);
    return (int)$db->lastInsertId();
}
// 按手机号前缀清理本套件夹具（前一次失败退出时也能重跑），再插入新行。
$db->exec("DELETE FROM users WHERE phone LIKE '139%'");
$userA = userRow($db, 1);
$userB = userRow($db, 2);

$conv = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

// 1. Turn record is idempotent and stores the user question.
aiCoachTurnRecord($db, $userA, 'job-1', ['conversation_id' => $conv, 'question' => '今天练什么']);
aiCoachTurnRecord($db, $userA, 'job-1', ['conversation_id' => $conv, 'question' => '今天练什么']);
$count = (int)$db->query('SELECT COUNT(*) FROM ai_messages')->fetchColumn();
check($count === 1, 'duplicate submit does not duplicate the user row');
check((int)$db->query('SELECT message_count FROM ai_conversations')->fetchColumn() === 1, 'counter after record');

// 2. Invalid payloads are skipped silently (no row, no error).
aiCoachTurnRecord($db, $userA, 'job-2', ['conversation_id' => 'short', 'question' => 'x']);
aiCoachTurnRecord($db, $userA, 'job-3', ['question' => 'no conversation']);
aiCoachTurnRecord($db, $userA, 'job-4', ['conversation_id' => $conv, 'question' => '']);
check((int)$db->query('SELECT COUNT(*) FROM ai_messages')->fetchColumn() === 1, 'invalid payloads stored nothing');

// 3. History before completion: pending turn excluded, sequence empty.
check(aiCoachHistory($db, $userA, $conv) === [], 'no assistant yet means no injectable history');

// 4. Complete the turn: assistant row + card rows + counters.
$coach = [
    'answer' => '今天安排了推力日：平板杠铃卧推 3 组，按计划完成即可，练后记得确认保存。',
    'sources' => [], 'actions' => [],
    'cards' => [[
        'card_id' => 'card-001', 'card_type' => 'today_training', 'schema_version' => 1,
        'title' => '今日训练', 'payload' => ['date' => '2026-10-24', 'total_sets' => 3],
    ]],
];
aiCoachTurnComplete($db, $userA, 'job-1', $coach);
aiCoachTurnComplete($db, $userA, 'job-1', $coach); // retry idempotency
check((int)$db->query("SELECT COUNT(*) FROM ai_messages WHERE role='assistant'")->fetchColumn() === 1, 'retry does not duplicate the assistant row');
check((int)$db->query('SELECT COUNT(*) FROM ai_message_cards')->fetchColumn() === 1, 'one card row');
check((int)$db->query('SELECT message_count FROM ai_conversations')->fetchColumn() === 2, 'counter after complete');
$payload = $db->query("SELECT payload_json FROM ai_messages WHERE role='assistant'")->fetchColumn();
check(is_string($payload) && str_contains($payload, '今天安排了推力日'), 'assistant payload stored');

// 5. History injection shape (worker envelope): user→assistant pairs.
$history = aiCoachHistory($db, $userA, $conv);
check(count($history) === 2, 'one complete pair injects two rows');
check($history[0]['role'] === 'user' && $history[1]['role'] === 'assistant', 'history alternates user→assistant');
check($history[0]['text'] === '今天练什么', 'history carries the question');

// 6. A trailing pending turn is excluded from history.
aiCoachTurnRecord($db, $userA, 'job-5', ['conversation_id' => $conv, 'question' => '那明天呢']);
$history = aiCoachHistory($db, $userA, $conv);
check(count($history) === 2 && $history[1]['text'] !== '那明天呢', 'pending turn excluded from history');

// 7. Cap: six complete pairs = 12 rows; a seventh pair pushes the oldest out.
for ($i = 2; $i <= 7; $i++) {
    $job = 'job-pair-' . $i;
    aiCoachTurnRecord($db, $userA, $job, ['conversation_id' => $conv, 'question' => '问题' . $i]);
    aiCoachTurnComplete($db, $userA, $job, ['answer' => '回答' . $i . '，按实际记录核对后给出的建议内容。', 'sources' => [], 'actions' => []]);
}
$history = aiCoachHistory($db, $userA, $conv);
check(count($history) === 12, 'history caps at 12 rows');
check($history[0]['text'] === '问题2', 'oldest pair rotated out');
check($history[11]['role'] === 'assistant', 'history ends with assistant');
// Oversized completed text is trimmed to the worker's per-row cap.
aiCoachTurnRecord($db, $userA, 'job-big-q', ['conversation_id' => $conv, 'question' => str_repeat('问', 6000)]);
aiCoachTurnComplete($db, $userA, 'job-big-q', ['answer' => '超大输入也已完整落库，历史行按 worker 上限截断。', 'sources' => [], 'actions' => []]);
$oversize = aiCoachHistory($db, $userA, $conv);
$lastUser = $oversize[count($oversize) - 2]['text'] ?? '';
check(mb_strlen($lastUser) <= 4000, 'history text trimmed to 4000 chars');

// 8. Pagination: newest-first fetch reversed to ascending, has_more flag.
aiCoachTurnRecord($db, $userA, 'job-page', ['conversation_id' => $conv, 'question' => '分页检查']);
$page1 = aiConversationMessages($db, $userA, $conv, null, 4);
check(count($page1['messages']) === 4 && $page1['has_more'] === true, 'page 1 respects limit and flags more');
$firstId = $page1['messages'][0]['id'];
$page2 = aiConversationMessages($db, $userA, $conv, $firstId, 4);
check($page2['messages'][0]['id'] < $firstId, 'before-id pages descend by id');
check(count(array_unique(array_merge(
    array_column($page1['messages'], 'id'), array_column($page2['messages'], 'id')
))) === count($page1['messages']) + count($page2['messages']), 'pages do not overlap');
$assistantPage = array_values(array_filter($page1['messages'], fn($m) => $m['role'] === 'assistant'));
check(isset($assistantPage[0]['coach']['answer']) || isset($page2['messages'][0]['coach']), 'assistant rows carry the coach payload');

// 9. R-22 cross-account isolation: user 2 sees nothing of user 1.
check(aiConversationList($db, $userB) === [], 'another account lists no conversations');
$page = aiConversationMessages($db, $userB, $conv, null, 10);
check($page['messages'] === [] && $page['has_more'] === false, 'another account reads no messages');
aiCoachTurnRecord($db, $userB, 'job-1', ['conversation_id' => $conv, 'question' => '别人的今天练什么']);
$historyB = aiCoachHistory($db, $userB, $conv);
check($historyB === [], 'another account injects no history');
check((int)$db->query('SELECT COUNT(DISTINCT user_id) FROM ai_conversations')->fetchColumn() === 2, 'same conversation id stays scoped per user');

// 10. List endpoint shape for the owner.
$list = aiConversationList($db, $userA);
check(count($list) === 1, 'owner lists the conversation once');
check($list[0]['id'] === $conv && $list[0]['message_count'] > 0, 'list carries counters');

// 11. Conversation with no rows messages -> empty page.
$page = aiConversationMessages($db, $userA, 'ffffffff-ffff-ffff-ffff-ffffffffffff', null, 10);
check($page['messages'] === [], 'unknown conversation returns empty page');

$db->exec("DELETE FROM users WHERE id IN ($userA,$userB)");
echo "ai conversations contract passed\n";
