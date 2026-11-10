<?php
declare(strict_types=1);

require_once __DIR__ . '/action-jobs.php';

/**
 * Server-verified context for "continue asking about this report / workout".
 *
 * The client sends only a typed source reference (type + own client job id +
 * optional canonical version). The server checks ownership and kind, loads the
 * worker's immutable result, and injects a bounded snapshot. Client text is
 * never accepted as the source of truth.
 */

const CONTEXT_SOURCE_TYPES = ['report', 'weekly', 'workout'];

function contextSourceResolve(PDO $db, int $userId, mixed $source): array {
    if (!is_array($source)) throw new RuntimeException('缺少可继续追问的来源。', 422);
    $type = (string)($source['type'] ?? '');
    $id = strtolower(trim((string)($source['id'] ?? $source['job_id'] ?? '')));
    $version = isset($source['version']) ? (string)$source['version'] : null;
    if (!in_array($type, CONTEXT_SOURCE_TYPES, true)) throw new RuntimeException('来源类型不正确。', 422);
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D', $id)) throw new RuntimeException('来源编号不正确。', 422);
    $query = $db->prepare('SELECT client_job_id,server_job_id,kind,created_at,completed_at FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');
    $query->execute([$userId, $id]);
    $job = $query->fetch(PDO::FETCH_ASSOC);
    if (!$job) throw new RuntimeException('来源不存在或不属于当前账号。', 404);
    $expectedKinds = match ($type) { 'report' => ['report'], 'weekly' => ['weekly_review','coach'], 'workout' => ['coach'], default => [] };
    if (!in_array((string)$job['kind'], $expectedKinds, true)) throw new RuntimeException('来源类型不匹配。', 409);
    $canonicalVersion = (string)$job['created_at'];
    if ($version !== null && $version !== '' && !hash_equals($canonicalVersion, $version)) throw new RuntimeException('来源版本已变化，请重新打开后再继续。', 409);
    try {
        $raw = actionPrivateRequest($GLOBALS['config'] ?? [], 'GET', '/v1/jobs/' . strtolower((string)$job['server_job_id']), null, 8.0);
    } catch (Throwable) {
        throw new RuntimeException('来源内容暂时无法核对，请稍后重试；本机记录仍保留。', 503);
    }
    if (($raw['status'] ?? '') !== 'succeeded' || !is_array($raw['result'] ?? null)) throw new RuntimeException('来源尚未完成保存，不能作为继续追问的依据。', 409);
    $result = $raw['result'];
    $kind = (string)($result['kind'] ?? '');
    $snapshot = ['schema_version' => 1, 'type' => $type, 'job_id' => $id, 'version' => $canonicalVersion,
        'saved_kind' => $kind, 'created_at' => (string)$job['created_at']];
    if ($type === 'report') {
        if ($kind !== 'report') throw new RuntimeException('来源不是日报。', 409);
        foreach (['summary', 'training', 'nutrition', 'recovery'] as $key) {
            $value = $result[$key] ?? '';
            if (!is_string($value)) $value = '';
            $snapshot[$key] = mb_substr($value, 0, 5000);
        }
        $snapshot['notes'] = array_slice(array_values(array_filter(is_array($result['notes'] ?? null) ? $result['notes'] : [], 'is_string')), 0, 5);
    } elseif ($type === 'weekly') {
        if ($kind === 'coach' && ($result['coach']['purpose'] ?? '') === 'weekly') {
            $snapshot['summary'] = mb_substr((string)($result['coach']['answer'] ?? ''), 0, 5000);
        } elseif ($kind === 'weekly_review') {
            foreach (['summary', 'training', 'nutrition', 'recovery', 'next_week'] as $key) {
                $value = $result[$key] ?? '';
                if (is_string($value) && $value !== '') $snapshot[$key] = mb_substr($value, 0, 5000);
            }
        } else { throw new RuntimeException('来源不是已保存的周度解读。', 409); }
    } else {
        if ($kind !== 'coach' || !is_array($result['coach'] ?? null)) throw new RuntimeException('来源不是已保存的训练解读。', 409);
        $coach = $result['coach'];
        if (($coach['purpose'] ?? '') !== 'workout') throw new RuntimeException('来源不是训练解读。', 409);
        $session = (string)($coach['source_session'] ?? '');
        $requestedSession = strtolower(trim((string)($source['session_id'] ?? '')));
        if ($requestedSession !== '' && !hash_equals(strtolower($session), $requestedSession)) throw new RuntimeException('训练场次与来源不一致。', 409);
        $snapshot['answer'] = mb_substr((string)($coach['answer'] ?? ''), 0, 5000);
        $snapshot['source_session'] = $session !== '' ? $session : null;
    }
    return $snapshot;
}

function contextSourcePrompt(array $snapshot): array {
    return ['type' => $snapshot['type'], 'job_id' => $snapshot['job_id'], 'version' => $snapshot['version'],
        'saved_at' => $snapshot['created_at'],
        'content' => array_filter($snapshot, fn($key) => !in_array($key, ['schema_version', 'type', 'job_id', 'version', 'created_at', 'saved_kind'], true), ARRAY_FILTER_USE_KEY)];
}
