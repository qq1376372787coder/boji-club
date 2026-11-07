<?php
declare(strict_types=1);

/**
 * M-1 (Phase 2 §2.3): server-side coach conversation storage.
 *
 * Write path: weekly.php records the user turn when a coach job is submitted
 * (idempotent per client job id) and completes the assistant turn when the
 * relayed result reports success. Function-only module: every helper takes an
 * explicit PDO so tests can drive them without the HTTP router.
 *
 * Privacy boundary: conversation content stays inside the member's own account
 * rows (user_id FK with ON DELETE CASCADE into account deletion). History is
 * injected back into the same member's coach requests only; the model never
 * sees another account's rows.
 */

function aiConversationIdValid(mixed $value): bool {
    return is_string($value) && preg_match('/^[0-9a-f-]{8,64}$/D', $value) === 1;
}

function aiConversationEnsure(PDO $db, int $userId, string $conversationId): int {
    $now = 'UTC_TIMESTAMP()';
    $insert = $db->prepare(
        'INSERT INTO ai_conversations(user_id,conversation_id,message_count,first_message_at,last_message_at,created_at,updated_at)
         VALUES(?,?,0,' . $now . ',' . $now . ',' . $now . ',' . $now . ')
         ON DUPLICATE KEY UPDATE updated_at=' . $now);
    $insert->execute([$userId, $conversationId]);
    $row = $db->prepare('SELECT id FROM ai_conversations WHERE user_id=? AND conversation_id=?');
    $row->execute([$userId, $conversationId]);
    $id = $row->fetchColumn();
    if (!is_string($id) && !is_int($id)) throw new RuntimeException('conversation row missing');
    return (int)$id;
}

/** Recompute denormalized counters from the rows themselves (no drift). */
function aiConversationRefreshCounters(PDO $db, int $conversationRowId): void {
    $counts = $db->prepare('SELECT COUNT(*), MIN(created_at), MAX(created_at) FROM ai_messages WHERE conversation_row_id=?');
    $counts->execute([$conversationRowId]);
    [$count, $first, $last] = $counts->fetch(PDO::FETCH_NUM);
    $update = $db->prepare(
        'UPDATE ai_conversations SET message_count=?,first_message_at=?,last_message_at=?,updated_at=UTC_TIMESTAMP() WHERE id=?');
    $update->execute([(int)$count, $first, $last, $conversationRowId]);
}

/**
 * Record the user turn at coach submit time. Idempotent: resubmitting the same
 * client job id rewrites the same row (UNIQUE user+job+role).
 */
function aiCoachTurnRecord(PDO $db, int $userId, string $clientId, mixed $payload): void {
    if (!aiConversationIdValid($payload['conversation_id'] ?? null)) return;
    $question = $payload['question'] ?? '';
    if (!is_string($question) || $question === '' || mb_strlen($question) > 4000) return;
    $conversationRowId = aiConversationEnsure($db, $userId, (string)$payload['conversation_id']);
    $insert = $db->prepare(
        'INSERT INTO ai_messages(user_id,conversation_row_id,job_client_id,role,content,payload_json,created_at,updated_at)
         VALUES(?,?,?,\'user\',?,NULL,UTC_TIMESTAMP(),UTC_TIMESTAMP())
         ON DUPLICATE KEY UPDATE content=VALUES(content),updated_at=UTC_TIMESTAMP()');
    $insert->execute([$userId, $conversationRowId, $clientId, $question]);
    aiConversationRefreshCounters($db, $conversationRowId);
}

/** Store the validated coach result (assistant turn + card rows). Idempotent on retry. */
function aiCoachTurnComplete(PDO $db, int $userId, string $clientId, array $coach): void {
    $db->beginTransaction();
    try {
        aiCoachTurnCompleteTx($db, $userId, $clientId, $coach, false);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

/**
 * Transactional assistant turn + cards. Caller owns the transaction.
 * $strict=true makes a missing user turn a hard failure (the SSE run path must
 * never report completion without a recoverable answer); the legacy polling
 * path keeps its historical best-effort behaviour.
 */
function aiCoachTurnCompleteTx(PDO $db, int $userId, string $clientId, array $coach, bool $strict = true): array {
    $answer = $coach['answer'] ?? '';
    if (!is_string($answer) || $answer === '') {
        if ($strict) throw new RuntimeException('assistant_answer_missing');
        return ['message_id' => null, 'cards' => 0];
    }
    $row = $db->prepare('SELECT id,conversation_row_id FROM ai_messages WHERE user_id=? AND job_client_id=? AND role=\'user\'');
    $row->execute([$userId, $clientId]);
    $turn = $row->fetch(PDO::FETCH_ASSOC);
    if (!$turn) {
        if ($strict) throw new RuntimeException('conversation_user_turn_missing');
        return ['message_id' => null, 'cards' => 0];
    }
    $conversationRowId = (int)$turn['conversation_row_id'];
    $payloadJson = json_encode($coach, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    if (strlen($payloadJson) > 400000) $payloadJson = null;
    $upsert = $db->prepare(
        'INSERT INTO ai_messages(user_id,conversation_row_id,job_client_id,role,content,payload_json,created_at,updated_at)
         VALUES(?,?,?,\'assistant\',?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())
         ON DUPLICATE KEY UPDATE content=VALUES(content),payload_json=VALUES(payload_json),updated_at=UTC_TIMESTAMP()');
    $upsert->execute([$userId, $conversationRowId, $clientId, $answer, $payloadJson]);
    $assistantId = $db->prepare('SELECT id FROM ai_messages WHERE user_id=? AND job_client_id=? AND role=\'assistant\'');
    $assistantId->execute([$userId, $clientId]);
    $messageId = (int)$assistantId->fetchColumn();
    if ($messageId < 1) throw new RuntimeException('assistant_message_missing');
    $db->prepare('DELETE FROM ai_message_cards WHERE message_id=?')->execute([$messageId]);
    $cardCount = 0;
    $cards = $coach['cards'] ?? [];
    if (is_array($cards)) {
        $cardInsert = $db->prepare(
            'INSERT INTO ai_message_cards(message_id,card_id,card_type,schema_version,title,payload_json,created_at)
             VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())');
        foreach ($cards as $card) {
            if (!is_array($card)) continue;
            $cardId = $card['card_id'] ?? ''; $type = $card['card_type'] ?? '';
            $title = $card['title'] ?? ''; $version = $card['schema_version'] ?? 0;
            if (!is_string($cardId) || $cardId === '' || strlen($cardId) > 64) continue;
            if (!is_string($type) || $type === '' || strlen($type) > 32) continue;
            if (!is_string($title) || mb_strlen($title) > 120) continue;
            if (!is_int($version)) continue;
            $cardJson = json_encode($card, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
            $cardInsert->execute([$messageId, $cardId, $type, $version, $title, $cardJson]);
            $cardCount++;
        }
    }
    aiConversationRefreshCounters($db, $conversationRowId);
    return ['message_id' => $messageId, 'cards' => $cardCount];
}

/**
 * Server-authoritative history for the model context: the last complete pairs
 * of this conversation, capped at the worker's validation envelope (≤12 rows,
 * ≤4000 chars each, ≤16000 total, user→assistant alternation). A trailing
 * user turn without an assistant reply (pending or failed job) is excluded so
 * the injected sequence always ends with the assistant.
 */
function aiCoachHistory(PDO $db, int $userId, string $conversationId): array {
    $row = $db->prepare('SELECT id FROM ai_conversations WHERE user_id=? AND conversation_id=?');
    $row->execute([$userId, $conversationId]);
    $conversationRowId = $row->fetchColumn();
    if (!is_string($conversationRowId) && !is_int($conversationRowId)) return [];
    // Exact pairing by job id: a failed/pending turn simply has no assistant
    // row and cannot corrupt the pairing of later turns (order-based scanning
    // would mispair concurrent turns).
    $query = $db->prepare(
        'SELECT u.content AS q, a.content AS a FROM ai_messages u
         JOIN ai_messages a ON a.user_id=u.user_id AND a.job_client_id=u.job_client_id AND a.role=\'assistant\'
         WHERE u.role=\'user\' AND u.conversation_row_id=? ORDER BY u.id DESC LIMIT 12');
    $query->execute([(int)$conversationRowId]);
    $pairs = array_reverse($query->fetchAll(PDO::FETCH_ASSOC));
    // Newest pairs first, within the worker's envelope (≤12 rows, ≤4000 chars
    // each, ≤16000 total), oldest pair dropped first.
    $history = [];
    $total = 0;
    for ($i = count($pairs) - 1; $i >= 0 && count($history) < 12; $i--) {
        $userText = mb_substr((string)$pairs[$i]['q'], 0, 4000);
        $assistantText = mb_substr((string)$pairs[$i]['a'], 0, 4000);
        if ($total + mb_strlen($userText) + mb_strlen($assistantText) > 16000) break;
        $total += mb_strlen($userText) + mb_strlen($assistantText);
        array_unshift($history, ['role' => 'assistant', 'text' => $assistantText]);
        array_unshift($history, ['role' => 'user', 'text' => $userText]);
    }
    return $history;
}


function aiConversationList(PDO $db, int $userId, int $limit = 50): array {
    $limit = max(1, min($limit, 100));
    $query = $db->prepare(
        'SELECT conversation_id,message_count,first_message_at,last_message_at
         FROM ai_conversations WHERE user_id=? ORDER BY last_message_at DESC LIMIT ' . $limit);
    $query->execute([$userId]);
    $items = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $items[] = ['id' => $row['conversation_id'], 'message_count' => (int)$row['message_count'],
                    'first_message_at' => $row['first_message_at'], 'last_message_at' => $row['last_message_at']];
    }
    return $items;
}

/** Paged messages for ONE conversation, ascending. Unknown or foreign conversations return empty. */
function aiConversationMessages(PDO $db, int $userId, string $conversationId, ?int $beforeId, int $limit = 30): array {
    $limit = max(1, min($limit, 50));
    $conversation = $db->prepare('SELECT id FROM ai_conversations WHERE user_id=? AND conversation_id=?');
    $conversation->execute([$userId, $conversationId]);
    $conversationRowId = $conversation->fetchColumn();
    if (!is_string($conversationRowId) && !is_int($conversationRowId)) return ['messages' => [], 'has_more' => false];
    $query = $db->prepare(
        'SELECT id,role,content,payload_json,created_at FROM ai_messages
         WHERE conversation_row_id=?' . ($beforeId !== null ? ' AND id<?' : '') .
        ' ORDER BY id DESC LIMIT ' . ($limit + 1));
    $query->execute($beforeId !== null ? [(int)$conversationRowId, $beforeId] : [(int)$conversationRowId]);
    $rows = array_reverse($query->fetchAll(PDO::FETCH_ASSOC));
    $hasMore = count($rows) > $limit;
    if ($hasMore) array_shift($rows);
    $messages = [];
    foreach ($rows as $row) {
        $message = ['id' => (int)$row['id'], 'role' => $row['role'], 'content' => $row['content'],
                    'created_at' => $row['created_at']];
        if ($row['role'] === 'assistant' && is_string($row['payload_json'])) {
            $decoded = json_decode($row['payload_json'], true);
            if (is_array($decoded)) $message['coach'] = $decoded;
        }
        $messages[] = $message;
    }
    return ['messages' => $messages, 'has_more' => $hasMore];
}
