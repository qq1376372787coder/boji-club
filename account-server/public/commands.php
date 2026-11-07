<?php
declare(strict_types=1);

/**
 * Unified Business Commands Handler (A2 / A3 Architecture).
 *
 * Provides CAS version-controlled business mutations for schedules, profiles,
 * and workouts. Guarantees mutual exclusion, idempotency via data_operations,
 * and publishes domain events into domain_outbox in the same database transaction.
 */


require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/action-compensation.php';
require_once __DIR__ . '/action-sync.php';
require_once __DIR__ . '/ai-proposals.php';
require_once __DIR__ . '/training-commands.php';

function commandUUID(): string { return businessUUID(); }

// Phase 1: proposal-free direct records carry a client idempotency key.
const DIRECT_COMMAND_TYPES = ['BodyWeight.CreateDirect', 'Meal.CreateDirect'];
// Phase 1: training lifecycle commands (single active session invariant).
const TRAINING_COMMAND_TYPES = ['Training.SessionStart', 'Training.SessionFinish', 'Training.LogSet','Training.CorrectSet','Training.CorrectSet'];

function handleBusinessCommand(PDO $db, array $user): array {
    // HTTP wrapper: parse + size gate, then the pure core (also exercised by tests).
    return businessScoped(fn()=>handleBusinessCommandCore($db, $user, body(1024 * 1024))); // max 1MB command
}

function handleBusinessCommandCore(PDO $db, array $user, array $cmd): array {
    $uid = (int)$user['id'];

    $commandId = trim((string)($cmd['commandId'] ?? ''));
    if (!preg_match('/^[0-9a-f-]{36}$/i', $commandId)) {
        fail('命令标识不正确（commandId 必须为 UUID）。', 400);
    }
    
    $type = trim((string)($cmd['type'] ?? ''));
    // Schedule.Rest and Workout.Confirm used to fall through to a generic
    // "succeeded" response without changing anything. Reject them explicitly
    // until they have real command semantics.
    $allowedTypes = ['Schedule.Replace', 'Schedule.Move', 'Profile.Update',
                     'PlanReschedule.Confirm', 'Meal.Create', 'BodyWeight.Create',
                     'Training.SessionStart', 'Training.SessionFinish', 'Training.LogSet','Training.CorrectSet',
                     'BodyWeight.CreateDirect', 'Meal.CreateDirect',
                     'ExerciseSwap.Confirm', 'PlanVersion.Activate','Training.FinishConfirm','Training.DiscardConfirm'];
    if (!in_array($type, $allowedTypes, true)) {
        fail("不支持的业务命令类型: {$type}。", 400);
    }
    
    $payload = $cmd['payload'] ?? [];
    if (!is_array($payload)) fail('命令载荷格式不正确。', 400);
    
    $expectedVersions = $cmd['expectedVersions'] ?? [];
    if (!is_array($expectedVersions)) fail('期望版本号格式不正确。', 400);
    
    $payloadHash = hash('sha256', json_encode([$type, $payload, $expectedVersions], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    $actor = ($cmd['actor'] ?? '') === 'ai' ? 'ai' : 'user';
    
    // Expiry sweep before the transaction: a failed confirmation must not
    // roll the sweep back (the due proposal stays expired either way).
    if (in_array(($cmd['type'] ?? ''), ['PlanReschedule.Confirm', 'Meal.Create', 'BodyWeight.Create', 'ExerciseSwap.Confirm', 'PlanVersion.Activate','Training.FinishConfirm','Training.DiscardConfirm'], true)) {
        require_once __DIR__ . '/ai-proposals.php';
        aiProposalExpireDue($db, (int)$user['id']);
    }
    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        actionAssertParentActive($db, $uid);
        
        // 1. Idempotency Check in data_operations
        $q = $db->prepare('SELECT payload_hash,command_type, after_version, status, diff_json FROM data_operations WHERE operation_id=? AND user_id=? FOR UPDATE');
        $q->execute([$commandId, $uid]);
        $existingOp = $q->fetch();
        if ($existingOp) {
            if ($existingOp['payload_hash'] !== $payloadHash && !($existingOp['command_type'] === $type && hash_equals($existingOp['payload_hash'], hash('sha256', json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))))) {
                fail('同一 commandId 不得使用不同载荷重复提交。', 400);
            }
            $db->commit();
            return [
                'commandId' => $commandId,
                'status' => $existingOp['status'],
                'version' => $existingOp['after_version'],
                'idempotent' => true,
                'diff' => json_decode((string)$existingOp['diff_json'], true)
            ];
        }

        // 1b. Semantic idempotency for direct commands: the same operation key
        // must always map to the same payload, even when the client lost its
        // queue and generated a fresh commandId (reinstall / new device).
        $idempotencyKey = null;
        if (in_array($type, DIRECT_COMMAND_TYPES, true)) {
            $idempotencyKey = $payload['idempotency_key'] ?? null;
            if (!is_string($idempotencyKey) || preg_match('/^[0-9a-f]{64}$/D', $idempotencyKey) !== 1) {
                fail('直接记录需要稳定的操作标识（idempotency_key）。', 400);
            }
            $q = $db->prepare('SELECT operation_id,payload_hash,command_type,after_version,status,diff_json FROM data_operations WHERE user_id=? AND idempotency_key=? FOR UPDATE');
            $q->execute([$uid, $idempotencyKey]);
            $keyedOp = $q->fetch();
            if ($keyedOp) {
                if (!hash_equals($keyedOp['payload_hash'], $payloadHash)) {
                    fail('同一操作标识不能用于不同的记录内容。', 409);
                }
                $db->commit();
                return [
                    'commandId' => (string)$keyedOp['operation_id'],
                    'status' => $keyedOp['status'],
                    'version' => $keyedOp['after_version'],
                    'idempotent' => true,
                    'diff' => json_decode((string)$keyedOp['diff_json'], true)
                ];
            }
        }
        
        // 2. Load current state and revision
        $q = $db->prepare('SELECT revision, state_json FROM app_states WHERE user_id=? FOR UPDATE');
        $q->execute([$uid]);
        $stateRow = $q->fetch();
        $currentRevision = $stateRow ? (int)$stateRow['revision'] : 0;
        $state = $stateRow ? json_decode($stateRow['state_json'], true) : [];
        if (!is_array($state)) $state = [];
        $partitioned = ($state['_partitioned'] ?? null) === 2;
        $proposalRow = null;
        $proposalId = '';
        $dates = [];
        if (in_array($type, ['PlanReschedule.Confirm', 'Meal.Create', 'BodyWeight.Create', 'ExerciseSwap.Confirm', 'PlanVersion.Activate','Training.FinishConfirm','Training.DiscardConfirm'], true)) {
            $proposalId = strtolower(trim((string)($payload['proposalId'] ?? '')));
            $proposalRow = aiProposalFetch($db, $uid, $proposalId);
            if (!$proposalRow) fail('提案不存在。', 404);
            $expectedKind = ['PlanReschedule.Confirm' => 'plan_change_proposal', 'Meal.Create' => 'meal_draft', 'BodyWeight.Create' => 'weight_entry',
                             'ExerciseSwap.Confirm' => 'exercise_swap', 'PlanVersion.Activate' => 'plan_activation','Training.FinishConfirm'=>'training_finish','Training.DiscardConfirm'=>'training_finish'][$type];
            if ($proposalRow['kind'] !== $expectedKind) fail('提案类型与命令不匹配。', 400);
            if ($proposalRow['status'] === 'succeeded') {
                $db->commit();
                return ['commandId' => $proposalRow['confirmed_command_id'], 'status' => 'succeeded', 'idempotent' => true];
            }
            if ($proposalRow['status'] !== 'awaiting_confirmation') fail('提案已过期或已失效，请重新预览。', 409);
            $storedPayload = $proposalRow['payload'];
            if ($type === 'PlanVersion.Activate') {
                $dates = array_values(array_unique(array_column($storedPayload['sessions'] ?? [], 'date')));
            } else {
                $dates = isset($storedPayload['moves'])
                    ? array_merge(array_column($storedPayload['moves'], 'from'), array_column($storedPayload['moves'], 'to'))
                    : [$storedPayload['date']];
            }
        } else {
            foreach (['date', 'from', 'to'] as $key) if (isset($payload[$key])) $dates[] = $payload[$key];
        }
        $state = businessStateRead($db, $uid, $state, $dates);
        $beforeState = $state;
        if (!isset($state['days']) || !is_array($state['days'])) $state['days'] = [];
        
        $aggregateType = 'schedule';
        $aggregateId = '';
        $beforeVersion = '';
        $afterVersion = '';
        $eventType = '';
        $diff = [];
        
        // Stored proposals are bound to the exact training state at preview.
        $proposalKind = is_array($proposalRow) ? (string)$proposalRow['kind'] : '';
        $proposalPayload = is_array($proposalRow['payload'] ?? null) ? $proposalRow['payload'] : [];

        if(in_array($type,['Training.FinishConfirm','Training.DiscardConfirm'],true)){
            foreach($proposalPayload['_expected_days']??[] as $d=>$hash)if(!hash_equals($hash,businessDayFingerprint($state['days'][$d]??[])))fail('训练内容已变化，请重新预览。',409);
            $type=$type==='Training.FinishConfirm'?'Training.SessionFinish':'Training.SessionDiscard';$payload=$proposalPayload;
        }
        // 3. Process Specific Command Types
        if ($type === 'Schedule.Replace') {
            $date = trim((string)($payload['date'] ?? ''));
            if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) fail('目标日期格式不正确。', 400);
            $aggregateId = $date;
            
            // CAS Version check
            $expectedVer = $expectedVersions["schedule:{$date}"] ?? $expectedVersions['schedule'] ?? null;
            if($expectedVer===null)fail('缺少日程版本，请重新读取后提交。',409);
            $currentDayVer = (int)($state['days'][$date]['_schedule_version'] ?? 1);
            $beforeVersion = (string)$currentDayVer;
            
            if ($expectedVer !== null && (int)$expectedVer !== $currentDayVer) {
                $db->rollBack();
                businessReject(409, [
                    'error' => "日程在其他会话已更新（当前版本: {$currentDayVer}，提交版本: {$expectedVer}），请重新预览核对。",
                    'conflict' => true,
                    'currentVersion' => $currentDayVer,
                    'date' => $date
                ]);
            }
            
            // Invariant: started / completed workouts cannot be overwritten
            $existingDay = $state['days'][$date] ?? [];
            if (businessDayProtected($existingDay)) {
                fail("日期 {$date} 的训练已开始或已确认完成，受保护不可直接替换。", 409);
            }
            
            $newExercises = $payload['exercises'] ?? [];
            if (!is_array($newExercises)) fail('替换动作清单格式不正确。', 400);
            
            $diff = [
                'before_exercises' => $existingDay['exercises'] ?? [],
                'after_exercises' => $newExercises
            ];
            
            // Apply replacement
            $afterDayVer = $currentDayVer + 1;
            $afterVersion = (string)$afterDayVer;
            $state['days'][$date]['exercises'] = $newExercises;
            $state['days'][$date]['_schedule_version'] = $afterDayVer;
            $state['days'][$date]['updated_at'] = gmdate('Y-m-d\TH:i:s\Z');
            
            $eventType = 'ScheduleReplaced';
            
        } elseif ($type === 'Schedule.Move') {
            $fromDate = trim((string)($payload['from'] ?? ''));
            $toDate = trim((string)($payload['to'] ?? ''));
            if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $fromDate) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $toDate)) {
                fail('移动起止日期格式不正确。', 400);
            }
            $aggregateId = "{$fromDate}->{$toDate}";
            
            $fromDay = $state['days'][$fromDate] ?? [];
            $toDay = $state['days'][$toDate] ?? [];
            
            if (businessDayProtected($fromDay)) {
                fail("原日期 {$fromDate} 的训练已开始或已完成，不可移动。", 409);
            }
            if (businessDayProtected($toDay) || !empty($toDay['exercises'])) {
                fail("目标日期 {$toDate} 已有已开始或已完成的训练，不可覆盖。", 409);
            }
            
            $diff = ['from' => $fromDate, 'to' => $toDate, 'exercises' => $fromDay['exercises'] ?? []];
            
            $fromVer = (int)($fromDay['_schedule_version'] ?? 1);
            $toVer = (int)($toDay['_schedule_version'] ?? 1);
            foreach([$fromDate=>$fromVer,$toDate=>$toVer] as $d=>$version)if(!isset($expectedVersions['schedule:'.$d])||(int)$expectedVersions['schedule:'.$d]!==$version)fail('日程版本已变化，请重新预览。',409);
            $beforeVersion = "{$fromVer}:{$toVer}";
            $afterVersion = ($fromVer + 1) . ":" . ($toVer + 1);
            
            // Move exercises
            $state['days'][$toDate]['exercises'] = $fromDay['exercises'] ?? [];
            $state['days'][$toDate]['_schedule_version'] = $toVer + 1;
            $state['days'][$fromDate]['exercises'] = [];
            $state['days'][$fromDate]['_schedule_version'] = $fromVer + 1;
            
            $eventType = 'ScheduleMoved';
            
        } elseif ($type === 'Profile.Update') {
            $aggregateType = 'profile';
            $aggregateId = (string)$uid;
            
            $curProf = $state['profile'] ?? [];
            $newProf = $payload['profile'] ?? [];
            if (!is_array($newProf)) fail('个人资料载荷格式不正确。', 400);
            
            $beforeVersion = (string)($curProf['_profile_version'] ?? 1);
            $afterVer = (int)$beforeVersion + 1;
            $afterVersion = (string)$afterVer;
            
            $diff = ['before' => $curProf, 'after' => $newProf];
            
            $newProf['_profile_version'] = $afterVer;
            $state['profile'] = array_merge($curProf, $newProf);
            
            // Sync profiles table projection (R02 authoritative sync)
            if (isset($newProf['age']) || isset($newProf['weight']) || isset($newProf['height'])) {
                $profile = $state['profile'];
                $gender = mb_substr(trim((string)($profile['gender'] ?? '')), 0, 10);
                $goal = mb_substr(trim((string)($profile['goal'] ?? '')), 0, 30);
                $experience = mb_substr(trim((string)($profile['experience'] ?? '')), 0, 20);
                $venue = mb_substr(trim((string)($profile['venue'] ?? '')), 0, 20);
                $focus = mb_substr(trim((string)($profile['focus'] ?? '')), 0, 100);
                $nickname = mb_substr(trim((string)($profile['nickname'] ?? '成员')), 0, 30) ?: '成员';
                $age = min(100, max(13, (int)($profile['age'] ?? 25)));
                $height = min(250, max(80, (float)($profile['height'] ?? 170)));
                $weight = min(400, max(20, (float)($profile['weight'] ?? 65)));
                $daysPerWeek = min(7, max(1, (int)($profile['daysPerWeek'] ?? 3)));
                // Column names must match schema.sql; the old statement used
                // height/weight and omitted NOT NULL columns, failing every call.
                $db->prepare('INSERT INTO profiles(user_id,nickname,gender,age,height_cm,weight_kg,goal,experience,venue,days_per_week,focus,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE nickname=VALUES(nickname),gender=VALUES(gender),age=VALUES(age),height_cm=VALUES(height_cm),weight_kg=VALUES(weight_kg),goal=VALUES(goal),experience=VALUES(experience),venue=VALUES(venue),days_per_week=VALUES(days_per_week),focus=VALUES(focus),updated_at=UTC_TIMESTAMP()')
                    ->execute([$uid, $nickname, $gender, $age, $height, $weight, $goal, $experience, $venue, $daysPerWeek, $focus]);
            }
            
            $eventType = 'ProfileUpdated';

        } elseif($type==='Training.SessionDiscard'){
            $date=$payload['date'];$session=$payload['session_id'];$day=&$state['days'][$date];
            if(!is_array($day)||strtolower($day['activeWorkoutSessionID']??'')!==$session)fail('活动训练已变化，请重新核对。',409);
            foreach($day['workoutSessions']??[] as &$row)if(strtolower($row['id'])===$session){if(!empty($row['savedAt']))fail('已保存训练不可放弃。',409);$row['cancelledAt']=businessDocumentNow();$row['endedAt']=businessDocumentNow();}unset($row);
            // Persist the cancellation on the actual array (foreach over ?? copies the value).
            foreach($day['workoutSessions'] as $i=>$row)if(strtolower($row['id'])===$session){$day['workoutSessions'][$i]['cancelledAt']=businessDocumentNow();$day['workoutSessions'][$i]['endedAt']=businessDocumentNow();}
            unset($day['activeWorkoutSessionID'],$day['workoutStartedAt'],$day['workoutSavedAt']);$day['workoutEndedAt']=businessDocumentNow();$day['_schedule_version']=(int)($day['_schedule_version']??1)+1;
            trainingActiveRelease($db,$uid,$session);$aggregateType='training';$aggregateId=$date;$beforeVersion=(string)($beforeState['days'][$date]['_schedule_version']??1);$afterVersion=(string)$day['_schedule_version'];$eventType='WorkoutSessionDiscarded.v1';$diff=['date'=>$date,'discarded'=>true,'preserved_recorded_sets'=>true];unset($day);
        } elseif ($type === 'Training.SessionStart') {
            // Phase 1: claim the single active session. A second device/start
            // resumes the existing session instead of creating a parallel one.
            if (!appFeatureEnabled($db, 'training_commands')) fail('训练命令功能尚未开放。', 503);
            $startPayload = trainingStartPayloadValid($payload);
            if ($startPayload === null) fail('训练开始参数不正确。', 400);
            $today = actionToday($db,$uid);
            if ($startPayload['date'] > $today) fail('不能开始未来日期的训练。', 422);
            $startDay = $state['days'][$startPayload['date']] ?? [];
            if (array_filter($startDay['workoutSessions']??[],fn($v)=>strtolower($v['id']??'')===$startPayload['session_id'] && (!empty($v['savedAt'])||!empty($v['cancelledAt'])))) {
                businessReject(409, ['error' => "日期 {$startPayload['date']} 的训练已确认完成，不能重新开始。", 'conflict' => true]);
            }
            $existingActive = trainingActiveFetch($db, $uid);
            if ($existingActive !== null) {
                // 规范 §5.1：已有 IN_PROGRESS 会话 → 原样恢复，不新建。
                trainingRecordAudit($db, $uid, $commandId, $actor, $type, $payloadHash, 'training',
                    $existingActive['session_id'], (string)$currentRevision, (string)$currentRevision,
                    ['resume' => true, 'session_id' => $existingActive['session_id'], 'date' => $existingActive['date_key']], $idempotencyKey);
                $db->commit();
                return [
                    'commandId' => $commandId, 'status' => 'succeeded', 'resume' => true,
                    'session_id' => $existingActive['session_id'], 'date' => $existingActive['date_key'],
                    'revision' => $currentRevision, 'idempotent' => false
                ];
            }
            if (!empty($startDay['workoutStartedAt']) && empty($startDay['workoutSavedAt'])) {
                // Legacy in-document session (started before the claim table):
                // adopt it under its own id instead of forking a second session.
                $legacyID = $startDay['activeWorkoutSessionID'] ?? null;
                if (!trainingSessionIDValid($legacyID)) {
                    businessReject(409, ['error' => '这一天已有进行中训练但缺少会话标识，请在 App 内打开该日训练后重试。', 'conflict' => true]);
                }
                $legacyID = strtolower((string)$legacyID);
                trainingActiveClaim($db, $uid, $legacyID, $startPayload['date']);
                trainingRecordAudit($db, $uid, $commandId, $actor, $type, $payloadHash, 'training',
                    $legacyID, (string)$currentRevision, (string)$currentRevision,
                    ['adopted' => true, 'session_id' => $legacyID, 'date' => $startPayload['date']], $idempotencyKey);
                $db->commit();
                return [
                    'commandId' => $commandId, 'status' => 'succeeded', 'resume' => true,
                    'session_id' => $legacyID, 'date' => $startPayload['date'],
                    'revision' => $currentRevision, 'idempotent' => false
                ];
            }
            trainingActiveClaim($db, $uid, $startPayload['session_id'], $startPayload['date']);
            $started = trainingApplyStart($state, $startPayload, $startPayload['session_id']);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$startPayload['date']], 'day', "days.{$startPayload['date']}");
            $aggregateType = 'training';
            $aggregateId = $startPayload['date'];
            $beforeVersion = (string)($startDay['_schedule_version'] ?? 1);
            $afterVersion = (string)($state['days'][$startPayload['date']]['_schedule_version']);
            $diff = $started;
            $eventType = 'WorkoutSessionStarted.v1';

        } elseif ($type === 'Training.SessionFinish') {
            // Phase 1: apply the session snapshot exactly once and release the
            // claim. A new commandId on an already-saved day is refused; only
            // the original commandId may replay its stored result (handled by
            // the data_operations idempotency check above).
            if (!appFeatureEnabled($db, 'training_commands')) fail('训练命令功能尚未开放。', 503);
            $finishPayload = trainingFinishPayloadValid($payload);
            if ($finishPayload === null) fail('训练完成参数不正确。', 400);
            $existingActive = trainingActiveFetch($db, $uid);
            if ($existingActive !== null && $existingActive['session_id'] !== $finishPayload['session_id']) {
                businessReject(409, [
                    'error' => '其他设备正在进行另一场训练（' . $existingActive['date_key'] . '），请先结束那场训练。',
                    'conflict' => true, 'active_session' => $existingActive
                ]);
            }
            if ($existingActive !== null && $existingActive['date_key'] !== $finishPayload['date']) businessReject(409,['error'=>'会话日期不匹配，请恢复原训练。','conflict'=>true]);
            if ($finishPayload['date'] > actionToday($db,$uid)) fail('不能确认未来日期的训练。',422);
            $finishDay = $state['days'][$finishPayload['date']] ?? [];
            $knownSessions=$finishDay['workoutSessions']??[];
            foreach($knownSessions as $known) if(strtolower($known['id']??'')===$finishPayload['session_id'] && !empty($known['savedAt'])) {
                if($existingActive===null || !trainingFinishFactsMatch130($finishDay,$finishPayload)) businessReject(409,['error'=>'这场训练已保存，请刷新记录。','conflict'=>true]);
                // An active claim means no finish transaction has consumed it.
                // Preserve the saved timestamps; never overwrite existing facts.
                $finishPayload['saved_at']=$known['savedAt'];
                if(isset($known['startedAt']))$finishPayload['started_at']=$known['startedAt'];
                if(isset($known['endedAt']))$finishPayload['ended_at']=$known['endedAt'];
            }
            if (!empty($finishDay['workoutSavedAt']) && empty($finishDay['workoutSessions'])) {
                businessReject(409, ['error' => "日期 {$finishPayload['date']} 的训练已确认完成，不能重复确认。", 'conflict' => true]);
            }
            $finished = trainingApplyFinish($state, $finishPayload);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$finishPayload['date']], 'day', "days.{$finishPayload['date']}");
            if ($existingActive !== null) trainingActiveRelease($db, $uid, $existingActive['session_id']);
            $aggregateType = 'training';
            $aggregateId = $finishPayload['date'];
            $beforeVersion = (string)($finishDay['_schedule_version'] ?? 1);
            $afterVersion = (string)($state['days'][$finishPayload['date']]['_schedule_version']);
            $diff = $finished;
            $eventType = 'WorkoutSessionFinished.v1';

        } elseif (in_array($type,['Training.LogSet','Training.CorrectSet'],true)) {
            $correction=$type==='Training.CorrectSet';
            if($correction&&$actor!=='user')fail('历史修正需要用户明确操作。',403);
            // Phase 1: incremental set logging into the claimed active session.
            if (!appFeatureEnabled($db, 'training_commands')) fail('训练命令功能尚未开放。', 503);
            $logPayload = trainingLogSetPayloadValid($payload);
            if ($logPayload === null) fail('训练组参数不正确。', 400);
            $existingActive = trainingActiveFetch($db, $uid);
            if (!$correction && ($existingActive === null || $existingActive['session_id'] !== $logPayload['session_id'] || $existingActive['date_key']!==$logPayload['date'])) {
                businessReject(409, ['error' => '没有进行中的训练会话，或会话已在其他设备变化。', 'conflict' => true]);
            }
            $logDay = $state['days'][$logPayload['date']] ?? [];
            if (!$correction && (!empty($logDay['workoutSavedAt']) || !empty($logDay['training_confirmed']))) {
                businessReject(409, ['error' => "日期 {$logPayload['date']} 的训练已确认完成，不能修改组数。", 'conflict' => true]);
            }
            if (strtolower((string)($logDay['activeWorkoutSessionID'] ?? '')) !== $logPayload['session_id']) {
                businessReject(409, ['error' => '当天的活动训练会话已变化，请重新打开训练。', 'conflict' => true]);
            }
            foreach($logDay['exercises']??[] as $e)foreach($e['sets']??[] as $set)if(strtolower($e['id'])===$logPayload['exercise_id']&&strtolower($set['id'])===$logPayload['set']['id']&&isset($payload['expected_set'])){
                foreach(['weight','reps','completed','durationSeconds'] as $k)if(($set[$k]??null)!=($payload['expected_set'][$k]??null)&&($set[$k]??null)!=($logPayload['set'][$k]??null))businessReject(409,['error'=>'这组已在其他设备修改，请重新核对。','conflict'=>true]);
            }
            $previousSet=null;foreach($logDay['exercises']??[] as $e)if(strtolower($e['id'])===$logPayload['exercise_id'])foreach($e['sets'] as $set)if(strtolower($set['id'])===$logPayload['set']['id'])$previousSet=$set;
            if($correction&&$previousSet&&$previousSet['completed']!==$logPayload['set']['completed'])fail('已确认场次的完成事实不能切换；可在明确勘误中修正数值。',409);
            $logged = trainingApplyLogSet($state, $logPayload);
            if ($logged === null) fail('动作不在当天的训练安排中。', 422);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$logPayload['date']], 'day', "days.{$logPayload['date']}");
            $aggregateType = 'training';
            $aggregateId = $logPayload['date'];
            $beforeVersion = (string)($logDay['_schedule_version'] ?? 1);
            $afterVersion = (string)($state['days'][$logPayload['date']]['_schedule_version']);
            $diff = $logged;
            if($correction)$diff += ['before'=>$previousSet,'after'=>$logPayload['set'],'reason'=>'explicit_user_numeric_correction'];
            $eventType = $correction?'WorkoutSetCorrected.v1':'WorkoutSetLogged.v1';

        } elseif ($type === 'BodyWeight.CreateDirect') {
            // Phase 1: low-risk direct record (no proposal round-trip). The
            // operation-level idempotency was already enforced above.
            if (!appFeatureEnabled($db, 'direct_records')) fail('直接记录功能尚未开放。', 503);
            $weightPayload = trainingDirectWeightPayloadValid($payload);
            if ($weightPayload === null) fail('体重记录参数不正确。', 400);
            if($weightPayload['date']>actionToday($db,$uid))fail('不能登记未来测量。',422);
            $weightDay = $state['days'][$weightPayload['date']] ?? [];
            $weightPayload['measurement_id']=$weightPayload['measurement_id']??actionUUID('weight/'.$uid.'/'.$commandId);
            $undoJson = json_encode(['date' => $weightPayload['date'],
                                     'measurement_id' => $weightPayload['measurement_id']], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            $recorded = trainingApplyDirectWeight($state, $weightPayload);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$weightPayload['date']], 'day', "days.{$weightPayload['date']}");
            $aggregateType = 'body';
            $aggregateId = $weightPayload['date'];
            $beforeVersion = (string)($weightDay['_body_version'] ?? 1);
            $afterVersion = (string)($state['days'][$weightPayload['date']]['_body_version']);
            $diff = $recorded;
            $eventType = 'BodyWeightRecorded';

        } elseif ($type === 'Meal.CreateDirect') {
            // Phase 1: direct meal record; client entry ids make re-application
            // convergent (a retry never produces a second meal).
            if (!appFeatureEnabled($db, 'direct_records')) fail('直接记录功能尚未开放。', 503);
            $mealPayload = trainingDirectMealPayloadValid($payload);
            if ($mealPayload === null) fail('饮食记录参数不正确。', 400);
            if($mealPayload['date']>actionToday($db,$uid))fail('不能登记未来饮食。',422);
            $mealDay = $state['days'][$mealPayload['date']] ?? [];
            $mealDiff = trainingApplyDirectMeal($state, $mealPayload, $commandId);
            $written=[];foreach($state['days'][$mealPayload['date']]['meals'] as $m)if(in_array(strtolower($m['id']),$mealDiff['appended_ids']??[],true))$written[$m['id']]=$m;
            $undoJson = json_encode(['date' => $mealPayload['date'],
                                     'written_meals'=>$written,'removed_meal_ids' => $mealDiff['appended_ids'] ?? []], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$mealPayload['date']], 'day', "days.{$mealPayload['date']}");
            $aggregateType = 'meals';
            $aggregateId = $mealPayload['date'];
            $beforeVersion = (string)($mealDay['_meal_version'] ?? 1);
            $afterVersion = (string)($state['days'][$mealPayload['date']]['_meal_version']);
            $diff = $mealDiff;
            $eventType = 'MealCreated';

        } elseif ($type === 'ExerciseSwap.Confirm') {
            // Phase 2: single-occurrence exercise swap (spec §5.4). The proposal
            // payload is bound to the day fingerprint captured at preview.
            if ($proposalKind !== 'exercise_swap') fail('提案类型与命令不匹配。', 400);
            $swapDate = (string)$proposalPayload['date'];
            $swapDay = $state['days'][$swapDate] ?? [];
            if (businessDayProtected($swapDay)) {
                businessReject(409, ['error' => "日期 {$swapDate} 的训练已开始或已完成，受保护不可替换。", 'conflict' => true]);
            }
            $versionsMatch = !empty($proposalPayload['_expected_days']) ;
            foreach ($proposalPayload['_expected_days'] ?? [] as $date => $hash) {
                if (!hash_equals($hash, businessDayFingerprint($state['days'][$date] ?? []))) $versionsMatch = false;
            }
            if (!$versionsMatch) {
                $db->rollBack();
                $db->prepare("UPDATE ai_action_proposals SET status='conflict',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=? AND status='awaiting_confirmation'")
                    ->execute([$uid, $proposalId]);
                businessReject(409, ['error' => '安排与提案预览时已发生变化，请重新预览。', 'conflict' => true, 'proposalId' => $proposalId]);
            }
            $deleted = $state['deletedExerciseIDs'] ?? [];
            $sessionID = strtoupper(commandUUID());
            $copies = [];
            foreach ($proposalPayload['exercises'] as $planned) {
                $exercise = ['id' => strtoupper(commandUUID()), 'name' => $planned['name'], 'muscle' => $planned['muscle'],
                             'sets' => array_map(fn($set) => array_merge($set, ['id' => strtoupper(commandUUID()), 'weight' => (float)($set['weight'] ?? 0), 'completed' => false]), $planned['sets'])];
                $exercise += array_filter(['libraryID'=>$planned['library_id']??null,'libraryQuery'=>$planned['library_query']??null,'customExerciseID'=>$planned['custom_id']??null,'customUnit'=>$planned['custom_unit']??null,'restSeconds'=>$planned['rest_seconds']??null],fn($v)=>$v!==null);
                $copies[] = $exercise;
            }
            foreach ($copies as &$exercise) $exercise['workoutSessionID'] = $sessionID; unset($exercise);
            foreach ($swapDay['exercises'] ?? [] as $old) if (isset($old['id'])) $deleted[] = $old['id'];
            $state['days'][$swapDate] = array_merge(['meals' => []], $swapDay, [
                'exercises' => $copies, 'workoutSessions' => [['id' => $sessionID]], 'activeWorkoutSessionID' => $sessionID,
                '_schedule_version' => (int)($swapDay['_schedule_version'] ?? 1) + 1,
            ]);
            unset($state['days'][$swapDate]['workoutStartedAt'], $state['days'][$swapDate]['workoutEndedAt'], $state['days'][$swapDate]['workoutSavedAt']);
            $state['deletedExerciseIDs'] = array_values(array_unique($deleted));
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$swapDate], 'day', "days.{$swapDate}");
            $aggregateType = 'schedule';
            $aggregateId = $swapDate;
            $beforeVersion = (string)($swapDay['_schedule_version'] ?? 1);
            $afterVersion = (string)($state['days'][$swapDate]['_schedule_version']);
            $diff = ['date' => $swapDate, 'scope' => 'single_occurrence',
                     'before_exercises' => array_column($swapDay['exercises'] ?? [], 'name'),
                     'after_exercises' => array_column($copies, 'name')];
            $eventType = 'WorkoutOccurrenceChanged.v1';

        } elseif ($type === 'PlanVersion.Activate') {
            // Phase 2: activate a candidate plan version (spec §5.8). Only
            // future, unprotected days are written; finished history is never
            // touched or moved.
            if ($proposalKind !== 'plan_activation') fail('提案类型与命令不匹配。', 400);
            $versionsMatch = !empty($proposalPayload['_expected_days']) ;
            foreach ($proposalPayload['_expected_days'] ?? [] as $date => $hash) {
                if (!hash_equals($hash, businessDayFingerprint($state['days'][$date] ?? []))) $versionsMatch = false;
            }
            if (!$versionsMatch) {
                $db->rollBack();
                $db->prepare("UPDATE ai_action_proposals SET status='conflict',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=? AND status='awaiting_confirmation'")
                    ->execute([$uid, $proposalId]);
                businessReject(409, ['error' => '安排与提案预览时已发生变化，请重新预览。', 'conflict' => true, 'proposalId' => $proposalId]);
            }
            $compensation = isset($proposalPayload['compensates']) ? actionValidatePlanCompensation($db,$uid,$state,$proposalPayload) : null;
            $memoryBefore = actionCompMemories($db,$uid);
            $todayServer = actionToday($db,$uid);
            $applied = [];
            foreach ($proposalPayload['sessions'] as $session) {
                $date = (string)$session['date'];
                $day = $state['days'][$date] ?? [];
                if ($date < $todayServer || businessDayProtected($day)) {
                    businessReject(409, ['error' => "日期 {$date} 已过去或训练已开始/完成，不能启用新计划。", 'conflict' => true]);
                }
                $sessionID = strtoupper(commandUUID());
                $copies = [];
                foreach ($session['exercises'] as $planned) {
                    $copies[] = ['id' => strtoupper(commandUUID()), 'name' => $planned['name'], 'muscle' => $planned['muscle'],
                                 'sets' => array_map(fn($set) => array_merge($set, ['id' => strtoupper(commandUUID()), 'weight' => (float)($set['weight'] ?? 0), 'completed' => false]), $planned['sets']),
                                 'workoutSessionID' => $sessionID,'planID'=>'action-plan-'.$proposalPayload['draft_id'],'libraryID'=>$planned['library_id']??null,'libraryQuery'=>$planned['library_query']??null,'customExerciseID'=>$planned['custom_id']??null,'customUnit'=>$planned['custom_unit']??null,'restSeconds'=>$planned['rest_seconds']??null];
                }
                $deleted = $state['deletedExerciseIDs'] ?? [];
                foreach ($day['exercises'] ?? [] as $old) if (isset($old['id'])) $deleted[] = $old['id'];
                $state['days'][$date] = array_merge(['meals' => []], $day, [
                    'exercises' => $copies, 'workoutSessions' => [['id' => $sessionID]], 'activeWorkoutSessionID' => $sessionID,
                    '_schedule_version' => (int)($day['_schedule_version'] ?? 1) + 1,
                ]);
                if(!$copies){$state['days'][$date]['workoutSessions']=[];unset($state['days'][$date]['activeWorkoutSessionID']);}
                unset($state['days'][$date]['workoutStartedAt'], $state['days'][$date]['workoutEndedAt'], $state['days'][$date]['workoutSavedAt']);
                $state['deletedExerciseIDs'] = array_values(array_unique($deleted));
                $applied[] = $date;
            }
            foreach ($applied as $date) cloudValidate($state['days'][$date], 'day', "days.{$date}");
            $aggregateType = 'plan';
            $aggregateId = (string)$proposalPayload['draft_id'];
            $beforeVersion = (string)$currentRevision;
            $afterVersion = (string)($currentRevision + 1);
            $diff = ['draft_id' => $proposalPayload['draft_id'], 'applied_dates' => $applied,
                     'sessions' => array_map(fn($s) => ['date' => $s['date'], 'label' => $s['label'],
                                                      'exercises' => array_column($s['exercises'], 'name')], $proposalPayload['sessions'])];
            actionRecordPlanVersion($state,$beforeState,$proposalPayload,$proposalId,$applied);
            if(isset($proposalPayload['recurring_weekday']))actionRememberRecurringPlan($db,$uid,$proposalPayload,$proposalId,$currentRevision+1);
            if($compensation!==null){actionApplyPlanCompensation($db,$uid,$state,$compensation,$proposalId,$currentRevision+1);$diff['compensates']=$proposalPayload['compensates'];}
            $undoJson=json_encode(actionCapturePlanInverse($db,$uid,$beforeState,$state,$applied,$memoryBefore),JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
            $eventType = 'TrainingPlanActivated.v1';
        }
        

        if ($type === 'PlanReschedule.Confirm') {
            if ($proposalKind !== 'plan_change_proposal') fail('提案类型与命令不匹配。', 400);
            $moves = $proposalPayload['moves'] ?? [];
            $versionsMatch = !empty($proposalPayload['_expected_days']) ;
            if (isset($proposalPayload['_expected_revision']) && (int)$proposalPayload['_expected_revision'] !== $currentRevision) $versionsMatch = false;
            foreach ($proposalPayload['_expected_days'] ?? [] as $date => $hash) {
                if (!hash_equals($hash, businessDayFingerprint($state['days'][$date] ?? []))) $versionsMatch = false;
            }
            if (!$versionsMatch || !aiProposalMovesMatchDocument($state, $moves, actionToday($db,$uid))) {
                $db->rollBack();
                $db->prepare("UPDATE ai_action_proposals SET status='conflict',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=? AND status='awaiting_confirmation'")
                    ->execute([$uid, $proposalId]);
                businessReject(409, ['error' => '日程与提案预览时已发生变化，请重新发起提案。', 'conflict' => true, 'proposalId' => $proposalId]);
            }
            $aggregateId = $proposalId;
            $diff = ['moves' => $moves];
            $beforeVersions = [];
            $afterVersions = [];
            foreach ($moves as $move) {
                $from = $move['from']; $to = $move['to'];
                $beforeVersions[] = "$from:" . (int)($state['days'][$from]['_schedule_version'] ?? 1);
                $afterVersions[] = "$to:" . ((int)($state['days'][$to]['_schedule_version'] ?? 1) + 1);
            }
            businessMoveSchedule($state, $moves, $proposalId);
            // Bind future compensation to the exact entities and versions produced.
            foreach (aiProposalScopeDates('plan_change_proposal', $proposalPayload) as $date) {
                $diff['after_day_fingerprints'][$date] = businessDayFingerprint($state['days'][$date] ?? []);
            }
            if (isset($proposalPayload['compensates'])) $diff['compensates'] = $proposalPayload['compensates'];
            require_once __DIR__ . '/cloud-validation.php';
            foreach ($state['days'] as $date => $day) {
                if (($beforeState['days'][$date] ?? null) != $day) cloudValidate($day, 'day', "days.$date");
            }
            $beforeVersion = (string)$currentRevision;
            $afterVersion = (string)($currentRevision + 1);
            $diff['before_day_versions'] = $beforeVersions;
            $diff['after_day_versions'] = $afterVersions;
            $eventType = 'PlanRescheduled';

        } elseif ($type === 'Meal.Create') {
            if ($proposalKind !== 'meal_draft') fail('提案类型与命令不匹配。', 400);
            $aggregateType = 'meals';
            $date = (string)$proposalPayload['date'];
            if ($date > actionToday($db, $uid)) fail('不能登记未来饮食。', 422);
            $aggregateId = $date;
            $beforeVersion = (string)($state['days'][$date]['_meal_version'] ?? 1);
            $newMeals = [];
            foreach ($proposalPayload['meals'] as $mealIndex => $meal) {
                $newMeals[] = [
                    'id' => actionUUID('meal/'.$uid.'/'.$commandId.'/'.$mealIndex),
                    'name' => $meal['name'],
                    'category' => $meal['category'],
                    'calories' => (float)($meal['calories'] ?? 0),
                    'protein' => (float)($meal['protein'] ?? 0),
                    'carbs' => (float)($meal['carbs'] ?? 0),
                    'fat' => (float)($meal['fat'] ?? 0),
                    'sourceAIJobID' => count($proposalPayload['meals'])>1 ? $proposalId.'#'.$mealIndex : $proposalId,
                    'estimated' => $meal['estimated']??true,
                    'portion' => $meal['portion']??null,
                    'recognitionConfidence' => $meal['confidence']??null,
                    'nutritionKnown' => isset($meal['calories']) || isset($meal['protein']) || isset($meal['carbs']) || isset($meal['fat']),
                    'components' => is_array($meal['components'] ?? null) ? $meal['components'] : null,
                    'requiresReview' => !empty($meal['requiresReview']),
                    'nutritionSources' => is_array($meal['nutritionSources'] ?? null) ? $meal['nutritionSources'] : null,
                ];
            }
            // 'exercises' is required by the day schema even for meal-only days.
            if (!isset($state['days'][$date]) || !is_array($state['days'][$date])) $state['days'][$date] = ['exercises' => [], 'meals' => []];
            if (!isset($state['days'][$date]['exercises']) || !is_array($state['days'][$date]['exercises'])) $state['days'][$date]['exercises'] = [];
            $state['days'][$date]['meals'] = array_values(array_merge(is_array($state['days'][$date]['meals'] ?? null) ? $state['days'][$date]['meals'] : [], $newMeals));
            // The written day must still satisfy the Swift Codable contract.
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$date], 'day', "days.{$date}");
            $afterVer = $beforeVersion + 1;
            $state['days'][$date]['_meal_version'] = $afterVer;
            $afterVersion = (string)$afterVer;
            $inverse=[];foreach($newMeals as $m)$inverse[$m['id']]=$m;
            $undoJson=json_encode(['date'=>$date,'removed_meal_ids'=>array_map(fn($m)=>strtolower($m['id']),$newMeals),'written_meals'=>$inverse]);
            $diff = ['date' => $date, 'added' => count($newMeals), 'written_meals' => $newMeals];
            $eventType = 'MealCreated';

        } elseif ($type === 'BodyWeight.Create') {
            if ($proposalKind !== 'weight_entry') fail('提案类型与命令不匹配。', 400);
            $aggregateType = 'body';
            $date = (string)$proposalPayload['date'];
            if ($date > actionToday($db, $uid)) fail('不能登记未来测量。', 422);
            $aggregateId = $date;
            $beforeVersion = (string)($state['days'][$date]['_body_version'] ?? 1);
            $proposalPayload['measurement_id']=actionUUID('weight/'.$uid.'/'.$commandId);
            $undoJson=json_encode(['date'=>$date,'measurement_id'=>$proposalPayload['measurement_id']]);
            trainingApplyDirectWeight($state,$proposalPayload);
            require_once __DIR__ . '/cloud-validation.php';
            cloudValidate($state['days'][$date], 'day', "days.{$date}");
            $afterVer = $beforeVersion + 1;
            $state['days'][$date]['_body_version'] = $afterVer;
            $afterVersion = (string)$afterVer;
            $diff = ['date' => $date, 'kilograms' => (float)$proposalPayload['kilograms']];
            $eventType = 'BodyWeightRecorded';
        }

        if(str_starts_with($type,'BodyWeight.') && isset($diff['date'],$state['days'][$diff['date']])) {
            $diff['written_body_measurements']=$state['days'][$diff['date']]['bodyMeasurements']??[];
        }
        foreach($state['days']??[] as $date=>$day)actionValidateTrainingFacts($beforeState['days'][$date]??[],$day);
        // 4. Update app_states revision
        $newRevision = $currentRevision + 1;
        businessStateWrite($db, $uid, $state, $beforeState, $partitioned, $newRevision);

        // 5. Audit in data_operations
        $undoJson ??= null;
        $db->prepare('INSERT INTO data_operations(operation_id,user_id,actor,command_type,payload_hash,idempotency_key,trace_id,aggregate_type,aggregate_id,before_version,after_version,diff_json,undo_json,status,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,"succeeded",UTC_TIMESTAMP())')
            ->execute([
                $commandId, $uid, $actor, $type, $payloadHash, $idempotencyKey,
                $GLOBALS['boji_trace_id'] ?? null,
                $aggregateType, $aggregateId, $beforeVersion, $afterVersion,
                json_encode($diff, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $undoJson
            ]);
            
        // 5b. Proposal lifecycle: succeeded + execution ledger (same transaction).
        if (is_array($proposalRow)) {
            aiProposalMarkExecution($db, (int)$proposalRow['id'], $uid, $commandId,
                (string)$proposalRow['idempotency_key'], 'succeeded', ['type' => $type, 'version' => $afterVersion]);
            if($type==='Training.SessionDiscard')$db->prepare("UPDATE ai_action_proposals SET status='cancelled',updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$proposalRow['id']]);
        }

        // 6. Transactional Outbox (domain_outbox)
        $eventId = commandUUID();
        $outboxPayload = [
            'commandId' => $commandId,
            'type' => $type,
            'aggregateType' => $aggregateType,
            'aggregateId' => $aggregateId,
            'version' => $afterVersion,
            'revision' => $newRevision,
            'diff' => $diff
        ];
        $db->prepare('INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,trace_id,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,"pending",0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())')
            ->execute([
                $eventId, $commandId, $uid, $aggregateType, $aggregateId,
                $newRevision, $GLOBALS['boji_trace_id'] ?? null, $eventType,
                json_encode($outboxPayload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)
            ]);
            
        $db->commit();
        
        return [
            'commandId' => $commandId,
            'status' => 'succeeded',
            'version' => $afterVersion,
            'revision' => $newRevision,
            'diff' => $diff
        ];
    } catch (Throwable $e) {
        if ($db->inTransaction()) $db->rollBack();
        throw $e;
    }
}
