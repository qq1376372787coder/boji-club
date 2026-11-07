<?php
declare(strict_types=1);

/**
 * Durable AI Run worker (Phase 2 §3.1–3.3).
 *
 * Claims queued runs with an expiring lease, submits the same coach request the
 * polling path uses, waits for the Python worker, then appends ordered SSE
 * events and finishes the normal conversation/job records. Model I/O never
 * holds an account row lock.
 *
 * CLI only. Run from cron/systemd every 5–10 seconds.
 */

if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__ . '/cli-bootstrap.php';

require_once __DIR__ . '/public/app-config.php';
require_once __DIR__ . '/public/cloud-validation.php';
require_once __DIR__ . '/public/action-support.php';
require_once __DIR__ . '/public/ai-response.php';
require_once __DIR__ . '/public/ai-conversations.php';
require_once __DIR__ . '/public/ai-memory.php';
require_once __DIR__ . '/public/insights.php';
require_once __DIR__ . '/public/cloud-parts.php';
require_once __DIR__ . '/public/ai-entitlements.php';
require_once __DIR__ . '/public/capability-registry.php';
require_once __DIR__ . '/public/ai-runs.php';
require_once __DIR__.'/public/fast-intent.php';
require_once __DIR__ . '/public/action-jobs.php';
// The CLI worker must load the same domain executors as the HTTP adapter.
require_once __DIR__ . '/public/ai-router.php';

if (!defined('BOJI_AI_RUN_WORKER_LIBRARY')) {
 $config = require __DIR__ . '/config.php';
 $GLOBALS['config'] = $config;
 $db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
 ]);
}

function aiRunWorkerLog(array $value): void {
    echo json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";
}

function aiRunWorkerClaim(PDO $db, int $limit): array {
    // One lease per process: a batch of 3 could exceed the systemd timeout
    // before later rows start. Callers may still raise this explicitly.
    $limit = max(1, min(3, $limit));
    $owner = substr(gethostname() ?: 'worker', 0, 40) . ':' . getmypid();
    $db->beginTransaction();
    try {
        $query = $db->query(
            "SELECT * FROM ai_runs
             WHERE status='queued'
                OR (status='running' AND (lease_expires_at IS NULL OR lease_expires_at < UTC_TIMESTAMP()))
             ORDER BY created_at ASC LIMIT " . $limit . ' FOR UPDATE SKIP LOCKED');
        $rows = $query->fetchAll(PDO::FETCH_ASSOC);
        if ($rows) {
            $claim = $db->prepare("UPDATE ai_runs SET status='running',lease_owner=?,
                lease_expires_at=DATE_ADD(UTC_TIMESTAMP(), INTERVAL " . AI_RUN_LEASE_SECONDS . " SECOND),
                attempts=attempts+1,updated_at=UTC_TIMESTAMP() WHERE id=?");
            foreach ($rows as $row) $claim->execute([$owner, $row['id']]);
        }
        $db->commit();
        foreach ($rows as &$row) {
            $row['status'] = 'running';
            $row['lease_owner'] = $owner;
            $row['lease_expires_at'] = gmdate('Y-m-d H:i:s', time() + AI_RUN_LEASE_SECONDS);
            $row['attempts'] = (int)$row['attempts'] + 1;
        }
        unset($row);
        return $rows;
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

function aiRunWorkerHeartbeat(PDO $db, string $runId, string $owner): void {
    $statement = $db->prepare("UPDATE ai_runs SET lease_expires_at=DATE_ADD(UTC_TIMESTAMP(), INTERVAL " . AI_RUN_LEASE_SECONDS . " SECOND),updated_at=UTC_TIMESTAMP()
        WHERE id=? AND status='running' AND lease_owner=? AND lease_expires_at>=UTC_TIMESTAMP()");
    $statement->execute([$runId, $owner]);
    // MySQL reports changed rows, so a heartbeat within the same second can
    // legitimately report zero. Verify ownership instead of failing the run.
    if ($statement->rowCount() !== 1) {
        $check=$db->prepare("SELECT 1 FROM ai_runs WHERE id=? AND status='running' AND lease_owner=? AND lease_expires_at>=UTC_TIMESTAMP()");
        $check->execute([$runId,$owner]);
        if (!$check->fetchColumn()) throw new RuntimeException('lease_lost',409);
    }
}

/** Server-authoritative context. Client-supplied memory/capabilities are discarded. */
function aiRunWorkerRequest(PDO $db, array $row, array $config): array {
    $request = json_decode((string)$row['request_json'], true);
    $kind = (string)($request['kind'] ?? '');
    $supported = array_merge(['coach'], AI_RUN_KINDS);
    if (!is_array($request) || !in_array($kind, $supported, true) || !is_array($request['payload'] ?? null)) {
        throw new RuntimeException('invalid_run_request');
    }
    $uid = (int)$row['user_id'];
    $payload = $request['payload'];
    aiProviderConsentAssert($db,$uid,$payload);
    unset($payload['memory'], $payload['capabilities'], $payload['action_preferences'], $payload['_onboarding_context']);
    if ($kind !== 'coach') {
        // Non-coach kinds carry no conversation context. The polling path sends
        // this payload unchanged, so the Run path must stay identical for both
        // paths to reach the same Python job with the same prompt.
        $payload['_fast_intent_enabled'] = appFeatureEnabled($db,'ai_fast_intent_v1');
        $payload['_router_v3'] = appFeatureEnabled($db,'ai_router_v3');
        $payload['_context_status'] = ['memory' => 'not_applicable', 'history' => 'not_applicable',
                                       'capabilities' => 'not_applicable', 'purpose' => 'not_applicable'];
        $request['payload'] = $payload;
        $request['id'] = (string)$row['server_job_id'];
        $request['_quota_owner'] = aiQuotaOwner($uid, $config);
        $request['_trace_id'] = (string)$row['trace_id'];
        return $request;
    }
    $purpose = (string)($payload['purpose'] ?? 'dialogue');
    $context = ['memory' => 'not_requested', 'history' => 'not_requested', 'capabilities' => 'not_requested', 'purpose' => $purpose];
    if ($purpose === 'onboarding_assist') {
        $sessionId = strtolower((string)($payload['_onboarding_session_id'] ?? ''));
        $session = function_exists('onboardingSessionRead') ? onboardingSessionRead($db, $uid, $sessionId) : null;
        if (!$session || (string)$session['status'] === 'completed') throw new RuntimeException('onboarding_session_invalid');
        $question = trim((string)($payload['question'] ?? ''));
        $payload['_onboarding_context'] = onboardingAssistContext($db, $uid, $session, $question);
        $payload['history'] = onboardingAssistHistory($db, $uid, $sessionId, 10);
        $payload['days'] = [];
        $payload['upcoming'] = [];
        $payload['context_days'] = 0;
        $payload['memory'] = [];
        $payload['capabilities'] = onboardingCapabilityWhitelist();
        $payload['action_preferences'] = ['weight_unit' => 'kg'];
        $context = ['memory' => 'skipped_onboarding', 'history' => $payload['history'] ? 'injected' : 'empty',
                    'capabilities' => 'restricted_onboarding', 'purpose' => $purpose];
    } elseif ($purpose === 'context_continue') {
        $snapshot = $payload['_context_source'] ?? null;
        if (!is_array($snapshot) || !is_string($snapshot['type'] ?? null) || !is_string($snapshot['job_id'] ?? null)) {
            throw new RuntimeException('context_source_invalid');
        }
        $refreshed = contextSourceResolve($db, $uid, ['type' => $snapshot['type'], 'id' => $snapshot['job_id'], 'version' => $snapshot['version'] ?? null]);
        $payload['_context_source'] = contextSourcePrompt($refreshed);
        $payload['memory'] = [];
        $payload['days'] = [];
        $payload['upcoming'] = [];
        $payload['context_days'] = 0;
        try {
            $payload['capabilities'] = appFeatureEnabled($db, 'action_system_enabled') ? capabilityWhitelistForChatImages($payload) : [];
            $context['capabilities'] = 'injected';
        } catch (Throwable $error) { $context['capabilities'] = 'unavailable'; }
        if (aiConversationIdValid($payload['conversation_id'] ?? null)) {
            try {
                $history = aiCoachHistory($db, $uid, (string)$payload['conversation_id']);
                if ($history) $payload['history'] = $history;
                $context['history'] = $history ? 'injected' : 'empty';
            } catch (Throwable $error) { $context['history'] = 'unavailable'; }
        }
        $context['memory'] = 'skipped_context_continue';
    } else {
        try {
            $memory = aiMemoryForContext($db, $uid);
            if ($memory) $payload['memory'] = $memory;
            $context['memory'] = $memory ? 'injected' : 'empty';
        } catch (Throwable $error) {
            $context['memory'] = 'unavailable';
            error_log('BOJI run memory inject failed: ' . get_class($error) . ': ' . $error->getMessage());
        }
        try {
            $payload['capabilities'] = appFeatureEnabled($db, 'action_system_enabled') ? capabilityWhitelistForChatImages($payload) : [];
            $preferences = actionPreferences($db, $uid);
            $payload['action_preferences'] = ['weight_unit' => $preferences['weight_unit']];
            $context['capabilities'] = 'injected';
        } catch (Throwable $error) {
            $context['capabilities'] = 'unavailable';
            error_log('BOJI run capability inject failed: ' . get_class($error));
        }
        if (aiConversationIdValid($payload['conversation_id'] ?? null)) {
            try {
                $history = aiCoachHistory($db, $uid, (string)$payload['conversation_id']);
                if ($history) $payload['history'] = $history;
                $context['history'] = $history ? 'injected' : 'empty';
            } catch (Throwable $error) {
                $context['history'] = 'unavailable';
                error_log('BOJI run history inject failed: ' . get_class($error));
            }
        }
    }
    if(isset($payload['context_bundle_id'])){
        $bundle=aiContextLoad($db,$uid,(string)$payload['context_bundle_id'],(string)$payload['conversation_id'],$config);
        $payload['_references']=$bundle['references'];$payload['days']=[];$payload['upcoming']=[];$payload['memory']=[];
        $payload['_analysis_read_only131']=localContextIsReadOnly131($bundle['references']);
        // Referenced notes are untrusted; mutations use explicit native proposal flows.
        $payload['capabilities']=array_values(array_filter($payload['capabilities']??[],fn($x)=>in_array(capabilityRegistryEntry($x['capability'])['mode']??'',(!empty($payload['_analysis_read_only131'])?['read_only','advisory']:['read_only','advisory','preview','async']),true)));
    }
    // Observable degradation without leaking content; admin/log readers only see
    // the status. A model may ignore this key.
    $payload['_context_status'] = $context;
    $payload['_fast_intent_enabled']=appFeatureEnabled($db,'ai_fast_intent_v1');
    $payload['_router_v3']=appFeatureEnabled($db,'ai_router_v3');
    $request['payload'] = $payload;
    $request['id'] = (string)$row['server_job_id'];
    $request['_quota_owner'] = aiQuotaOwner($uid, $config);
    $request['_trace_id'] = (string)$row['trace_id'];
    return $request;
}

function aiRunWorkerText(array $coach): string {
    $answer = $coach['answer'] ?? '';
    return is_string($answer) ? $answer : '';
}

function aiRunWorkerUsage(array $response, int $latencyMs): array {
    $result = is_array($response['result'] ?? null) ? $response['result'] : [];
    return [
        'provider' => (string)($response['provider'] ?? ''),
        'model' => (string)($response['model'] ?? ''),
        'latency_ms' => $latencyMs,
        'prompt_tokens' => $response['usage']['prompt_tokens'] ?? $result['usage']['prompt_tokens'] ?? null,
        'completion_tokens' => $response['usage']['completion_tokens'] ?? $result['usage']['completion_tokens'] ?? null,
        'attempt_count' => $response['usage']['attempt_count'] ?? null,
    ];
}

/**
 * Non-coach completion: no conversation turn and no action resolution.
 * Marks the shared ai_user_jobs row, publishes the terminal snapshot, writes the
 * usage ledger and closes the run — all inside one transaction.
 */
function aiRunWorkerCompleteKind(PDO $db, array $row, array $config, array $response, int $latencyMs, array $result): void {
    $uid = (int)$row['user_id'];
    $runId = (string)$row['id'];
    $owner = (string)($row['lease_owner'] ?? '');
    $kind = (string)($result['kind'] ?? '');
    $usage = aiRunWorkerUsage($response, $latencyMs);

    $preflight = $db->prepare('SELECT status FROM ai_runs WHERE id=?');
    $preflight->execute([$runId]);
    $statusNow = (string)$preflight->fetchColumn();
    if ($statusNow === 'cancelled') {
        aiRunWorkerLog(['run' => $runId, 'status' => 'cancelled_before_complete', 'persisted' => false]);
        return;
    }
    if ($statusNow === 'completed') {
        aiRunWorkerLog(['run' => $runId, 'status' => 'already_completed', 'persisted' => true]);
        return;
    }

    aiRunWorkerHeartbeat($db, $runId, $owner);
    $liveRequest = json_decode((string)$row['request_json'], true);
    aiProviderConsentAssert($db, $uid, $liveRequest['payload'] ?? []);

    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        $lock = $db->prepare('SELECT * FROM ai_runs WHERE id=? FOR UPDATE');
        $lock->execute([$runId]);
        $locked = $lock->fetch(PDO::FETCH_ASSOC);
        if (!$locked) throw new RuntimeException('run_missing');
        $lockedStatus = (string)$locked['status'];
        if ($lockedStatus === 'completed') { $db->commit(); return; }
        if ($lockedStatus === 'cancelled') { $db->rollBack(); aiRunWorkerLog(['run' => $runId, 'status' => 'cancelled_at_commit']); return; }
        if ($lockedStatus !== 'running') throw new RuntimeException('run_not_running', 409);
        if ($owner === '' || !hash_equals((string)($locked['lease_owner'] ?? ''), $owner)) throw new RuntimeException('lease_lost', 409);
        if ($locked['lease_expires_at'] !== null && strtotime((string)$locked['lease_expires_at'] . ' UTC') < time()) throw new RuntimeException('lease_expired', 409);

        $requestStored = json_decode((string)$locked['request_json'], true);
        aiProviderConsentAssert($db, $uid, $requestStored['payload'] ?? []);
        aiMarkCompleted($db, $uid, (string)$row['server_job_id'], $response);

        aiRunAppend($db, $runId, 'result.snapshot', ['kind' => $kind, 'result' => $result], $owner);
        aiRunAppend($db, $runId, 'usage.summary', $usage, $owner);

        $ledger = $db->prepare('SELECT 1 FROM ai_usage_ledger WHERE user_id=? AND server_job_id=? AND kind=? LIMIT 1');
        $ledger->execute([$uid, (string)$row['server_job_id'], $kind]);
        if (!$ledger->fetchColumn()) {
            $db->prepare('INSERT INTO ai_usage_ledger(user_id,server_job_id,kind,status,latency_ms,prompt_tokens,completion_tokens,provider,trace_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())')
                ->execute([$uid, (string)$row['server_job_id'], $kind, 'succeeded', $latencyMs,
                           $usage['prompt_tokens'], $usage['completion_tokens'], $usage['provider'], (string)$row['trace_id']]);
        }

        aiRunAppend($db, $runId, 'run.completed', ['final_message_id' => (string)$row['message_id'], 'status' => 'completed'], $owner);
        $db->prepare("UPDATE ai_runs SET status='completed',error_code=NULL,result_json=?,lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?")
            ->execute([json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $runId]);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
    aiRunWorkerLog(['run' => $runId, 'status' => 'completed', 'kind' => $kind, 'latency_ms' => $latencyMs]);
}

/** Finish one succeeded run atomically. */
function aiRunWorkerComplete(PDO $db, array $row, array $config, array $response, int $latencyMs): void {
    $uid = (int)$row['user_id'];
    $runId = (string)$row['id'];
    $messageId = (string)$row['message_id'];
    $owner = (string)($row['lease_owner'] ?? '');
    $result = is_array($response['result'] ?? null) ? $response['result'] : [];
    if (in_array((string)($result['kind'] ?? ''), AI_RUN_KINDS, true)) {
        aiRunWorkerCompleteKind($db, $row, $config, $response, $latencyMs, $result);
        return;
    }
    if (($result['kind'] ?? '') !== 'coach' || !is_array($result['coach'] ?? null)) {
        throw new RuntimeException('invalid_coach_result');
    }
    $coach = $result['coach'];
    $answer = aiRunWorkerText($coach);
    if ($answer === '') throw new RuntimeException('empty_coach_answer');
    $cards = is_array($coach['cards'] ?? null) ? $coach['cards'] : [];
    $usage = aiRunWorkerUsage($response, $latencyMs);

    $preflight = $db->prepare('SELECT status FROM ai_runs WHERE id=?');
    $preflight->execute([$runId]);
    $statusNow = (string)$preflight->fetchColumn();
    if ($statusNow === 'cancelled') {
        aiRunWorkerLog(['run' => $runId, 'status' => 'cancelled_before_complete', 'persisted' => false]);
        return;
    }
    if ($statusNow === 'completed') {
        aiRunWorkerLog(['run' => $runId, 'status' => 'already_completed', 'persisted' => true]);
        return;
    }

    // Domain commands use their own transactions and stable message/call IDs.
    // Resolve BEFORE publishing a terminal SSE event. A crash after a command
    // commit replays that ID, never a second business operation.
    aiRunWorkerHeartbeat($db, $runId, $owner);
    $liveRequest=json_decode((string)$row['request_json'],true);
    aiProviderConsentAssert($db,$uid,$liveRequest['payload']??[]);
    if(isset($liveRequest['payload']['context_bundle_id']))aiContextLoad($db,$uid,(string)$liveRequest['payload']['context_bundle_id'],(string)$liveRequest['payload']['conversation_id'],$config);
    aiRunAppend($db, $runId, 'run.status', ['status' => 'resolving_actions'], $owner);
    $actions = actionWithParent($uid, $messageId,
        fn() => actionResolveCompletedMessage($db, ['id'=>$uid], $messageId, $response), $owner);
    if (array_filter($actions['results'], fn($r) => in_array($r['status'] ?? '', ['failed_retryable','verifying_result'], true))) {
        throw new RuntimeException('ACTIONS_PENDING');
    }
    $coach['action_results'] = $actions['results'];
    $response['result']['coach'] = $coach;
    aiRunAppend($db, $runId, 'run.status', ['status' => 'composing'], $owner);

    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid); // Same account -> run lock order as cancel/commands.
        $lock = $db->prepare('SELECT * FROM ai_runs WHERE id=? FOR UPDATE');
        $lock->execute([$runId]);
        $locked = $lock->fetch(PDO::FETCH_ASSOC);
        if (!$locked) throw new RuntimeException('run_missing');
        $lockedStatus = (string)$locked['status'];
        if ($lockedStatus === 'completed') { $db->commit(); return; }
        if ($lockedStatus === 'cancelled') { $db->rollBack(); aiRunWorkerLog(['run' => $runId, 'status' => 'cancelled_at_commit']); return; }
        if ($lockedStatus !== 'running') throw new RuntimeException('run_not_running', 409);
        if ($owner === '' || !hash_equals((string)($locked['lease_owner'] ?? ''), $owner)) throw new RuntimeException('lease_lost', 409);
        if ($locked['lease_expires_at'] !== null && strtotime((string)$locked['lease_expires_at'] . ' UTC') < time()) throw new RuntimeException('lease_expired', 409);

        // Necessary persistence: a failure here aborts completion and the caller
        // marks the run failed. It is never swallowed.
        $requestStored = json_decode((string)$locked['request_json'], true);
        aiProviderConsentAssert($db,$uid,$requestStored['payload']??[]);
        if(isset($requestStored['payload']['context_bundle_id'])) aiContextLoad($db,$uid,(string)$requestStored['payload']['context_bundle_id'],(string)$requestStored['payload']['conversation_id'],$config);
        $purpose = (string)($requestStored['payload']['purpose'] ?? 'dialogue');
        if ($purpose === 'onboarding_assist') {
            $sessionId = (string)($requestStored['payload']['_onboarding_session_id'] ?? '');
            $question = (string)($requestStored['payload']['question'] ?? '');
            $candidates = is_array($coach['onboarding']['candidates'] ?? null) ? $coach['onboarding']['candidates'] : [];
            // Candidates are already schema/evidence validated by the Python
            // worker; this second pass binds them to the live session and never
            // turns them into confirmed facts. If the member edited the session
            // while the model was running, later edits win: do not apply stale
            // candidates.
            $contextRevision = (int)($requestStored['payload']['_onboarding_context']['session_revision'] ?? -1);
            $liveSession = $sessionId !== '' ? onboardingSessionRead($db, $uid, $sessionId) : null;
            if ($liveSession && (int)$liveSession['revision'] === $contextRevision) {
                $applied = onboardingApplyModelCandidates($db, $uid, $sessionId, $candidates, $question, $runId);
                $coach['onboarding_applied'] = $applied['applied'];
            } else {
                $coach['onboarding_applied'] = 0;
                $coach['onboarding_stale'] = true;
            }
            onboardingAssistRecordTurn($db, $uid, $sessionId, 'assistant', $answer);
        } else {
            aiCoachTurnCompleteTx($db, $uid, $messageId, $coach, true);
        }
        aiMarkCompleted($db, $uid, (string)$row['server_job_id'], $response);

        aiRunAppend($db, $runId, 'assistant.text.snapshot', ['message_id' => $messageId, 'text' => $answer], $owner);
        foreach ($cards as $card) {
            if (!is_array($card)) continue;
            $cardId = (string)($card['card_id'] ?? '');
            if ($cardId === '') continue;
            aiRunAppend($db, $runId, 'card.upsert', [
                'card_id' => $cardId,
                'card_type' => (string)($card['card_type'] ?? 'unknown'),
                'schema_version' => (int)($card['schema_version'] ?? 0),
                'status' => (string)($card['status'] ?? 'ready'),
                'card' => $card,
            ], $owner);
            if (!empty($card['proposal_id'])) {
                aiRunAppend($db, $runId, 'action.proposed', [
                    'proposal_id' => (string)$card['proposal_id'], 'card_id' => $cardId,
                    'status' => (string)($card['status'] ?? 'needs_confirmation'),
                ], $owner);
            }
        }
        aiRunAppend($db, $runId, 'usage.summary', $usage, $owner);

        $ledger = $db->prepare("SELECT 1 FROM ai_usage_ledger WHERE user_id=? AND server_job_id=? AND kind='coach' LIMIT 1");
        $ledger->execute([$uid, (string)$row['server_job_id']]);
        if (!$ledger->fetchColumn()) {
            $db->prepare('INSERT INTO ai_usage_ledger(user_id,server_job_id,kind,status,latency_ms,prompt_tokens,completion_tokens,provider,trace_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())')
                ->execute([$uid, (string)$row['server_job_id'], 'coach', 'succeeded', $latencyMs, $usage['prompt_tokens'], $usage['completion_tokens'], $usage['provider'], (string)$row['trace_id']]);
        }

        aiRunAppend($db, $runId, 'run.completed', ['final_message_id' => $messageId, 'status' => 'completed'], $owner);
        $resultJson = [
            'answer' => $answer, 'coach' => $coach, 'card_count' => count($cards),
            'provider' => $usage['provider'], 'model' => $usage['model'],
            'latency_ms' => $latencyMs, 'trace_id' => (string)$row['trace_id'],
        ];
        $db->prepare("UPDATE ai_runs SET status='completed',error_code=NULL,result_json=?,lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?")
            ->execute([json_encode($resultJson, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $runId]);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
    aiRunWorkerLog(['run' => $runId, 'status' => 'completed', 'cards' => count($cards), 'latency_ms' => $latencyMs]);
}

/** Fail a run once, with the same lease fencing as completion. */
function aiRunWorkerFail(PDO $db, array $row, string $code, string $publicMessage): void {
    $runId = (string)$row['id'];
    $owner = (string)($row['lease_owner'] ?? '');
    $db->beginTransaction();
    try {
        $lock = $db->prepare('SELECT status,lease_owner FROM ai_runs WHERE id=? FOR UPDATE');
        $lock->execute([$runId]);
        $locked = $lock->fetch(PDO::FETCH_ASSOC);
        if (!$locked) { $db->rollBack(); return; }
        $status = (string)$locked['status'];
        if (in_array($status, ['cancelled', 'completed', 'failed'], true)) { $db->commit(); return; }
        if ($owner !== '' && !hash_equals((string)($locked['lease_owner'] ?? ''), $owner)) { $db->rollBack(); return; }
        aiRunAppend($db, $runId, 'run.failed', ['code' => $code, 'message' => $publicMessage, 'retryable' => false], $owner !== '' ? $owner : null);
        $db->prepare("UPDATE ai_runs SET status='failed',error_code=?,result_json=?,lease_owner=NULL,lease_expires_at=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?")
            ->execute([$code, json_encode(['error' => $publicMessage, 'trace_id' => (string)$row['trace_id']], JSON_UNESCAPED_UNICODE), $runId]);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
    aiRunWorkerLog(['run' => $runId, 'status' => 'failed', 'code' => $code]);
}

/** Bridge real provider events; the persisted source cursor fences worker replay. */
function aiRunWorkerStream(PDO $db, array $row, array $config, int &$after): void {
    try { $batch = actionPrivateRequest($config, 'GET', '/v1/jobs/' . $row['server_job_id'] . '/events?wait_ms=700&after_seq=' . $after, null, 1.5); }
    catch (Throwable) { return; } // Older private workers may only support final results.
    foreach ($batch['events'] ?? [] as $event) {
        $seq = (int)($event['seq'] ?? 0);
        if ($seq <= $after) continue;
        if ($seq !== $after + 1 || !in_array($event['type'] ?? '', ['delta','reset'], true)) throw new RuntimeException('invalid_stream_sequence');
        $data = ['message_id' => $row['message_id'], 'source_seq' => $seq];
        if ($event['type'] === 'reset') $data['text'] = '';
        else {
            $text = $event['text'] ?? null;
            if (!is_string($text) || mb_strlen($text) > 5000) throw new RuntimeException('invalid_stream_delta');
            $data['delta'] = $text;
            $data['provisional'] = true;
        }
        aiRunAppend($db, $row['id'], $event['type'] === 'delta' ? 'assistant.text.delta' : 'assistant.text.snapshot', $data, $row['lease_owner']);
        $after = $seq;
    }
}

function aiRunWorkerProcess(PDO $db, array $row, array $config): void {
    appConfigFeatureSnapshot($db, true);
    $runId = (string)$row['id'];
    $owner = (string)($row['lease_owner'] ?? '');
    // The tool label is user-visible in the event log; keep coach runs on the
    // historical name and give non-coach kinds an accurate one.
    $runKind = (string)(json_decode((string)$row['request_json'], true)['kind'] ?? 'coach');
    $toolName = $runKind === 'coach' ? 'coach.model' : 'ai.model';
    if ((int)$row['attempts'] > AI_RUN_MAX_ATTEMPTS) {
        aiRunWorkerFail($db, $row, 'RUN_ATTEMPTS_EXHAUSTED', '这次分析未能完成，输入仍在本机，可稍后重试。');
        return;
    }
    try {
        aiRunAppend($db, $runId, 'run.status', ['status' => 'running', 'attempt' => (int)$row['attempts'], 'queue_ms'=>max(0,(int)((microtime(true)-strtotime($row['created_at'].' UTC'))*1000))], $owner);
        aiRunAppend($db, $runId, 'tool.started', ['tool' => $toolName, 'tool_call_id' => 'tc_' . $runId], $owner);
    } catch (Throwable $error) {
        aiRunWorkerLog(['run' => $runId, 'status' => 'fenced_out', 'reason' => $error->getMessage()]);
        return;
    }
    // On recovery the private job owns its original validated request. Rebuild
    // context only after a real 404, never after an ambiguous network failure.
    $alreadySubmitted=false;
    if((int)$row['attempts']>1){
        try{actionPrivateRequest($config,'GET','/v1/jobs/'.$row['server_job_id']);$alreadySubmitted=true;}
        catch(Throwable $error){
            if($error->getCode()!==404){
                if((int)$row['attempts']>=AI_RUN_MAX_ATTEMPTS)aiRunWorkerFail($db,$row,'RECOVERY_UNAVAILABLE','原任务暂未确认，请查询原消息的行动回执；已提交的操作会保留。');
                else{
                    aiRunAppend($db,$runId,'run.status',['status'=>'retrying','reason'=>'recovery_unavailable'],$owner);
                    $db->prepare("UPDATE ai_runs SET lease_expires_at=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 5 SECOND) WHERE id=? AND status='running' AND lease_owner=?")->execute([$runId,$owner]);
                }
                return;
            }
        }
    }
    if(!$alreadySubmitted)try {
        $contextStarted=microtime(true);
        $request = aiRunWorkerRequest($db, $row, $config);
        aiRunAppend($db,$runId,'context.resolved',['duration_ms'=>(int)((microtime(true)-$contextStarted)*1000),'references'=>count($request['payload']['_references']??[])],$owner);
    } catch (Throwable $error) {
        try { aiRunAppend($db, $runId, 'tool.failed', ['tool' => $toolName, 'tool_call_id' => 'tc_' . $runId, 'status' => 'failed'], $owner); } catch (Throwable) {}
        aiRunWorkerFail($db, $row, 'INVALID_RUN_REQUEST', $error instanceof RuntimeException && in_array($error->getCode(),[403,409,410],true) ? $error->getMessage() : '这次请求无法恢复，请重新提问。');
        return;
    }

    $started = microtime(true);
    try {
        if(!$alreadySubmitted)actionPrivateRequest($config, 'POST', '/v1/jobs', $request);
    } catch (Throwable $error) {
        try { aiRunAppend($db, $runId, 'tool.failed', ['tool' => $toolName, 'tool_call_id' => 'tc_' . $runId, 'status' => 'failed'], $owner); } catch (Throwable) {}
        if (in_array($error->getCode(), [400,401,403,404,409,410,413,422], true)) {
            aiRunWorkerFail($db,$row,'UPSTREAM_REQUEST_REJECTED','分析请求未通过校验，请刷新引用或资料后重试；原消息中已存在的行动回执会保留。');
            aiRunWorkerLog(['run'=>$runId,'status'=>'request_rejected','upstream_status'=>$error->getCode()]);
            return;
        }
        $db->prepare("UPDATE ai_runs SET lease_expires_at=UTC_TIMESTAMP(),updated_at=UTC_TIMESTAMP() WHERE id=? AND status='running' AND lease_owner=?")->execute([$runId, $owner]);
        if ((int)$row['attempts'] >= AI_RUN_MAX_ATTEMPTS) {
            aiRunWorkerFail($db, $row, 'MODEL_UNAVAILABLE', '分析服务暂不可用，输入已保留，请稍后重试。');
        } else {
            try { aiRunAppend($db, $runId, 'run.status', ['status' => 'retrying', 'reason' => 'model_unavailable'], $owner); } catch (Throwable) {}
        }
        return;
    }
    $cursor = $db->prepare("SELECT COALESCE(MAX(CAST(JSON_UNQUOTE(JSON_EXTRACT(data_json,'$.data.source_seq')) AS UNSIGNED)),0) FROM ai_run_events WHERE run_id=?");
    $cursor->execute([$runId]);
    $streamAfter = (int)$cursor->fetchColumn();
    $deadline = time() + 100;
    $lastStatus = '';
    $lastBeat = time();
    while (time() < $deadline) {
        try { aiRunWorkerStream($db, $row, $config, $streamAfter); }
        catch (Throwable) { return; } // Cancellation/lease loss fences public events too.
        try {
            $response = actionPrivateRequest($config, 'GET', '/v1/jobs/' . $row['server_job_id']);
        } catch (Throwable $error) {
            usleep(1000000);
            continue;
        }
        $serverStatus = (string)($response['status'] ?? 'running');
        if ($serverStatus !== $lastStatus) {
            $lastStatus = $serverStatus;
            if (in_array($serverStatus, ['queued', 'running', 'retrying'], true)) {
                try { aiRunAppend($db, $runId, 'run.status', ['status' => $serverStatus], $owner); } catch (Throwable $error) {
                    aiRunWorkerLog(['run' => $runId, 'status' => 'fenced_out', 'reason' => $error->getMessage()]);
                    return;
                }
            }
        }
        if ($serverStatus === 'succeeded') {
            try {
                aiRunAppend($db, $runId, 'tool.completed', ['tool' => $toolName, 'tool_call_id' => 'tc_' . $runId, 'status' => 'succeeded'], $owner);
            } catch (Throwable $error) {
                aiRunWorkerLog(['run' => $runId, 'status' => 'fenced_out', 'reason' => $error->getMessage()]);
                return;
            }
            $latencyMs = (int)round((microtime(true) - $started) * 1000);
            try {
                aiRunWorkerComplete($db, $row, $config, $response, $latencyMs);
            } catch (Throwable $error) {
                $fenced = in_array($error->getMessage(), ['run_terminal','lease_lost','lease_expired'], true);
                if (!$fenced && (int)$row['attempts'] < AI_RUN_MAX_ATTEMPTS) {
                    aiRunAppend($db, $runId, 'run.status', ['status'=>'retrying','reason'=>'result_or_actions_pending'], $owner);
                    $db->prepare("UPDATE ai_runs SET lease_expires_at=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 5 SECOND),updated_at=UTC_TIMESTAMP() WHERE id=? AND status='running' AND lease_owner=?")->execute([$runId,$owner]);
                    return;
                }
                $code = $fenced ? 'FENCED_OUT' : 'RESULT_PERSIST_FAILED';
                aiRunWorkerFail($db, $row, $code, $fenced ? '任务状态已变化。' : '本次回复或部分行动未能确认；已执行的操作会保留，请查询原消息的行动回执后再决定是否重试。');
            }
            return;
        }
        if (in_array($serverStatus, ['failed', 'rejected', 'cancelled', 'expired'], true)) {
            try { aiRunAppend($db, $runId, 'tool.failed', ['tool' => $toolName, 'tool_call_id' => 'tc_' . $runId, 'status' => 'failed'], $owner); } catch (Throwable) {}
            $code = is_string($response['error_code'] ?? null) && $response['error_code'] !== '' ? $response['error_code'] : 'MODEL_FAILED';
            aiRunWorkerFail($db, $row, $code, '这次分析未能完成，输入已保留；可重新提问。');
            return;
        }
        if (time() - $lastBeat >= 20) {
            try { aiRunWorkerHeartbeat($db, $runId, $owner); $lastBeat = time(); }
            catch (Throwable $error) { aiRunWorkerLog(['run' => $runId, 'status' => 'lease_lost']); return; }
        }
        usleep(100000);
    }
    $db->prepare("UPDATE ai_runs SET lease_expires_at=UTC_TIMESTAMP(),updated_at=UTC_TIMESTAMP() WHERE id=? AND status='running' AND lease_owner=?")->execute([$runId, $owner]);
    if ((int)$row['attempts'] >= AI_RUN_MAX_ATTEMPTS) {
        aiRunWorkerFail($db, $row, 'UPSTREAM_TIMEOUT', '分析耗时过长，输入已保留，请稍后重试。');
    } else {
        try { aiRunAppend($db, $runId, 'run.status', ['status' => 'retrying', 'reason' => 'upstream_slow'], $owner); } catch (Throwable) {}
    }
}

if (defined('BOJI_AI_RUN_WORKER_LIBRARY')) return;
$daemon=in_array('--daemon',$argv,true);
$stop=false;
if(function_exists('pcntl_async_signals')){pcntl_async_signals(true);pcntl_signal(SIGTERM,function()use(&$stop){$stop=true;});pcntl_signal(SIGINT,function()use(&$stop){$stop=true;});}
do {
    try {
        $runs=aiRunWorkerClaim($db,1);
        foreach($runs as $row){
            try{aiRunWorkerProcess($db,$row,$config);}
            catch(Throwable $error){aiRunWorkerLog(['run'=>$row['id'],'status'=>'worker_error','error'=>get_class($error)]);}
        }
        if(!$runs&&$daemon)usleep(100000);
    }catch(Throwable $error){aiRunWorkerLog(['status'=>'claim_error','error'=>get_class($error)]);if($daemon)sleep(1);else exit(1);}
}while($daemon&&!$stop);
