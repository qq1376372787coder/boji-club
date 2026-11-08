<?php
declare(strict_types=1);
require_once __DIR__ . '/app-config.php';
require_once __DIR__ . '/chat-input.php';
require_once __DIR__.'/ai-context.php';

/**
 * Phase 2 (spec §3.1–3.3): durable AI Run + SSE transport.
 *
 * POST creates a persistent run and a normal ai_user_jobs row (same quota,
 * membership and conversation records as the polling path). A CLI worker does
 * the model I/O and appends ordered events. GET only subscribes; closing the
 * connection never cancels the run. SSE carries progress and validated text —
 * it never grants a write: cards still confirm through the proposal endpoint.
 */

require_once __DIR__ . '/ai-response.php';
require_once __DIR__ . '/ai-conversations.php';
require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/onboarding-v2.php';
require_once __DIR__ . '/context-continuation.php';

const AI_RUN_LEASE_SECONDS = 150;
const AI_RUN_MAX_ATTEMPTS = 3;
const AI_RUN_SSE_MAX_SECONDS = 25;

function aiRunCanonical(mixed $value): mixed {
    if (!is_array($value)) return $value;
    if (!array_is_list($value)) ksort($value);
    foreach ($value as $key => $item) $value[$key] = aiRunCanonical($item);
    return $value;
}

function aiRunHash(array $request): string {
    return hash('sha256', json_encode(aiRunCanonical($request), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
}

/** Dynamic server context is not part of the client's idempotent identity. */
function aiRunStableHash(array $request): string {
    if (isset($request['payload']) && is_array($request['payload'])) {
        unset($request['payload']['_onboarding_context']);
        if(isset($request['payload']['_context_source'])) {
            $source=$request['payload']['_context_source'];
            $request['payload']['_context_source']=array_intersect_key($source,array_flip(['type','job_id','version','source_session']));
        }
    }
    return aiRunHash($request);
}

function aiRunTraceId(): string {
    return bin2hex(random_bytes(16));
}

function aiRunFetch(PDO $db, int $userId, string $runId): ?array {
    if (!preg_match('/^[0-9a-f-]{36}$/iD', $runId)) return null;
    $query = $db->prepare('SELECT * FROM ai_runs WHERE user_id=? AND id=?');
    $query->execute([$userId, strtolower($runId)]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function aiRunResyncRequired(array $row, int $afterSeq): bool {
    return $afterSeq < (int)($row['event_floor'] ?? 1) - 1;
}

/** Delete old terminal event logs, keep snapshot, raise event_floor. */
function aiRunPruneEvents(PDO $db, int $days = 30, int $batch = 100): array {
    $days = max(1, min(365, $days));
    $batch = max(1, min(500, $batch));
    $deletedEvents = 0; $prunedRuns = 0; $staleRuns = 0;
    $db->beginTransaction();
    try {
        $stale = $db->prepare("SELECT id FROM ai_runs WHERE status='running' AND lease_expires_at IS NOT NULL
            AND lease_expires_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 24 HOUR) LIMIT " . $batch . ' FOR UPDATE SKIP LOCKED');
        $stale->execute();
        $ids = $stale->fetchAll(PDO::FETCH_COLUMN);
        if ($ids) {
            $marks = implode(',', array_fill(0, count($ids), '?'));
            $db->prepare("UPDATE ai_runs SET status='failed',error_code='WORKER_ABANDONED',lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id IN (" . $marks . ')')
                ->execute($ids);
            $staleRuns = count($ids);
        }
        $query = $db->prepare("SELECT id,last_seq,event_floor FROM ai_runs
            WHERE status IN ('completed','failed','cancelled')
              AND updated_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL " . $days . " DAY)
              AND event_floor <= last_seq
            ORDER BY updated_at LIMIT " . $batch . ' FOR UPDATE SKIP LOCKED');
        $query->execute();
        $rows = $query->fetchAll(PDO::FETCH_ASSOC);
        $delete = $db->prepare('DELETE FROM ai_run_events WHERE run_id=? AND seq<=?');
        $bump = $db->prepare('UPDATE ai_runs SET event_floor=last_seq+1,updated_at=UTC_TIMESTAMP() WHERE id=?');
        foreach ($rows as $row) {
            $delete->execute([$row['id'], (int)$row['last_seq']]);
            $deletedEvents += $delete->rowCount();
            $bump->execute([$row['id']]);
            $prunedRuns++;
        }
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
    return ['retention_days'=>$days,'pruned_runs'=>$prunedRuns,'deleted_events'=>$deletedEvents,'stale_runs_failed'=>$staleRuns];
}

function aiRunTerminal(string $status): bool {
    return in_array($status, ['completed', 'failed', 'cancelled'], true);
}

function aiRunPublic(array $row, bool $idempotent = false): array {
    return [
        'run_id' => (string)$row['id'],
        'message_id' => (string)$row['message_id'],
        'status' => (string)$row['status'],
        'stream_url' => '/me/ai/runs/' . $row['id'] . '/events',
        'last_event_seq' => (int)$row['last_seq'],
        'trace_id' => (string)$row['trace_id'],
        'idempotent' => $idempotent,
    ];
}

/** Allocate the next per-run sequence and persist one event. */
function aiRunAppend(PDO $db, string $runId, string $type, array $data, ?string $leaseOwner = null): int {
    $own = !$db->inTransaction();
    if ($own) $db->beginTransaction();
    try {
        $lock = $db->prepare('SELECT last_seq,status,lease_owner,lease_expires_at FROM ai_runs WHERE id=? FOR UPDATE');
        $lock->execute([$runId]);
        $row = $lock->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new RuntimeException('run_missing');
        // A terminal run never accepts model output again; a worker that lost
        // its lease cannot append progress or a second completion.
        if (aiRunTerminal((string)$row['status'])) throw new RuntimeException('run_terminal', 409);
        if ($leaseOwner !== null) {
            if (!hash_equals((string)($row['lease_owner'] ?? ''), $leaseOwner)) throw new RuntimeException('lease_lost', 409);
            if ($row['lease_expires_at'] !== null && strtotime((string)$row['lease_expires_at'] . ' UTC') < time()) {
                throw new RuntimeException('lease_expired', 409);
            }
        }
        $seq = (int)$row['last_seq'] + 1;
        $eventId = actionUUID('ai-run-event/' . $runId . '/' . $seq);
        $envelope = [
            'run_id' => $runId, 'seq' => $seq, 'event_id' => $eventId,
            'type' => $type, 'ts' => gmdate('c'), 'ts_ms'=>(int)round(microtime(true)*1000), 'data' => $data,
        ];
        $db->prepare('INSERT INTO ai_run_events(run_id,seq,event_id,type,data_json,created_at) VALUES(?,?,?,?,?,UTC_TIMESTAMP())')
            ->execute([$runId, $seq, $eventId, $type,
                       json_encode($envelope, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $db->prepare('UPDATE ai_runs SET last_seq=?,updated_at=UTC_TIMESTAMP() WHERE id=?')->execute([$seq, $runId]);
        if ($own) $db->commit();
        return $seq;
    } catch (Throwable $error) {
        if ($own && $db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

/** Legacy helper. It can never overwrite a terminal state such as cancelled. */
function aiRunSetStatus(PDO $db, string $runId, string $status, ?string $errorCode = null, ?array $result = null): void {
    $own = !$db->inTransaction();
    if ($own) $db->beginTransaction();
    try {
        $lock = $db->prepare('SELECT status FROM ai_runs WHERE id=? FOR UPDATE');
        $lock->execute([$runId]);
        $current = $lock->fetchColumn();
        if ($current === false) throw new RuntimeException('run_missing');
        if (aiRunTerminal((string)$current) && (string)$current !== $status) throw new RuntimeException('run_terminal', 409);
        $db->prepare('UPDATE ai_runs SET status=?,error_code=?,result_json=COALESCE(?,result_json),lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?')
            ->execute([$status, $errorCode, $result === null ? null : json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $runId]);
        if ($own) $db->commit();
    } catch (Throwable $error) {
        if ($own && $db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

function aiRunEvents(PDO $db, string $runId, int $afterSeq, int $limit = 100): array {
    $limit = max(1, min($limit, 200));
    $query = $db->prepare('SELECT seq,type,data_json,created_at FROM ai_run_events WHERE run_id=? AND seq>? ORDER BY seq ASC LIMIT ' . $limit);
    $query->execute([$runId, max(0, $afterSeq)]);
    $events = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $decoded = json_decode((string)$row['data_json'], true);
        $seq = (int)$row['seq'];
        $events[] = is_array($decoded) ? $decoded : [
            'run_id' => $runId, 'seq' => $seq,
            'event_id' => actionUUID('ai-run-event/' . $runId . '/' . $seq),
            'type' => $row['type'], 'ts' => gmdate('c', strtotime((string)$row['created_at'] . ' UTC')), 'data' => [],
        ];
    }
    return $events;
}

/** POST /me/ai/conversations/{id}/runs — idempotent durable run creation. */
function aiRunCreate(PDO $db, array $user, array $config, string $conversationId, array $body, ?string $idempotencyKey = null): array {
    $uid = (int)$user['id'];
    // P2 休眠：coach 开关放在最前，休眠时统一回 coach_disabled（而不是先被
    // ai_enabled / ai_streaming_v2 的文案盖住），便于客户端识别唯一原因。
    if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');
    if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 分析暂未开放，请稍后再试。', 503);
    if (!appFeatureEnabled($db, 'ai_streaming_v2')) fail('流式对话暂未开放，请稍后再试。', 503);
    $clientId = strtolower(trim((string)($body['client_message_id'] ?? '')));
    if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D', $clientId)) fail('消息编号不正确。', 400);
    $idempotencyKey = strtolower(trim((string)($idempotencyKey ?? '')));
    if ($idempotencyKey === '') fail('缺少幂等标识（Idempotency-Key）。', 400);
    if (!hash_equals($clientId, $idempotencyKey)) fail('幂等标识与消息编号不一致。', 409);
    if (!aiConversationIdValid($conversationId)) fail('对话编号不正确。', 400);
    if (!empty($body['attachments'])) fail('附件请放在本条消息的 images 字段中。', 422);

    $request = $body['request'] ?? null;
    if (!is_array($request) || ($request['kind'] ?? '') !== 'coach') fail('请求格式不正确。', 400);
    $payload = $request['payload'] ?? null;
    if (!is_array($payload)) fail('请求格式不正确。', 400);
    if (($payload['conversation_id'] ?? null) !== $conversationId) fail('对话编号不一致。', 400);
    $question = trim((string)($payload['question'] ?? ''));
    if ($question === '' || mb_strlen($question) > 1200) fail('请把这次问题控制在 1200 字以内。', 422);
    $message = $body['message'] ?? null;
    if (is_array($message)) {
        if (($message['type'] ?? 'text') !== 'text') fail('当前只支持文字消息。', 422);
        $text = trim((string)($message['text'] ?? ''));
        if ($text !== '' && $text !== $question) fail('消息内容与请求不一致。', 422);
    }

    // Purpose is server-derived. The client may keep its legacy dialogue /
    // workout / weekly purposes, but onboarding_assist and context_continue
    // are never accepted from the wire.
    unset($payload['_onboarding_context'], $payload['_context_source'], $payload['_onboarding_session_id'], $payload['onboarding_session_id'], $payload['context_source']);
    $clientPurpose = (string)($payload['purpose'] ?? 'dialogue');
    if (!in_array($clientPurpose, ['dialogue', 'workout', 'weekly'], true)) fail('当前对话用途不正确。', 422);
    $serverPurpose = $clientPurpose;
    $onboardingSessionId = null;
    $onboardingSession = null;
    if (isset($body['onboarding_session_id'])) {
        $onboardingSessionId = strtolower(trim((string)$body['onboarding_session_id']));
        if (!preg_match('/^[0-9a-f-]{36}$/D', $onboardingSessionId)) fail('引导会话编号不正确。', 422);
        $onboardingSession = onboardingSessionRead($db, $uid, $onboardingSessionId);
        if (!$onboardingSession) fail('引导会话不存在。', 404);
        if ((string)$onboardingSession['status'] === 'completed') fail('引导已经结束，请使用普通对话。', 409);
        if (!hash_equals((string)$onboardingSession['conversation_id'], $conversationId)) fail('引导对话编号不一致。', 409);
        $serverPurpose = 'onboarding_assist';
        $payload['purpose'] = 'onboarding_assist';
        $payload['_onboarding_session_id'] = $onboardingSessionId;
    } elseif (isset($body['context_source'])) {
        $snapshot = contextSourceResolve($db, $uid, $body['context_source']);
        $serverPurpose = 'context_continue';
        $payload['purpose'] = 'context_continue';
        $payload['_context_source'] = contextSourcePrompt($snapshot);
    } else {
        $payload['purpose'] = $serverPurpose;
    }
    $clientTimeZone = $body['client_timezone'] ?? null;
    if (is_string($clientTimeZone) && $clientTimeZone !== '') {
        try { $zone = new DateTimeZone($clientTimeZone); $payload['timeZone'] = $zone->getName(); }
        catch (Exception) { fail('时区不正确。', 422); }
    }
    unset($payload['_references'],$payload['_intent'],$payload['reference_selection']);
    if(isset($payload['context_bundle_id'])) {
        if(!appFeatureEnabled($db,'ai_context_references_v1'))fail('引用功能暂未开放。',503);
        $payload['days']=[];$payload['upcoming']=[];
    }
    $request['payload'] = $payload;
    $requestHash = aiRunStableHash($request);
    $serverJobId = aiJobID($user, $clientId, $config);
    $traceId = aiRunTraceId();

    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        $existing = $db->prepare('SELECT * FROM ai_runs WHERE user_id=? AND client_message_id=? FOR UPDATE');
        $existing->execute([$uid, $clientId]);
        $row = $existing->fetch(PDO::FETCH_ASSOC) ?: null;
        if ($row) {
            if (!hash_equals((string)$row['request_hash'], $requestHash)) {
                $db->rollBack();
                fail('同一消息编号不能用于不同的提问。', 409);
            }
            $db->commit();
            return aiRunPublic($row, true);
        }
        require_once __DIR__.'/usage-guard131.php'; usageGuard131($db,$uid,$config);
        $job = $db->prepare('SELECT server_job_id,kind,created_at,purpose,onboarding_session_id FROM ai_user_jobs WHERE user_id=? AND client_job_id=? FOR UPDATE');
        $job->execute([$uid, $clientId]);
        $existingJob = $job->fetch(PDO::FETCH_ASSOC) ?: null;
        if ($existingJob && $existingJob['kind'] !== 'coach') {
            $db->rollBack();
            fail('消息编号已经用于其他分析。', 409);
        }
        if ($existingJob && (string)($existingJob['purpose'] ?? '') !== $serverPurpose) {
            $db->rollBack();
            fail('同一消息编号不能更换对话用途。', 409);
        }
        if (!$row) {
            aiProviderConsentAssert($db,$uid,$payload);
            if(isset($payload['context_bundle_id'])) aiContextLoad($db,$uid,(string)$payload['context_bundle_id'],$conversationId,$config);
            try { chatValidateInput($db,$uid,$request); }
            catch (RuntimeException $e) { $db->rollBack(); fail($e->getMessage(), in_array($e->getCode(),[409,422],true)?$e->getCode():422); }
        }
        if (!aiMayPostJob($db, $user, $config, 'coach', $existingJob, $serverPurpose)) {
            $db->rollBack();
            fail('请先开通会员后使用此功能。', 403);
        }
        if ($serverPurpose !== 'onboarding_assist' && $existingJob === null && aiCoachQuotaLeft($db, $uid) <= 0) {
            $db->rollBack();
            header('Retry-After: ' . max(60, 86400 - ((time() + 8 * 3600) % 86400)));
            fail('今天的对话次数已达上限，明天再继续。', 429);
        }
        if (!$existingJob) {
            $db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,purpose,onboarding_session_id,created_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())')
                ->execute([$uid, $clientId, $serverJobId, 'coach', $serverPurpose,
                           $serverPurpose === 'onboarding_assist' ? $onboardingSessionId : null]);
        }
        $activeLimit = max(1, min(5, (int)($config['ai_max_active_runs'] ?? 2)));
        $active = $db->prepare("SELECT COUNT(*) FROM ai_runs WHERE user_id=? AND status IN ('queued','running')");
        $active->execute([$uid]);
        if ((int)$active->fetchColumn() >= $activeLimit) {
            $db->rollBack();
            fail('当前有未完成的对话任务，请等待完成或取消后再发送。', 429);
        }
        $sameConversation = $db->prepare("SELECT COUNT(*) FROM ai_runs WHERE user_id=? AND conversation_id=? AND status IN ('queued','running')");
        $sameConversation->execute([$uid, $conversationId]);
        if ((int)$sameConversation->fetchColumn() > 0) {
            $db->rollBack();
            fail('这个对话已有进行中的任务，请等待完成。', 429);
        }
        if ($serverPurpose === 'onboarding_assist') {
            $reserved = onboardingAssistReserve($db, $uid, (string)$onboardingSessionId);
            $onboardingSession = $reserved['session'];
            $payload['_onboarding_context'] = onboardingAssistContext($db, $uid, $onboardingSession, $question);
            $request['payload'] = $payload;
        }
        $runId = actionUUID('ai-run/' . $uid . '/' . $clientId);
        $db->prepare('INSERT INTO ai_runs(id,user_id,conversation_id,client_message_id,server_job_id,message_id,trace_id,status,last_seq,request_hash,request_json,attempts,created_at,updated_at)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,0,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
            ->execute([$runId, $uid, $conversationId, $clientId, $serverJobId, $clientId, $traceId, 'queued', 1, $requestHash,
                       json_encode($request, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $envelope = ['run_id' => $runId, 'seq' => 1, 'event_id' => actionUUID('ai-run-event/' . $runId . '/1'), 'type' => 'run.created',
                     'ts' => gmdate('c'), 'data' => ['status' => 'queued', 'message_id' => $clientId, 'trace_id' => $traceId,
                                                     'purpose' => $serverPurpose]];
        $db->prepare('INSERT INTO ai_run_events(run_id,seq,event_id,type,data_json,created_at) VALUES(?,1,?,?,?,UTC_TIMESTAMP())')
            ->execute([$runId, $envelope['event_id'], 'run.created',
                       json_encode($envelope, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        if ($serverPurpose === 'onboarding_assist') {
            // Onboarding turns use a separate bounded transcript; they must not
            // pollute the member's ordinary coach history.
            onboardingAssistRecordTurn($db, $uid, (string)$onboardingSessionId, 'user', $question);
        } else {
            aiCoachTurnRecord($db, $uid, $clientId, $payload);
            $db->prepare("INSERT IGNORE INTO ai_action_messages(user_id,message_id,conversation_id,trace_id,status,created_at,updated_at) VALUES(?,?,?,?,'accepted',UTC_TIMESTAMP(),UTC_TIMESTAMP())")
                ->execute([$uid, $clientId, $conversationId, $traceId]);
        }
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        if ($error instanceof RuntimeException && $error->getCode() >= 400 && $error->getCode() < 600) {
            fail($error->getMessage(), $error->getCode());
        }
        throw $error;
    }

    if (is_string($payload['timeZone'] ?? null)) {
        try {
            $zone = new DateTimeZone((string)$payload['timeZone']);
            $db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,updated_at) VALUES(?,0,?,'kg',UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE time_zone=VALUES(time_zone),updated_at=UTC_TIMESTAMP()")
                ->execute([$uid, $zone->getName()]);
        } catch (Throwable) { /* non-fatal preference */ }
    }
    return [
        'run_id' => $runId, 'message_id' => $clientId, 'status' => 'queued',
        'stream_url' => '/me/ai/runs/' . $runId . '/events',
        'last_event_seq' => 1, 'trace_id' => $traceId, 'idempotent' => false,
        'purpose' => $serverPurpose,
    ];
}

/** Kinds the durable Run path serves. Phase 1: report + weekly_review only. */
const AI_RUN_KINDS = ['report', 'weekly_review'];

/**
 * POST /me/ai/jobs/runs — durable Run creation for non-coach kinds.
 *
 * Uses the same Python job identity as the legacy polling path (aiJobID), so a
 * client that falls back after a lost response never double-submits and both
 * paths converge on one ai_user_jobs row.
 */
function aiRunCreateForKind(PDO $db, array $user, array $config, string $kind, array $body, ?string $idempotencyKey): array {
    $uid = (int)$user['id'];
    // Gate order mirrors aiRunCreate: the run-v2 switch comes first so the client
    // can tell "not enabled" apart from "AI disabled" (distinct error_code).
    if (!aiRunV2Enabled($db)) fail('Run 流式暂未开放，请稍后再试。', 503, 'run_v2_disabled');
    if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 分析暂未开放，请稍后再试。', 503);
    if (!aiRunV2KindAllowed($db, $kind)) fail('该分析类型暂未开放流式，请稍后再试。', 503, 'run_v2_kind_disabled');
    if (!in_array($kind, AI_RUN_KINDS, true)) fail('当前分析类型不支持流式。', 400);

    $clientId = strtolower(trim((string)($body['client_job_id'] ?? '')));
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D', $clientId)) fail('任务编号不正确。', 400);
    $idempotencyKey = strtolower(trim((string)($idempotencyKey ?? '')));
    if ($idempotencyKey === '') fail('缺少幂等标识（Idempotency-Key）。', 400);
    if (!hash_equals($clientId, $idempotencyKey)) fail('幂等标识与任务编号不一致。', 409);

    $request = $body['request'] ?? null;
    if (!is_array($request) || ($request['kind'] ?? '') !== $kind) fail('请求格式不正确。', 400);
    $payload = $request['payload'] ?? null;
    if (!is_array($payload)) fail('请求格式不正确。', 400);
    // The same routing consent the polling path requires must be present.
    if (!isset($payload['_routing_version']) || !in_array((int)$payload['_routing_version'], [2, 3], true)) {
        fail('缺少云端分析授权版本。', 422);
    }
    if (isset($body['client_timezone']) && is_string($body['client_timezone']) && $body['client_timezone'] !== '') {
        try { $zone = new DateTimeZone($body['client_timezone']); $payload['timeZone'] = $zone->getName(); }
        catch (Exception) { fail('时区不正确。', 422); }
    }
    $request['payload'] = $payload;
    $requestHash = aiRunStableHash($request);
    $serverJobId = aiJobID($user, $clientId, $config);
    $traceId = aiRunTraceId();

    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        $existing = $db->prepare('SELECT * FROM ai_runs WHERE user_id=? AND client_message_id=? FOR UPDATE');
        $existing->execute([$uid, $clientId]);
        $row = $existing->fetch(PDO::FETCH_ASSOC) ?: null;
        if ($row) {
            if (!hash_equals((string)$row['request_hash'], $requestHash)) {
                $db->rollBack();
                fail('同一任务编号不能用于不同的分析。', 409);
            }
            $db->commit();
            return aiRunPublic($row, true);
        }
        require_once __DIR__.'/usage-guard131.php'; usageGuard131($db,$uid,$config);
        $job = $db->prepare('SELECT server_job_id,kind FROM ai_user_jobs WHERE user_id=? AND client_job_id=? FOR UPDATE');
        $job->execute([$uid, $clientId]);
        $existingJob = $job->fetch(PDO::FETCH_ASSOC) ?: null;
        if ($existingJob && $existingJob['kind'] !== $kind) { $db->rollBack(); fail('任务编号已经用于其他分析。', 409); }
        aiProviderConsentAssert($db,$uid,$payload);
        if (!aiMayPostJob($db, $user, $config, $kind, $existingJob)) { $db->rollBack(); fail('请先开通会员后使用此功能。', 403); }
        if ($existingJob === null) {
            // The durable job row must exist before any network call so deletion
            // and recovery can always find it (same rule as the polling path).
            $db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP())')
                ->execute([$uid, $clientId, $serverJobId, $kind]);
        }
        $activeLimit = max(1, min(5, (int)($config['ai_max_active_runs'] ?? 2)));
        $active = $db->prepare("SELECT COUNT(*) FROM ai_runs WHERE user_id=? AND status IN ('queued','running')");
        $active->execute([$uid]);
        if ((int)$active->fetchColumn() >= $activeLimit) {
            $db->rollBack();
            fail('当前有未完成的分析任务，请等待完成或取消后再提交。', 429);
        }

        $runId = actionUUID('ai-run/' . $uid . '/' . $clientId);
        // conversation_id has coach-only semantics; non-coach runs use an empty
        // value and keep client_message_id as the stable client identity.
        $db->prepare('INSERT INTO ai_runs(id,user_id,conversation_id,client_message_id,server_job_id,message_id,trace_id,status,last_seq,request_hash,request_json,attempts,created_at,updated_at)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,0,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
            ->execute([$runId, $uid, '', $clientId, $serverJobId, $clientId, $traceId, 'queued', 1, $requestHash,
                       json_encode($request, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $envelope = ['run_id' => $runId, 'seq' => 1, 'event_id' => actionUUID('ai-run-event/' . $runId . '/1'), 'type' => 'run.created',
                     'ts' => gmdate('c'), 'data' => ['status' => 'queued', 'message_id' => $clientId, 'trace_id' => $traceId, 'kind' => $kind]];
        $db->prepare('INSERT INTO ai_run_events(run_id,seq,event_id,type,data_json,created_at) VALUES(?,1,?,?,?,UTC_TIMESTAMP())')
            ->execute([$runId, $envelope['event_id'], 'run.created',
                       json_encode($envelope, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        if ($error instanceof RuntimeException && $error->getCode() >= 400 && $error->getCode() < 600) fail($error->getMessage(), $error->getCode());
        throw $error;
    }
    return [
        'run_id' => $runId, 'message_id' => $clientId, 'status' => 'queued',
        'stream_url' => '/me/ai/runs/' . $runId . '/events',
        'last_event_seq' => 1, 'trace_id' => $traceId, 'idempotent' => false, 'kind' => $kind,
    ];
}

/** GET /me/ai/runs/{id} — final snapshot for resync (never replays tool writes). */
function aiRunSnapshot(PDO $db, int $userId, string $runId): array {
    if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');
    $row = aiRunFetch($db, $userId, $runId);
    if (!$row) fail('对话任务不存在。', 404);
    $run = [
        'run_id' => (string)$row['id'], 'message_id' => (string)$row['message_id'],
        'status' => (string)$row['status'], 'last_event_seq' => (int)$row['last_seq'],
        'event_floor' => (int)($row['event_floor'] ?? 1),
        'trace_id' => (string)$row['trace_id'], 'created_at' => $row['created_at'],
        'updated_at' => $row['updated_at'], 'error_code' => $row['error_code'],
        'attempts' => (int)$row['attempts'], 'terminal' => aiRunTerminal((string)$row['status']),
    ];
    $message = null; $cards = [];
    $query = $db->prepare("SELECT id,content,payload_json,created_at FROM ai_messages WHERE user_id=? AND job_client_id=? AND role='assistant'");
    $query->execute([$userId, (string)$row['message_id']]);
    $assistant = $query->fetch(PDO::FETCH_ASSOC) ?: null;
    if ($assistant) {
        $message = ['id' => (int)$assistant['id'], 'role' => 'assistant', 'content' => $assistant['content'], 'created_at' => $assistant['created_at']];
        $decoded = json_decode((string)$assistant['payload_json'], true);
        if (is_array($decoded)) $message['coach'] = $decoded;
        $cardQuery = $db->prepare('SELECT payload_json FROM ai_message_cards WHERE message_id=? ORDER BY id');
        $cardQuery->execute([(int)$assistant['id']]);
        foreach ($cardQuery->fetchAll(PDO::FETCH_COLUMN) as $json) {
            $card = json_decode((string)$json, true);
            if (is_array($card)) $cards[] = $card;
        }
    }
    $result = json_decode((string)($row['result_json'] ?? ''), true);
    if ($message === null && is_array($result['coach'] ?? null)) {
        // Recovery for a completed run whose message row could not be read
        // (e.g. legacy data or a transient replica lag). The authoritative
        // result_json is written atomically with completion.
        $coach = $result['coach'];
        $message = ['id' => 0, 'role' => 'assistant', 'content' => (string)($coach['answer'] ?? ''),
                    'created_at' => $row['updated_at'], 'coach' => $coach, 'recovered' => true];
        if (is_array($coach['cards'] ?? null)) $cards = $coach['cards'];
    }
    return ['run' => $run, 'message' => $message, 'cards' => $cards,
            'result' => is_array($result) ? $result : null,
            'events_tail' => aiRunEvents($db, (string)$row['id'], max(0, (int)$row['last_seq'] - 20), 20)];
}

/** POST /me/ai/runs/{id}/cancel — stops uncommitted work only. */
function aiRunCancel(PDO $db, int $userId, string $runId): array {
    if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');
    $db->beginTransaction();
    try {
        lockActiveUser($db, $userId);
        $query = $db->prepare('SELECT * FROM ai_runs WHERE user_id=? AND id=? FOR UPDATE');
        $query->execute([$userId, strtolower($runId)]);
        $row = $query->fetch(PDO::FETCH_ASSOC);
        if (!$row) { $db->rollBack(); fail('对话任务不存在。', 404); }
        $status = (string)$row['status'];
        if ($status === 'cancelled') { $db->commit(); return ['run_id' => $row['id'], 'status' => 'cancelled', 'idempotent' => true]; }
        if (aiRunTerminal($status)) { $db->rollBack(); fail('任务已完成，不能取消；如需更正请创建新的提案。', 409); }
        $db->prepare("UPDATE ai_runs SET status='cancelled',lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$row['id']]);
        // Stop child actions for this message before they are resolved. Already
        // committed business facts are never rolled back.
        try {
            $db->prepare("UPDATE ai_action_messages SET status='cancelled',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND message_id=? AND status='accepted'")
                ->execute([$userId, (string)$row['message_id']]);
        } catch (Throwable $error) { error_log('BOJI cancel action message failed: ' . get_class($error)); }
        $seq = (int)$row['last_seq'] + 1;
        $envelope = ['run_id' => $row['id'], 'seq' => $seq, 'event_id' => actionUUID('ai-run-event/' . $row['id'] . '/' . $seq), 'type' => 'run.cancelled',
                     'ts' => gmdate('c'), 'data' => ['status' => 'cancelled']];
        $db->prepare('INSERT INTO ai_run_events(run_id,seq,event_id,type,data_json,created_at) VALUES(?,?,?,?,?,UTC_TIMESTAMP())')
            ->execute([$row['id'], $seq, $envelope['event_id'], 'run.cancelled',
                       json_encode($envelope, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $db->prepare('UPDATE ai_runs SET last_seq=? WHERE id=?')->execute([$seq, $row['id']]);
        $db->commit();
        return ['run_id' => $row['id'], 'status' => 'cancelled', 'last_event_seq' => $seq];
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

/** GET /me/ai/runs/{id}/events — SSE. Polls the durable log; safe to reconnect. */
function aiRunStream(PDO $db, int $userId, string $runId, int $afterSeq): never {
    if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');
    $row = aiRunFetch($db, $userId, $runId);
    if (!$row) fail('对话任务不存在。', 404);
    if ($afterSeq < (int)($row['event_floor'] ?? 1) - 1) {
        header('X-Boji-Resync: 1');
        fail('事件日志已过期，请重新同步。', 410);
    }
    $lease=businessUUID();
    $db->beginTransaction();
    try {
        lockActiveUser($db,$userId);
        $db->prepare('DELETE FROM ai_stream_leases WHERE user_id=? AND expires_at<UTC_TIMESTAMP()')->execute([$userId]);
        $q=$db->prepare('SELECT COUNT(*) FROM ai_stream_leases WHERE user_id=?');$q->execute([$userId]);
        if((int)$q->fetchColumn()>=2){$db->rollBack();header('Retry-After: 2');fail('打开的对话连接较多，请稍后重试。',429);}
        $db->prepare('INSERT INTO ai_stream_leases VALUES(?,?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 40 SECOND))')->execute([$lease,$userId]);$db->commit();
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
    register_shutdown_function(function()use($db,$lease){try{$db->prepare('DELETE FROM ai_stream_leases WHERE id=?')->execute([$lease]);}catch(Throwable){}});
    $runId = (string)$row['id'];
    $started = time();
    $lastHeartbeat = 0;
    @ini_set('zlib.output_compression', '0');
    @ini_set('implicit_flush', '1');
    set_time_limit(AI_RUN_SSE_MAX_SECONDS + 10);
    while (ob_get_level() > 0) @ob_end_clean();
    http_response_code(200);
    header('Content-Type: text/event-stream; charset=utf-8');
    header('Cache-Control: no-cache, no-transform, no-store');
    header('Connection: keep-alive');
    header('X-Accel-Buffering: no');
    header('Content-Encoding: identity');
    echo "retry: 3000\n\n";
    @flush();
    while (time() - $started < AI_RUN_SSE_MAX_SECONDS) {
        if (connection_aborted()) exit;
        $state = aiRunFetch($db, $userId, $runId);
        if (!$state) {
            // 终态帧必须与普通事件同形：客户端 AIRunEvent 要求
            // run_id/seq/event_id/type/ts/data 全部存在，否则整帧被丢弃并重连。
            $goneSeq = $afterSeq + 1;
            $gone = ['run_id' => $runId, 'seq' => $goneSeq,
                'event_id' => actionUUID('ai-run-event/' . $runId . '/' . $goneSeq),
                'type' => 'run.failed', 'ts' => gmdate('c'),
                'data' => ['code' => 'RUN_GONE', 'message' => '任务已删除，请重新提问。']];
            echo "id: " . $goneSeq . "\n";
            echo "event: run.failed\n";
            echo "data: " . json_encode($gone, JSON_UNESCAPED_UNICODE) . "\n\n";
            @flush();
            exit;
        }
        $events = aiRunEvents($db, $runId, $afterSeq, 120);
        foreach ($events as $event) {
            $afterSeq = (int)($event['seq'] ?? $afterSeq);
            echo 'id: ' . $afterSeq . "\n";
            echo 'event: ' . (string)($event['type'] ?? 'message') . "\n";
            echo 'data: ' . json_encode($event, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n\n";
        }
        if ($events) { @flush(); continue; }
        if (aiRunTerminal((string)$state['status'])) { exit; }
        if (time() - $lastHeartbeat >= 10) {
            echo ": heartbeat\n\n";
            @flush();
            $lastHeartbeat = time();
        }
        usleep(250000);
    }
    exit;
}

/** Read-only operational summary for the member-facing ops page. */
function aiRunOpsSummary(PDO $db, int $userId): array {
    $counts = [];
    $query = $db->prepare("SELECT status,COUNT(*) AS n FROM ai_runs WHERE user_id=? GROUP BY status");
    $query->execute([$userId]);
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) $counts[(string)$row['status']] = (int)$row['n'];
    $oldest = $db->prepare("SELECT MIN(created_at) FROM ai_runs WHERE user_id=? AND status='running'");
    $oldest->execute([$userId]);
    $usage = $db->prepare('SELECT COUNT(*) AS n, AVG(latency_ms) AS avg_ms, MAX(latency_ms) AS max_ms,
                                  SUM(COALESCE(prompt_tokens,0)) AS prompt_tokens,
                                  SUM(COALESCE(completion_tokens,0)) AS completion_tokens
                           FROM ai_usage_ledger WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(), INTERVAL 7 DAY)');
    $usage->execute([$userId]);
    $recent = $db->prepare('SELECT run_id,trace_id,status,attempts,created_at,updated_at,error_code FROM (
                                SELECT id AS run_id,trace_id,status,attempts,created_at,updated_at,error_code
                                FROM ai_runs WHERE user_id=? ORDER BY created_at DESC LIMIT 20) AS recent');
    $recent->execute([$userId]);
    $runs = [];
    foreach ($recent->fetchAll(PDO::FETCH_ASSOC) as $row) $runs[] = $row;
    return [
        'runs_by_status' => $counts,
        'oldest_running_at' => $oldest->fetchColumn() ?: null,
        'usage_7d' => $usage->fetch(PDO::FETCH_ASSOC) ?: [],
        'recent_runs' => $runs,
        'projection' => function_exists('aiRouterProjectionStatus') ? aiRouterProjectionStatus($db, $userId) : null,
    ];
}

/** Remove terminal image bytes in SQL, without loading large private photos into worker memory. */
function aiRunPruneImageInputs(PDO $db, int $batch = 100): int {
    $batch=max(1,min(500,$batch));
    return $db->exec("UPDATE ai_runs SET request_json=JSON_REMOVE(request_json,'$.payload.images[0].data_base64','$.payload.images[1].data_base64','$.payload.images[2].data_base64') WHERE status IN ('completed','failed','cancelled') AND updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY) AND JSON_CONTAINS_PATH(request_json,'one','$.payload.images[0].data_base64') LIMIT ".$batch);
}
