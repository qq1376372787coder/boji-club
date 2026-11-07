<?php
require_once __DIR__ . '/chat-input.php';
require_once __DIR__ . '/ai-response.php';
require_once __DIR__ . '/ai-conversations.php';
require_once __DIR__ . '/insights.php';
require_once __DIR__ . '/ai-proposals.php';
require_once __DIR__ . '/ai-memory.php';
require_once __DIR__ . '/capability-registry.php';
require_once __DIR__.'/ai-entitlements.php';
require_once __DIR__.'/onboarding-v2.php';
require_once __DIR__.'/context-continuation.php';
// Included after account authentication setup. Never expose the AI owner token to clients.
if (preg_match('#^/me/weekly/jobs/([a-f0-9-]{36})$#i', $path, $match)) {
    $user=authenticated($db);
    if ($method === 'POST') requireActiveMembership($db, $user, $config);
    $clientId=strtolower($match[1]);
    if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$clientId)) fail('任务编号不正确。');
    $hex=hash_hmac('sha256',$user['id'].':'.$clientId,$config['otp_secret']);
    $serverId=substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
    $token=$config['ai_proxy_token']??'';
    if(strlen($token)<24)fail('复盘服务尚未配置。',503);
    $requestBody=null;
    if($method==='POST'){
        if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 分析暂未开放，请稍后再试。', 503);
        $requestBody=body(5900000);
        if(($requestBody['kind']??'')!=='weekly_review')fail('请求类型不正确。');
        $db->beginTransaction();
        lockActiveUser($db, (int)$user['id']);
        $existing = $db->prepare('SELECT server_job_id,kind FROM ai_user_jobs WHERE user_id=? AND client_job_id=?'); $existing->execute([(int)$user['id'],$clientId]); $job = $existing->fetch();
        if ($job && ($job['server_job_id'] !== $serverId || $job['kind'] !== 'weekly_review')) { $db->rollBack(); fail('任务编号已经使用。',409); }
        if (!$job) {
            $db->prepare("INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES(?,?,?,'weekly_review',UTC_TIMESTAMP())")->execute([(int)$user['id'],$clientId,$serverId]);
        }
        // Commit the durable job row before the network call. The row itself is
        // enough for deletion to find a late job; holding the users row lock
        // across a 15s AI request blocks the same account's record saves.
        if ($db->inTransaction()) $db->commit();
        $requestBody['id']=$serverId;
        // B05/C-02: same source fingerprint as the /me/ai/jobs creation path.
        $revisionStatement = $db->prepare('SELECT revision FROM app_states WHERE user_id=?');
        $revisionStatement->execute([(int)$user['id']]);
        $sourceRevision = $revisionStatement->fetchColumn();
        if ($sourceRevision !== false) $requestBody['source_revision'] = (string)(int)$sourceRevision;
        $requestBody['_quota_owner']=aiQuotaOwner((int)$user['id'],$config);
        $target='/v1/jobs';
    } elseif(in_array($method,['GET','DELETE'],true)) $target='/v1/jobs/'.$serverId;
    else fail('不支持此操作。',405);
    $context=stream_context_create(['http'=>['method'=>$method,'header'=>"Content-Type: application/json\r\nAuthorization: Bearer ".$token."\r\n",'content'=>$requestBody===null?'':json_encode($requestBody,JSON_THROW_ON_ERROR),'timeout'=>15,'ignore_errors'=>true,'follow_location'=>0]]);
    $raw=@file_get_contents(privateAiBase($config).$target,false,$context);
    $upstreamStatus=502;
    foreach($http_response_header ?? [] as $header) if(preg_match('#^HTTP/\S+ (\d{3})#',$header,$code)) $upstreamStatus=(int)$code[1];
    if ($db->inTransaction()) { if($upstreamStatus>=400 && $upstreamStatus<500) $db->rollBack(); else $db->commit(); }
    if($raw===false)fail('复盘服务暂不可用，输入仍在本机。',503);
    if($upstreamStatus===401)fail('复盘服务鉴权暂时不可用，输入仍在本机。',503);
    $result=json_decode($raw,true);
    if(!is_array($result))fail('复盘服务响应不完整。',503);
    $status=502;
    foreach($http_response_header??[] as $line){if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$m))$status=(int)$m[1];}
    if ($status === 200) aiMarkCompleted($db,(int)$user['id'],$serverId,$result);
    if(isset($result['id']))$result['id']=$clientId;
    respond($status,publicAIResponse($result));
}

// General AI jobs use the same authenticated proxy as weekly reviews. The Python
// worker only sees a deterministic server ID and never receives an app session.
// (aiJobID lives in ai-response.php so the capability router shares it.)

function aiRetryConsumesUsage(int $status, mixed $result): bool {
    // A retry never charges quota. The worker counts the first successful result only.
    return false;
}

function aiRequestJSON(array|stdClass|null $requestBody): string {
    return $requestBody === null ? '' : json_encode($requestBody, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}

function aiProxy(array $config, string $method, string $target, array|stdClass|null $requestBody, string $clientId): never {
    $token = $config['ai_proxy_token'] ?? '';
    if (strlen($token) < 24) fail('AI 服务尚未配置。', 503);
    $content = aiRequestJSON($requestBody);
    $context = stream_context_create(['http' => ['method' => $method, 'header' => "Content-Type: application/json\r\nAuthorization: Bearer " . $token . "\r\n", 'content' => $content, 'timeout' => 20, 'ignore_errors' => true, 'follow_location' => 0]]);
    $relayStarted = microtime(true);
    $raw = @file_get_contents(privateAiBase($config) . $target, false, $context);
    $relayMs = (int)round((microtime(true) - $relayStarted) * 1000);
    global $db, $user;
    $upstreamStatus=502;
    foreach($http_response_header ?? [] as $header) if(preg_match('#^HTTP/\S+ (\d{3})#',$header,$code)) $upstreamStatus=(int)$code[1];
    $result = $raw === false ? null : json_decode($raw, true);
    if ($db->inTransaction()) { if($upstreamStatus>=400 && $upstreamStatus<500) $db->rollBack(); else $db->commit(); }
    if ($raw === false) fail('AI 服务暂不可用，输入仍在本机。', 503);
    if ($upstreamStatus === 401) fail('AI 服务鉴权暂时不可用，输入仍在本机。', 503);
    $result = json_decode($raw, true);
    if (!is_array($result)) fail('AI 服务响应不完整。', 503);
    $status = 502;
    foreach ($http_response_header ?? [] as $line) if (preg_match('#^HTTP/\S+ (\d{3})#', $line, $m)) $status = (int)$m[1];
    if ($status === 200 && ($result['status'] ?? '') === 'succeeded' && is_array($result['result'] ?? null)) {
        $serverId = is_array($requestBody) && isset($requestBody['id']) ? $requestBody['id'] : basename(preg_replace('#/retry$#', '', $target));
        global $user;
        aiMarkCompleted($db,(int)$user['id'],$serverId,$result);
        // Phase 5 §6.2: per-request usage ledger (latency at the relay; token
        // counts nullable until the worker reports provider usage).
        try {
            $db->prepare('INSERT INTO ai_usage_ledger(user_id,server_job_id,kind,status,latency_ms,provider,trace_id,created_at) VALUES(?,?,?,?,?,?,?,UTC_TIMESTAMP())')
                ->execute([(int)$user['id'], $serverId, (string)($result['result']['kind'] ?? $result['kind'] ?? 'unknown'),
                           'succeeded', $relayMs, (string)($result['provider'] ?? ''), $GLOBALS['boji_trace_id'] ?? null]);
        } catch (Throwable $ledgerError) { error_log('BOJI usage ledger failed: ' . get_class($ledgerError)); }
        if (($result['result']['kind'] ?? '') === 'coach') {
            // aiCoachTurnComplete expects the coach object (answer/cards), which
            // the worker nests under result.coach.
            $coachObject = is_array($result['result']['coach'] ?? null) ? $result['result']['coach'] : null;
            $jobQuery = $db->prepare('SELECT purpose,onboarding_session_id FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');
            $jobQuery->execute([(int)$user['id'], $clientId]);
            $jobMeta = $jobQuery->fetch(PDO::FETCH_ASSOC) ?: [];
            $coachPurpose = (string)($jobMeta['purpose'] ?? 'dialogue');
            if ($coachObject !== null && $coachPurpose === 'onboarding_assist') {
                $sessionId = (string)($jobMeta['onboarding_session_id'] ?? '');
                $question = trim((string)($requestBody['payload']['question'] ?? ''));
                $db->beginTransaction();
                try {
                    $candidates = is_array($coachObject['onboarding']['candidates'] ?? null) ? $coachObject['onboarding']['candidates'] : [];
                    $contextRevision = (int)($requestBody['payload']['_onboarding_context']['session_revision'] ?? -1);
                    $liveSession = $sessionId !== '' ? onboardingSessionRead($db, (int)$user['id'], $sessionId) : null;
                    if ($liveSession && (int)$liveSession['revision'] === $contextRevision) {
                        $applied = onboardingApplyModelCandidates($db, (int)$user['id'], $sessionId, $candidates, $question, $clientId);
                        $result['result']['coach']['onboarding_applied'] = $applied['applied'];
                    } else {
                        $result['result']['coach']['onboarding_applied'] = 0;
                        $result['result']['coach']['onboarding_stale'] = true;
                    }
                    onboardingAssistRecordTurn($db, (int)$user['id'], $sessionId, 'assistant', (string)($coachObject['answer'] ?? ''));
                    $db->commit();
                } catch (Throwable $storageError) {
                    if ($db->inTransaction()) $db->rollBack();
                    error_log('BOJI onboarding turn complete failed: ' . get_class($storageError));
                }
            } elseif ($coachObject !== null && $coachPurpose !== 'context_continue') {
                try {
                    aiCoachTurnComplete($db, (int)$user['id'], $clientId, $coachObject);
                } catch (Throwable $storageError) {
                    error_log('BOJI conversation complete failed: ' . get_class($storageError));
                }
            } elseif ($coachObject !== null) {
                try {
                    aiCoachTurnComplete($db, (int)$user['id'], $clientId, $coachObject);
                } catch (Throwable $storageError) {
                    error_log('BOJI conversation complete failed: ' . get_class($storageError));
                }
            }
        }
    } elseif ($status === 200 && ($result['status'] ?? '') === 'failed') {
        // A failed coach turn leaves its user row without an assistant reply;
        // readers (and history injection) treat that shape as an incomplete
        // turn, so no explicit row update is needed here.
    }
    if (isset($result['id'])) $result['id'] = $clientId;
    // B05/C-02 serve-time source check: Python cannot see MySQL, so freshness is
    // verified here where the live revision lives. A mismatch means records
    // changed after the model read its snapshot; the result stays available but
    // is no longer presented as the current version.
    if ($method === 'GET' && preg_match('#^/v1/jobs/[a-f0-9-]{36}$#', $target)
        && in_array($result['kind'] ?? '', ['report','weekly_review'], true)
        && ($result['status'] ?? '') === 'succeeded'
        && is_string($result['source_revision'] ?? null)) {
        try {
            $revisionQuery = $db->prepare('SELECT revision FROM app_states WHERE user_id=?');
            $revisionQuery->execute([(int)$user['id']]);
            $currentRevision = $revisionQuery->fetchColumn();
            if ($currentRevision !== false && (string)(int)$currentRevision !== $result['source_revision']) {
                $result['source_status'] = 'stale';
                $result['source_note'] = '生成后记录已更新，本报告保留为历史版本。';
            }
        } catch (Throwable $staleCheckError) { error_log('BOJI stale check failed: ' . get_class($staleCheckError)); }
    }
    respond($status, publicAIResponse($result));
}

// The authenticated caller can inspect their own successful-use counter only.
if($method==='GET' && $path==='/me/ai/usage') {
    $user=authenticated($db);
    respond(200,aiQuotaRequest($config,'usage',['owner'=>aiQuotaOwner((int)$user['id'],$config)]));
}

require_once __DIR__.'/task-recovery.php';
if($method==='GET' && $path==='/me/tasks') {
    $user=authenticated($db);respond(200,taskRecoveryPage($db,(int)$user['id'],$config,$_GET));
}

if ($path === '/me/ai/jobs' || preg_match('#^/me/ai/jobs/([a-f0-9-]{36})(/retry)?$#i', $path, $match)) {
    $user = authenticated($db);
    if ($method === 'POST') revenueCatRefreshIfDue($db, $user, $config);
    $requestBody = null;
    if ($path === '/me/ai/jobs') {
        if ($method !== 'POST') fail('不支持此操作。', 405);
        if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 分析暂未开放，请稍后再试。', 503);
        $requestBody = body(5900000);
        $clientId = strtolower((string)($requestBody['id'] ?? ''));
        $kind = (string)($requestBody['kind'] ?? '');
        if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D', $clientId) || !in_array($kind, ['generate_plan','parse_plan','food','report','coach'], true)) fail('AI 任务格式不正确。');
        $serverId = aiJobID($user, $clientId, $config);
        $clientPurpose = (string)($requestBody['payload']['purpose'] ?? 'dialogue');
        if (!in_array($clientPurpose, ['dialogue','workout','weekly'], true)) { $clientPurpose = 'dialogue'; }
        $serverPurpose = $kind === 'coach' ? $clientPurpose : '';
        $onboardingSessionId = null;
        $contextSnapshot = null;
        $planOnboardingSession = null;
        if (in_array($kind, ['generate_plan','parse_plan'], true) && isset($requestBody['onboarding_session_id'])) {
            $candidateSession = strtolower(trim((string)$requestBody['onboarding_session_id']));
            if (!preg_match('/^[0-9a-f-]{36}$/D', $candidateSession)) fail('引导会话编号不正确。', 422);
            $planOnboardingSession = onboardingSessionRead($db, (int)$user['id'], $candidateSession);
            if (!$planOnboardingSession) fail('引导会话不存在。', 404);
            $sessionPublic = onboardingSessionPublic($db, $planOnboardingSession);
            $taskKind = (string)$planOnboardingSession['task_kind'];
            if ($kind === 'generate_plan' && !$sessionPublic['plan_ready']) fail('请先核对生成第一份计划所需的资料。', 409);
            if ($kind === 'parse_plan' && $taskKind !== 'plan_import') fail('当前引导任务不是导入计划。', 409);
            $requestBody['onboarding_session_id'] = $candidateSession;
            $onboardingSessionId = $candidateSession;
        }
        if(in_array($kind,['generate_plan','parse_plan'],true)&&($requestBody['payload']['_v2_profile']??false)===true){
            $rawProfile=is_array($requestBody['payload']['profile']??null)?$requestBody['payload']['profile']:[];
            $requestBody['payload']['profile']=profileFactsPlanningPayload($db,(int)$user['id'],$rawProfile,$planOnboardingSession===null);
            if(isset($requestBody['payload']['weight_reference'])){$reference=profileFactsMeasuredPlanWeight($db,(int)$user['id'],$requestBody['payload']['weight_reference']);$requestBody['payload']['weight_reference']=$reference;$requestBody['payload']['profile']['weight']=$reference['kilograms'];}
        }
        if ($kind === 'coach' && isset($requestBody['onboarding_session_id'])) {
            $onboardingSessionId = strtolower(trim((string)$requestBody['onboarding_session_id']));
            if (!preg_match('/^[0-9a-f-]{36}$/D', $onboardingSessionId)) fail('引导会话编号不正确。', 422);
            $session = onboardingSessionRead($db, (int)$user['id'], $onboardingSessionId);
            if (!$session) fail('引导会话不存在。', 404);
            if ((string)$session['status'] === 'completed') fail('引导已经结束，请使用普通对话。', 409);
            if (!hash_equals((string)$session['conversation_id'], (string)($requestBody['payload']['conversation_id'] ?? ''))) fail('引导对话编号不一致。', 409);
            $serverPurpose = 'onboarding_assist';
            $requestBody['payload']['purpose'] = 'onboarding_assist';
            $requestBody['payload']['_onboarding_session_id'] = $onboardingSessionId;
            unset($requestBody['payload']['_onboarding_context'], $requestBody['payload']['_context_source'], $requestBody['payload']['onboarding_session_id'], $requestBody['payload']['context_source']);
        } elseif ($kind === 'coach' && isset($requestBody['context_source'])) {
            $contextSnapshot = contextSourceResolve($db, (int)$user['id'], $requestBody['context_source']);
            $serverPurpose = 'context_continue';
            $requestBody['payload']['purpose'] = 'context_continue';
            $requestBody['payload']['_context_source'] = contextSourcePrompt($contextSnapshot);
            unset($requestBody['payload']['_onboarding_context'], $requestBody['payload']['_onboarding_session_id']);
        }
        $requestBody['payload']['_fast_intent_enabled']=appFeatureEnabled($db,'ai_fast_intent_v1');
        $requestBody['payload']['_router_v3']=appFeatureEnabled($db,'ai_router_v3');
        require_once __DIR__.'/ai-context.php';
        aiProviderConsentAssert($db,(int)$user['id'],$requestBody['payload']);
        unset($requestBody['payload']['_references'],$requestBody['payload']['_intent'],$requestBody['payload']['reference_selection']);
        if($kind==='coach'&&isset($requestBody['payload']['context_bundle_id'])){
            require_once __DIR__.'/ai-context.php';
            if(!appFeatureEnabled($db,'ai_context_references_v1'))fail('引用功能暂未开放。',503);
            try { $bundle=aiContextLoad($db,(int)$user['id'],(string)$requestBody['payload']['context_bundle_id'],(string)$requestBody['payload']['conversation_id'],$config); } catch(RuntimeException $e){fail($e->getMessage(),in_array($e->getCode(),[403,409,410,422,503],true)?$e->getCode():422);}
            $requestBody['payload']['_references']=$bundle['references'];$requestBody['payload']['days']=[];$requestBody['payload']['upcoming']=[];
            $requestBody['payload']['_analysis_read_only131']=localContextIsReadOnly131($bundle['references']);
        }
        try {
            $db->beginTransaction();
            lockActiveUser($db, (int)$user['id']);
            $existing = $db->prepare('SELECT server_job_id,kind,created_at,purpose,onboarding_session_id FROM ai_user_jobs WHERE user_id=? AND client_job_id=? FOR UPDATE');
            $existing->execute([(int)$user['id'], $clientId]);
            $existingJob = $existing->fetch(PDO::FETCH_ASSOC) ?: null;
            if ($existingJob && $existingJob['kind'] !== $kind) { $db->rollBack(); fail('任务编号已经用于其他分析。', 409); }
            if ($existingJob && $kind === 'coach' && (string)($existingJob['purpose'] ?? '') !== $serverPurpose) { $db->rollBack(); fail('同一任务编号不能更换对话用途。', 409); }
            if (!$existingJob && $kind === 'coach') {
                try { chatValidateInput($db,(int)$user['id'],$requestBody); }
                catch (RuntimeException $e) { $db->rollBack(); fail($e->getMessage(), in_array($e->getCode(),[409,422],true)?$e->getCode():422); }
            }
            if (!aiMayPostJob($db, $user, $config, $kind, $existingJob, $serverPurpose)) { $db->rollBack(); fail('请先开通会员后使用此功能。', 403); }
            if ($kind === 'coach' && $serverPurpose !== 'onboarding_assist' && $existingJob === null && aiCoachQuotaLeft($db, (int)$user['id']) <= 0) {
                $db->rollBack();
                header('Retry-After: ' . max(60, 86400 - ((time() + 8 * 3600) % 86400)));
                fail('今天的对话次数已达上限，明天再继续。', 429);
            }
            if (!$existingJob) {
                $insert = $db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,purpose,onboarding_session_id,created_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())');
                $insert->execute([(int)$user['id'], $clientId, $serverId, $kind,
                                  $kind === 'coach' ? $serverPurpose : null,
                                  $onboardingSessionId]);
            }
            if ($kind === 'coach' && $serverPurpose === 'onboarding_assist' && !$existingJob) {
                $reserved = onboardingAssistReserve($db, (int)$user['id'], (string)$onboardingSessionId);
                $requestBody['payload']['_onboarding_context'] = onboardingAssistContext($db, (int)$user['id'], $reserved['session'],
                    trim((string)($requestBody['payload']['question'] ?? '')));
            }
        } catch (PDOException $error) {
            if ($db->inTransaction()) $db->rollBack();
            fail('AI 任务保存失败，请稍后重试。', 503);
        } catch (RuntimeException $error) {
            if ($db->inTransaction()) $db->rollBack();
            fail($error->getMessage(), $error->getCode() >= 400 && $error->getCode() < 600 ? $error->getCode() : 500);
        }
        // Commit the idempotent job row before AI I/O; do not hold the account lock.
        if ($db->inTransaction()) $db->commit();
        if ($planOnboardingSession !== null) {
            $bind = $db->prepare("UPDATE user_onboarding_sessions SET first_job_id=?,revision=revision+1,updated_at=UTC_TIMESTAMP()
                WHERE user_id=? AND id=? AND (first_job_id IS NULL OR first_job_id<>?)");
            $bind->execute([$clientId, (int)$user['id'], (string)$planOnboardingSession['id'], $clientId]);
        }
        if ($kind === 'coach') {
            // M-1 §2.3: server-authoritative dialogue history replaces the
            // client-carried 6 pairs when this conversation has stored turns;
            // otherwise the client payload passes through unchanged (pre-M-1
            // conversations keep working). The user turn is recorded before
            // the network call so a crashed job still leaves its question.
            $payload = is_array($requestBody['payload'] ?? null) ? $requestBody['payload'] : [];
            if ($serverPurpose === 'onboarding_assist') {
                $requestBody['payload']['memory'] = [];
                $requestBody['payload']['capabilities'] = onboardingCapabilityWhitelist();
                $requestBody['payload']['history'] = onboardingAssistHistory($db, (int)$user['id'], (string)$onboardingSessionId, 10);
                $requestBody['payload']['action_preferences'] = ['weight_unit' => 'kg'];
                $requestBody['payload']['days'] = [];
                $requestBody['payload']['upcoming'] = [];
                $requestBody['payload']['context_days'] = 0;
                onboardingAssistRecordTurn($db, (int)$user['id'], (string)$onboardingSessionId, 'user', trim((string)($payload['question'] ?? '')));
            } elseif ($serverPurpose === 'context_continue') {
                $requestBody['payload']['memory'] = [];
                $requestBody['payload']['capabilities'] = appFeatureEnabled($db,'action_system_enabled')?capabilityWhitelistForChatImages($payload):[];
                $preferences=actionPreferences($db,(int)$user['id']);
                $requestBody['payload']['action_preferences']=['weight_unit'=>$preferences['weight_unit']];
                $requestBody['payload']['days'] = [];
                $requestBody['payload']['upcoming'] = [];
                $requestBody['payload']['context_days'] = 0;
                if(aiConversationIdValid($payload['conversation_id'] ?? null)){
                    $history=aiCoachHistory($db,(int)$user['id'],(string)$payload['conversation_id']);
                    if($history)$requestBody['payload']['history']=$history;
                    aiCoachTurnRecord($db,(int)$user['id'],$clientId,$payload);
                }
            } else {
                // Client-supplied memory is never trusted (matches the streaming path,
                // which unconditionally unsets it): otherwise a crafted payload could
                // inject fake "long-term memory" into the system prompt whenever the
                // server simply has no statements yet.
                unset($requestBody['payload']['memory']);
                // Phase 4 §5.1: deterministic memory statements feed the prompt.
                try {
                    $memory = aiMemoryForContext($db, (int)$user['id']);
                    if ($memory) $requestBody['payload']['memory'] = $memory;
                } catch (Throwable $memoryError) {
                    error_log('BOJI memory inject failed: ' . get_class($memoryError));
                }
                // Phase 2 §2: the model may only REQUEST whitelisted capabilities.
                try {
                    $requestBody['payload']['capabilities'] = appFeatureEnabled($db,'action_system_enabled')?capabilityWhitelistForChatImages($payload):[];
                    $preferences=actionPreferences($db,(int)$user['id']);
                    $requestBody['payload']['action_preferences']=['weight_unit'=>$preferences['weight_unit']];
                } catch (Throwable $capabilityError) {
                    error_log('BOJI capability whitelist failed: ' . get_class($capabilityError));
                }
            }
            if (!in_array($serverPurpose, ['onboarding_assist', 'context_continue'], true) && aiConversationIdValid($payload['conversation_id'] ?? null)) {
                try {
                    $history = aiCoachHistory($db, (int)$user['id'], (string)$payload['conversation_id']);
                    if ($history) $requestBody['payload']['history'] = $history;
                    aiCoachTurnRecord($db, (int)$user['id'], $clientId, $payload);
                } catch (Throwable $storageError) {
                    // Storage is a side channel: the submit must proceed even if it fails.
                    error_log('BOJI conversation record failed: ' . get_class($storageError));
                }
            }
        }
        if($kind==='coach'&&!empty($requestBody['payload']['_analysis_read_only131'])){
            $requestBody['payload']['memory']=[];
            $requestBody['payload']['capabilities']=array_values(array_filter($requestBody['payload']['capabilities']??[],fn($cap)=>in_array(capabilityRegistryEntry($cap['capability'])['mode']??'',['read_only','advisory'],true)));
        }
        if($kind==='coach'&&is_string($requestBody['payload']['timeZone']??null)){
          try{$zone=new DateTimeZone($requestBody['payload']['timeZone']);$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,updated_at) VALUES(?,0,?,'kg',UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE time_zone=VALUES(time_zone),updated_at=UTC_TIMESTAMP()")->execute([(int)$user['id'],$zone->getName()]);}catch(Exception $e){fail('时区不正确。',422);}
        }
        if($kind==='coach')$db->prepare("INSERT IGNORE INTO ai_action_messages(user_id,message_id,conversation_id,trace_id,status,created_at,updated_at) VALUES(?,?,?,?,'accepted',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([(int)$user['id'],$clientId,$requestBody['payload']['conversation_id']??null,$GLOBALS['boji_trace_id']??null]);
        $requestBody['id'] = $serverId;
        // B05/C-02: record the sync revision that produced this report. The serve
        // path compares it against the current revision so a report generated from
        // since-changed records is presented as a historical version, not current.
        if (in_array($kind, ['report','weekly_review'], true)) {
            $revisionStatement = $db->prepare('SELECT revision FROM app_states WHERE user_id=?');
            $revisionStatement->execute([(int)$user['id']]);
            $sourceRevision = $revisionStatement->fetchColumn();
            if ($sourceRevision !== false) $requestBody['source_revision'] = (string)(int)$sourceRevision;
        }
        $requestBody['_quota_owner']=aiQuotaOwner((int)$user['id'],$config);
        require_once __DIR__.'/usage-guard131.php';
        try { usageGuard131($db,(int)$user['id'],$config); } catch(RuntimeException $e) { fail($e->getMessage(),in_array($e->getCode(),[429,503],true)?$e->getCode():503); }
        aiProxy($config, 'POST', '/v1/jobs', $requestBody, $clientId);
    }
    $clientId = strtolower($match[1]);
    if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D', $clientId)) fail('任务编号不正确。');
    $statement = $db->prepare('SELECT server_job_id FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');
    $statement->execute([(int)$user['id'], $clientId]);
    $serverId = $statement->fetchColumn();
    if (!is_string($serverId)) fail('任务不存在。', 404);
    if (!empty($match[2])) {
        if ($method !== 'POST') fail('不支持此操作。', 405);
        if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 分析暂未开放，请稍后再试。', 503);
        try {
            $db->beginTransaction();
            lockActiveUser($db, (int)$user['id']);
            $locked = $db->prepare('SELECT server_job_id,kind,created_at FROM ai_user_jobs WHERE user_id=? AND client_job_id=? FOR UPDATE');
            $locked->execute([(int)$user['id'], $clientId]);
            $existingJob = $locked->fetch(PDO::FETCH_ASSOC) ?: null;
            if (!$existingJob) { $db->rollBack(); fail('任务不存在。', 404); }
            if (!aiMayPostJob($db, $user, $config, (string)$existingJob['kind'], $existingJob)) { $db->rollBack(); fail('请先开通会员后使用此功能。', 403); }
            $serverId = $existingJob['server_job_id'];
        } catch (PDOException $error) {
            if ($db->inTransaction()) $db->rollBack();
            fail('AI 重试保存失败，请稍后重试。', 503);
        }
        if ($db->inTransaction()) $db->commit();
        aiProxy($config, 'POST', '/v1/jobs/' . $serverId . '/retry', ['_quota_owner'=>aiQuotaOwner((int)$user['id'],$config)], $clientId);
    }
    if ($method !== 'GET') fail('不支持此操作。', 405);
    aiProxy($config, 'GET', '/v1/jobs/' . $serverId, null, $clientId);
}

// M-1 §2.3 read path: the member's own conversation list and paged messages.
// Every query filters by the authenticated user id (cross-account reads return
// empty, never another member's rows).
if ($method === 'GET' && $path === '/me/ai/conversations') {
    $user = authenticated($db);
    respond(200, ['conversations' => aiConversationList($db, (int)$user['id'])]);
}
if ($method === 'GET' && preg_match('#^/me/ai/conversations/([0-9a-f-]{8,64})/messages$#', $path, $convMatch)) {
    $user = authenticated($db);
    $before = isset($_GET['before']) ? filter_var($_GET['before'], FILTER_VALIDATE_INT) : null;
    if ($before !== null && $before !== false && $before < 1) fail('分页参数不正确。');
    $limit = isset($_GET['limit']) ? filter_var($_GET['limit'], FILTER_VALIDATE_INT) : 30;
    if ($limit === false || $limit === null) $limit = 30;
    $page = aiConversationMessages($db, (int)$user['id'], (string)$convMatch[1],
        ($before !== null && $before !== false) ? $before : null, (int)$limit);
    respond(200, $page);
}

// Phase 2 §2.5 (D-09): server-owned home insight. Returns null when nothing is
// verified server-side; the client then keeps its local insight rules.
if ($method === 'GET' && $path === '/me/ai/insights/home') {
    $user = authenticated($db);
    if (!appFeatureEnabled($db, 'ai_enabled')) respond(200, ['insight' => null]);
    $state = clubState($db, (int)$user['id']);
    respond(200, ['insight' => insightHomePick($db, (int)$user['id'], is_array($state) ? $state : [], insightHomeToday())]);
}

// Phase 3 §4.1 (M-2): proposal intake and status. The AI can only PROPOSE;
// execution runs exclusively through /me/commands (PlanReschedule.Confirm /
// Meal.Create / BodyWeight.Create) which re-validates the proposal at
// confirmation time and applies the stored payload.
if ($path === '/me/ai/proposals') {
    $user = authenticated($db);
    if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 提案暂未开放。', 503);
    if ($method === 'POST') {
        $body = body(200000);
        $kind = (string)($body['kind'] ?? '');
        if (!aiProposalKindValid($kind)) fail('提案类型不正确。', 400);
        if (!is_string($body['idempotency_key'] ?? null) || !preg_match('/^[0-9a-f]{64}$/D', $body['idempotency_key'])) {
            fail('提案需要稳定的操作标识，请更新客户端后重试。', 400);
        }
        $db->beginTransaction();
        try {
            $result = aiProposalCreate($db, (int)$user['id'], $kind,
                is_array($body['payload'] ?? null) ? $body['payload'] : [],
                is_array($body['evidence_refs'] ?? null) ? $body['evidence_refs'] : [],
                isset($body['conversation_id']) && is_string($body['conversation_id']) ? substr($body['conversation_id'], 0, 64) : null,
                isset($body['idempotency_key']) && is_string($body['idempotency_key']) ? $body['idempotency_key'] : null,
                AI_PROPOSAL_TTL_HOURS, is_array($body['baseline_days'] ?? null) ? $body['baseline_days'] : null);
            $db->commit();
        } catch (Throwable $error) {
            if ($db->inTransaction()) $db->rollBack();
            throw $error;
        }
        respond(200, $result + ['kind' => $kind]);
    }
    if ($method !== 'GET') fail('不支持此操作。', 405);
    aiProposalExpireDue($db, (int)$user['id']);
    respond(200, ['proposals' => aiProposalList($db, (int)$user['id'],
        isset($_GET['status']) ? (string)$_GET['status'] : null)]);
}
if ($method === 'GET' && preg_match('#^/me/ai/proposals/([0-9a-f-]{36})$#i', $path, $propMatch)) {
    $user = authenticated($db);
    aiProposalExpireDue($db, (int)$user['id']);
    $row = aiProposalFetch($db, (int)$user['id'], strtolower($propMatch[1]));
    if (!$row) fail('提案不存在。', 404);
    respond(200, ['proposal' => $row]);
}
// Phase 3 §4.1: cancel a proposal the user no longer wants (spec §6).
if ($method === 'POST' && preg_match('#^/me/ai/proposals/([0-9a-f-]{36})/cancel$#i', $path, $propMatch)) {
    $user = authenticated($db);
    $proposalID=strtolower($propMatch[1]);
    $db->beginTransaction();
    try{
      lockActiveUser($db,(int)$user['id']);aiProposalExpireDue($db,(int)$user['id']);
      $row=aiProposalFetch($db,(int)$user['id'],$proposalID);
      if(!$row)businessReject(404,['error'=>'提案不存在。']);
      if($row['status']==='cancelled'){$db->commit();respond(200,['proposal_id'=>$proposalID,'status'=>'cancelled']);}
      $update=$db->prepare("UPDATE ai_action_proposals SET status='cancelled',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=? AND status IN ('draft','validated','awaiting_confirmation')");
      $update->execute([(int)$user['id'],$proposalID]);if(!$update->rowCount())businessReject(409,['error'=>'操作已结束，不能取消。','status'=>$row['status']]);
      $db->commit();respond(200,['proposal_id'=>$proposalID,'status'=>'cancelled']);
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}

// Phase 4 §5.1/§5.2 (D-10): long-term memory page + member controls.
// Phase 4 §5.5 + Phase 5 §6.3: feedback loop + client metric events
// (曝光→接受→执行→结果链路 + R-31 最小埋点，同一张表按 kind 区分)。
if ($method === 'POST' && $path === '/me/ai/feedback') {
    $user = authenticated($db);
    if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 反馈通道暂未开放。', 503);
    $body = body(20000);
    $entries = is_array($body['events'] ?? null) ? $body['events'] : [is_array($body['event'] ?? null) ? $body['event'] : []];
    if (count($entries) > 20) fail('单批事件过多。', 400);
    $insert = $db->prepare('INSERT INTO ai_feedback_events(user_id,kind,name,target_id,action,detail_json,created_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())');
    $db->beginTransaction();
    try {
        $stored = 0;
        $memoryUpdates = [];
        foreach ($entries as $entry) {
            if (!is_array($entry)) continue;
            $kind = substr(trim((string)($entry['kind'] ?? '')), 0, 40);
            if ($kind === '') continue;
            $name = isset($entry['name']) ? substr(trim((string)$entry['name']), 0, 60) : null;
            $targetId = isset($entry['target_id']) ? substr(trim((string)$entry['target_id']), 0, 80) : null;
            $action = isset($entry['action']) ? substr(trim((string)$entry['action']), 0, 30) : null;
            $detail = isset($entry['detail']) && is_array($entry['detail']) ? json_encode($entry['detail'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) : null;
            $insert->execute([(int)$user['id'], $kind, $name, $targetId, $action, $detail]);
            $stored++;
            // Phase 5 feedback loop: memory feedback moves the confidence of an
            // active memory; explicit corrections still take precedence.
            $updated = aiMemoryApplyFeedback($db, (int)$user['id'], $entry);
            if ($updated !== null) $memoryUpdates[] = $updated;
        }
        $db->commit();
        respond(200, ['stored' => $stored, 'memory_updates' => $memoryUpdates]);
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

if ($method === 'GET' && $path === '/me/ai/memory') {
    $user = authenticated($db);
    respond(200, ['columns' => aiMemoryPage($db, (int)$user['id'])]);
}
if ($method === 'POST' && preg_match('#^/me/ai/memory/([0-9a-f-]{36})/(correct|suspend|resume|withdraw)$#i', $path, $memMatch)) {
    $user = authenticated($db);
    $memoryId = strtolower($memMatch[1]);
    $action = strtolower($memMatch[2]);
    if ($action === 'correct') {
        $body = body(2000);
        $content = trim((string)($body['content'] ?? ''));
        $db->beginTransaction();
        try {
            $result = aiMemoryCorrect($db, (int)$user['id'], $memoryId, $content);
            $db->commit();
        } catch (Throwable $error) {
            if ($db->inTransaction()) $db->rollBack();
            throw $error;
        }
        respond(200, $result);
    }
    $changed = aiMemorySetStatus($db, (int)$user['id'], $memoryId,
        $action === 'suspend' ? 'suspended' : ($action === 'resume' ? 'active' : 'withdrawn'));
    respond(200, ['changed' => $changed]);
}
