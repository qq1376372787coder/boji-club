<?php
declare(strict_types=1);

/**
 * Phase 2: AI Intent Router — the five processing modes (spec §3, §5).
 *
 * POST /me/ai/resolve takes a batch of capability calls (requested by the
 * model through the whitelist, or relayed by the client from an AI card) and
 * routes each one by its registry mode:
 *
 *   read_only   execute immediately from the authoritative document
 *   advisory    compute facts + an AdviceCard; NEVER writes (spec §5.7)
 *   direct      low-risk write through the Domain Command service
 *               (gated; when the gate is closed it degrades to preview)
 *   preview     create an awaiting_confirmation proposal; nothing is written
 *               before an explicit confirm (spec §3.3)
 *   async       queue an ai_user_jobs job; 202 + execution id only
 *               (never claim business completion, spec §6)
 *
 * The router never lets a payload skip validation: capabilityCallValid checks
 * the registry schema, each mode re-checks preconditions and live state, and
 * every write still goes through commands.php (single authoritative entry).
 */

require_once __DIR__ . '/capability-registry.php';
require_once __DIR__.'/fast-intent.php';
require_once __DIR__.'/ai-response.php';
require_once __DIR__.'/ai-entitlements.php';
require_once __DIR__ . '/ai-proposals.php';
require_once __DIR__ . '/commands.php';
require_once __DIR__ . '/business-state.php';
require_once __DIR__ . '/action-execution.php';
require_once __DIR__ . '/action-plans.php';
require_once __DIR__ . '/action-jobs.php';
require_once __DIR__ . '/domain-consumers.php';
require_once __DIR__ . '/engine-proxy.php';

/** Load the affected document window for a read/advisory computation. */
function aiRouterState(PDO $db, int $uid, array $dates): array {
    $q = $db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=?');
    $q->execute([$uid]);
    $row = $q->fetch(PDO::FETCH_ASSOC);
    if (!$row) return ['revision' => 0, 'state' => []];
    if(count($dates)===2){$range=[];for($d=new DateTimeImmutable(min($dates));$d->format('Y-m-d')<=max($dates);$d=$d->modify('+1 day'))$range[]=$d->format('Y-m-d');$dates=$range;}
    $state = businessStateRead($db, $uid, json_decode((string)$row['state_json'], true), $dates);
    return ['revision' => (int)$row['revision'], 'state' => is_array($state) ? $state : []];
}

function aiRouterToday(): string {
    return (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
}

/**
 * Complete the card envelope so the iOS client can decode it directly
 * (card_id / schema_version / created_at / expires_at).
 */
function aiRouterCard(array $card, string $seed, ?string $expiresAt = null): array {
    $now = new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai'));
    $expires = $expiresAt ? actionISO($expiresAt) : $now->modify('+1 day')->format('Y-m-d\TH:i:sP');
    return array_merge([
        'card_id' => 'card-' . substr(hash('sha256', $seed), 0, 20),
        'schema_version' => 1,
        'created_at' => $now->format('Y-m-d\TH:i:sP'),
        'expires_at' => $expires,
        'actions' => [],
        'evidence_refs' => [],
    ], $card);
}

/** Read-only capability executors. Return [data, card?]. */
function aiRouterRead(PDO $db, array $user, string $capability, array $input): array {
    $uid = (int)$user['id'];
    $today = actionToday($db,$uid);
    if ($capability === 'nutrition.lookup_food') {
        $response = engineRequest($GLOBALS['config'] ?? [], '/v1/nutrition/search', ['query'=>$input['query'], 'limit'=>8]);
        if (!is_array($response['result'] ?? null)) fail('营养参考库暂不可用，请稍后再试；不会编造来源。',503);
        return ['data'=>$response['result'], 'card'=>null, 'revision'=>0];
    }
    if ($capability === 'training.get_today') {
        $date = is_string($input['date'] ?? null) && preg_match('/^\d{4}-\d{2}-\d{2}$/D', $input['date']) ? $input['date'] : $today;
        $loaded = aiRouterState($db, $uid, [$date]);
        $day = $loaded['state']['days'][$date] ?? [];
        $exercises = is_array($day['exercises'] ?? null) ? $day['exercises'] : [];
        $totalSets = array_sum(array_map(fn($ex) => count($ex['sets'] ?? []), $exercises));
        $completed = 0;
        foreach ($exercises as $ex) foreach ($ex['sets'] ?? [] as $set) if (!empty($set['completed'])) $completed++;
        $data = [
            'date' => $date,
            'exercise_count' => count($exercises),
            'total_sets' => $totalSets,
            'completed_sets' => $completed,
            'started' => !empty($day['workoutStartedAt']),
            'saved' => !empty($day['workoutSavedAt']),
            'active_session_id' => is_string($day['activeWorkoutSessionID'] ?? null) ? strtolower($day['activeWorkoutSessionID']) : null,
            'empty' => $exercises === [],
        ];
        $card = null;
        if ($exercises === []) {
            $card = aiRouterCard(['card_type' => 'today_training', 'title' => '今日训练',
                     'payload' => ['date' => $date, 'empty' => true, 'reason' => 'no_planned_session',
                                   'hint' => '今天没有已安排的训练。可以安排一次，或把今天留给恢复。']],
                     'today/' . $uid . '/' . $date);
        } else {
            $card = aiRouterCard(['card_type' => 'today_training', 'title' => '今日训练',
                     'payload' => ['date' => $date, 'display_name' => '今日训练安排', 'exercise_count' => count($exercises),
                                   'total_sets' => $totalSets, 'completed_sets' => $completed,
                                   'estimated_minutes' => max(15, min(150, $totalSets * 3)),
                                   'started' => !empty($day['workoutStartedAt']), 'saved' => !empty($day['workoutSavedAt'])]],
                     'today/' . $uid . '/' . $date);
        }
        return ['data' => $data, 'card' => $card, 'revision' => $loaded['revision']];
    }
    if ($capability === 'training.get_history') {
        $days = max(1, min(28, (int)($input['days'] ?? 14)));
        $start = (new DateTimeImmutable($today))->modify('-' . ($days - 1) . ' days')->format('Y-m-d');
        $loaded = aiRouterState($db, $uid, [$start, $today]);
        $rows = [];
        foreach (($loaded['state']['days'] ?? []) as $date => $day) {
            if (!is_array($day) || $date < $start || $date > $today) continue;
            $sets = 0; $movements=[];
            foreach ($day['exercises'] ?? [] as $ex) {
                if(isset($input['exercise_name']) && mb_stripos($ex['name']??'',trim($input['exercise_name']))===false)continue;
                $actual=[];foreach($ex['sets']??[] as $index=>$set)if(!empty($set['completed'])) {
                    $sets++;$actual[]=['set_number'=>$index+1,'weight'=>$set['weight']??0,'reps'=>$set['reps']??0,'duration_seconds'=>$set['durationSeconds']??null];
                }
                if($actual)$movements[]=['name'=>$ex['name'],'unit'=>$ex['customUnit']??'次','library_id'=>$ex['libraryID']??null,'sets'=>$actual];
            }
            $sessions = 0;
            foreach ($day['workoutSessions'] ?? [] as $session) if (!empty($session['savedAt'])) $sessions++;
            if ($sets || ($sessions && !isset($input['exercise_name']))) $rows[] = ['date' => $date, 'sets' => $sets, 'sessions' => $sessions,'movements'=>$movements];
        }
        $data = ['window_start' => $start, 'window_end' => $today, 'training_days' => count($rows),
                 'completed_sets' => array_sum(array_column($rows, 'sets')),
                 'confirmed_sessions' => array_sum(array_column($rows, 'sessions')), 'days' => $rows];
        $card = aiRouterCard(['card_type' => 'training_progress', 'title' => '近期训练进度',
                 'payload' => $data + ['empty' => $rows === []]], 'progress/' . $uid . '/' . $start);
        return ['data' => $data, 'card' => $card, 'revision' => $loaded['revision']];
    }
    if ($capability === 'club.get_progress') {
        require_once __DIR__ . '/club-progress.php';
        $season = $db->prepare("SELECT * FROM club_seasons WHERE status='published' AND starts_on<=? AND ends_on>=? ORDER BY starts_on DESC,id DESC LIMIT 1");
        $season->execute([$today, $today]);
        $seasonRow = $season->fetch(PDO::FETCH_ASSOC);
        if (!$seasonRow) return ['data' => ['season' => null], 'card' => null, 'revision' => 0];
        $progress = clubProgress($db, $uid, $seasonRow);
        $tasks = $db->prepare('SELECT title,metric,target FROM club_tasks WHERE season_id=? ORDER BY sort_order,id');
        $tasks->execute([(int)$seasonRow['id']]);
        $requirements = [];
        foreach ($tasks->fetchAll(PDO::FETCH_ASSOC) as $task) {
            $requirements[] = ['title' => $task['title'], 'metric' => $task['metric'], 'target' => (int)$task['target'],
                               'current' => (int)($progress[$task['metric']] ?? 0)];
        }
        $data = ['season' => ['title' => $seasonRow['title'], 'slug' => $seasonRow['slug']], 'requirements' => $requirements];
        $card = aiRouterCard(['card_type' => 'club_progress', 'title' => '成长季进度',
                 'payload' => ['season_title' => $seasonRow['title'], 'requirements' => $requirements]],
                 'club/' . $uid . '/' . $seasonRow['id']);
        return ['data' => $data, 'card' => $card, 'revision' => 0];
    }
    if ($capability === 'action.get_status') {
        return aiRouterActionStatus($db, $uid, (string)($input['execution_id'] ?? ''));
    }
    return ['data' => [], 'card' => null, 'revision' => 0];
}

/**
 * Advisory mode (spec §5.7): deterministic facts + an AdviceCard. Never
 * mutates the schedule; no invented recovery score.
 */
function aiRouterAdvice(PDO $db, array $user, array $input=[]): array {
    $uid = (int)$user['id'];
    $today = actionToday($db,$uid);
    $start = (new DateTimeImmutable($today))->modify('-6 days')->format('Y-m-d');
    $loaded = aiRouterState($db, $uid, [$start, $today]);
    $profile=$loaded['state']['profile']??[];$age=$profile['age']??null;
    $generalOnly=!is_numeric($age)||(float)$age<18||(($profile['nutritionContext']??'普通成人')!=='普通成人')||!empty($loaded['state']['nutritionTarget']['generalGuidanceOnly']);
    $days = [];
    foreach (($loaded['state']['days'] ?? []) as $date => $day) {
        if (!is_array($day) || $date < $start || $date > $today) continue;
        $sets = 0;
        foreach ($day['exercises'] ?? [] as $ex) foreach ($ex['sets'] ?? [] as $set) if (!empty($set['completed'])) $sets++;
        $days[] = ['date' => $date, 'completed_sets' => $sets,
                   'saved' => !empty($day['workoutSavedAt']), 'started' => !empty($day['workoutStartedAt'])];
    }
    $recentSets = array_sum(array_column($days, 'completed_sets'));
    // Coverage is confirmed training facts, not the number of date rows the
    // client happened to sync. A saved session also counts as a training day.
    $trainingRows = array_values(array_filter($days, fn($row) => $row['completed_sets'] > 0 || !empty($row['saved'])));
    $trainedRecently = count($trainingRows);
    $lastTraining = $trainingRows === [] ? null : max(array_column($trainingRows, 'date'));
    $freshnessDays = $lastTraining === null ? null
        : max(0, (int)(new DateTimeImmutable($today))->diff(new DateTimeImmutable($lastTraining))->format('%a'));
    $coverage = round(min(1, $trainedRecently / 7), 3);
    $restDays = null;
    $facts = ['window_days' => 7, 'training_days' => $trainedRecently, 'rest_days' => $restDays,
              'observed_days' => $trainedRecently, 'coverage_score' => $coverage,
              'completed_sets' => $recentSets, 'data_freshness_days' => $freshnessDays,
              'today_planned' => false];
    foreach (($loaded['state']['days'][$today]['exercises'] ?? []) as $ex) {
        if (!empty($ex['sets'])) { $facts['today_planned'] = true; break; }
    }
    $question=(string)($input['question']??'');
    // Phase 3: deterministic safety/readiness rules run before any wording.
    // The engine is advisory only; missing/invalid safety assessment asks for clarification.
    $engine = engineRequest($GLOBALS['config'] ?? [], '/v1/fitness/assess', [
        'question' => $question,
        'facts' => [
            'general_guidance_only' => $generalOnly,
            'coverage_score' => $coverage,
            'training_days' => $trainedRecently,
            'completed_sets' => $recentSets,
            'source_record_ids' => array_map(fn($row) => 'day/' . $row['date'], $trainingRows),
            'data_freshness_days' => $freshnessDays,
        ],
    ], 2.0);
    $engineResult = is_array($engine['result'] ?? null) ? $engine['result'] : null;
    if($engineResult===null||!in_array($engineResult['decision']??'',['TRAIN_AS_PLANNED','CONSIDER_MODIFIED','CONSIDER_REST','ASK_FOLLOWUP','SAFETY_ESCALATION'],true)){
        $engineResult=['decision'=>'ASK_FOLLOWUP','triage'=>['level'=>'unknown'],'reasons'=>['当前无法完成安全评估，不据此增加训练负荷；有明显急性不适请先停止训练并寻求医疗评估。'],'auto_apply'=>false,'writes_schedule'=>false];
    }
    if($generalOnly&&($engineResult['decision']??'')!=='SAFETY_ESCALATION'){
        $engineResult=['decision'=>'ASK_FOLLOWUP','triage'=>$engineResult['triage']??['level'=>'unknown'],'reasons'=>['目前资料不足以适用普通成人训练建议；特殊情况需结合专业评估，先核对记录。'],'auto_apply'=>false,'writes_schedule'=>false];
    }
    $options = [];
    if ($engineResult !== null) {
        $decision = (string)($engineResult['decision'] ?? 'ASK_FOLLOWUP');
        $triageLevel = (string)($engineResult['triage']['level'] ?? 'none');
        if ($triageLevel === 'emergency') {
            $options[] = ['choice' => 'medical', 'label' => '先停止训练并寻求医疗评估',
                          'reason' => (string)($engineResult['triage']['advice'] ?? '明显急性不适不适合由训练建议判断。')];
        } elseif ($decision === 'ASK_FOLLOWUP') {
            $options[] = ['choice' => 'clarify', 'label' => '先确认你的感受',
                          'reason' => implode(' ', array_slice($engineResult['reasons'] ?? [], 0, 2))];
        } elseif ($decision === 'CONSIDER_REST') {
            $options[] = ['choice' => 'rest', 'label' => '休息',
                          'reason' => (string)($engineResult['reasons'][0] ?? '恢复同样是计划的一部分。')];
            $options[] = ['choice' => 'reduced', 'label' => '减量',
                          'reason' => '结合当前感受减少训练量；有明显不适时停止，不把固定减量比例当作个人处方。'];
        } elseif ($decision === 'CONSIDER_MODIFIED') {
            $options[] = ['choice' => 'reduced', 'label' => '减量',
                          'reason' => (string)($engineResult['reasons'][0] ?? '减少组数，保留主要动作。')];
            $options[] = ['choice' => 'normal', 'label' => '正常训练',
                          'reason' => '如果主观状态允许，可按原计划训练；不适时随时停止。'];
        } else {
            $options[] = ['choice' => 'normal', 'label' => '正常训练',
                          'reason' => (string)($engineResult['reasons'][0] ?? '近 7 天负荷在常规范围。')];
            $options[] = ['choice' => 'reduced', 'label' => '减量',
                          'reason' => '如果主观疲劳明显，可减少组数，保留主要动作。'];
        }
    }
    $needsInfo=$question==='' || preg_match('/疼|痛|晕|不适|喘|发热|疲|累|难受|心悸/u',$question)===1;
    $emergency = preg_match('/胸痛|胸部.{0,4}(疼|痛|闷)|胸口.{0,4}(疼|痛|闷|紧)|胸闷|喘不过气|喘不上气|呼吸困难|晕厥|晕倒|眼前发黑|剧痛|骨折|发烧|高烧|心悸|心慌/u',$question)===1;
    $severe = preg_match('/严重|非常|极度|剧烈|厉害|无法/u',$question)===1 && preg_match('/疲|累|疼|痛|酸|不适/u',$question)===1;
    if($engineResult === null && $emergency){
       $options[]=['choice'=>'medical','label'=>'先停止训练并寻求医疗评估','reason'=>'明显急性不适不适合由训练建议判断。'];
    } elseif($engineResult === null && $severe){
       $options[]=['choice'=>'clarify','label'=>'先确认你的感受','reason'=>'你描述了明显疲劳或疼痛；请说明持续时间和程度，暂不建议按原计划训练。'];
    } elseif($engineResult === null && $needsInfo){
       $options[]=['choice'=>'clarify','label'=>'先确认你的感受','reason'=>'请说明疲劳程度、持续多久，是否疼痛或有其他不适。记录不能代替你的实际感受，暂不据此建议正常训练。'];
    } elseif ($engineResult === null && $trainedRecently >= 5) {
        $options[] = ['choice' => 'rest', 'label' => '休息', 'reason' => '近 7 天已训练 ' . $trainedRecently . ' 天，恢复同样是计划的一部分。'];
        $options[] = ['choice' => 'reduced', 'label' => '减量', 'reason' => '结合当前感受减少训练量；有明显不适时停止，不把固定减量比例当作个人处方。'];
    } elseif ($engineResult === null && $trainedRecently === 0) {
        $options[] = ['choice' => 'clarify', 'label' => '先补充恢复情况', 'reason' => '近 7 天缺少已确认训练记录，不能据此判断休息充分。请说明睡眠、疲劳及近期训练。'];
    } elseif ($engineResult === null) {
        $options[] = ['choice' => 'normal', 'label' => '正常训练', 'reason' => '近 7 天训练 ' . $trainedRecently . ' 天、共 ' . $recentSets . ' 组，负荷在常规范围。'];
        $options[] = ['choice' => 'reduced', 'label' => '减量', 'reason' => '如果主观疲劳明显，可减少组数，保留主要动作。'];
    }
    $card = aiRouterCard(['card_type' => 'advice', 'title' => '休息 / 减量 / 正常训练',
             'payload' => ['facts' => $facts, 'options' => $options,
                           'engine' => $engineResult === null ? null : [
                               'decision' => $engineResult['decision'] ?? 'ASK_FOLLOWUP',
                               'reasons' => $engineResult['reasons'] ?? [],
                               'triage' => $engineResult['triage'] ?? null,
                               'confidence' => $engineResult['confidence'] ?? 'low',
                               'rule_version' => $engineResult['rule_version'] ?? '',
                               'auto_apply' => false, 'writes_schedule' => false,
                           ],
                           'note' => '以上只依据你已确认的训练记录；不评估疼痛或健康风险，不修改任何安排。']],
             'advice/' . $uid . '/' . $today);
    return ['data' => ['facts' => $facts, 'options' => $options, 'engine' => $engineResult], 'card' => $card, 'revision' => $loaded['revision']];
}

/** Execution/proposal/job status for action.get_status and the card verifier. */
function aiRouterActionStatus(PDO $db, int $uid, string $executionID): array {
    $executionID = strtolower(trim($executionID));
    if ($executionID === '') fail('执行标识不正确。', 400);
    $call=$db->prepare('SELECT result_json,status FROM ai_action_calls WHERE user_id=? AND call_id=?');$call->execute([$uid,$executionID]);$callRow=$call->fetch(PDO::FETCH_ASSOC);
    if($callRow){$result=json_decode((string)$callRow['result_json'],true);return ['data'=>is_array($result)?actionRefreshResult($db,$uid,$result):['status'=>$callRow['status']],'card'=>null,'revision'=>0];}
    $queued=$db->prepare('SELECT status,error_code FROM ai_action_jobs WHERE user_id=? AND execution_id=?');$queued->execute([$uid,$executionID]);$jobRow=$queued->fetch(PDO::FETCH_ASSOC);
    if($jobRow)return ['data'=>['kind'=>'job','status'=>$jobRow['status'],'job_id'=>$executionID,'error'=>$jobRow['error_code']],'card'=>null,'revision'=>0];
    $proposal = aiProposalFetch($db, $uid, $executionID);
    if ($proposal) {
        return ['data' => ['kind' => 'proposal', 'status' => $proposal['status'], 'proposal_id' => $proposal['proposal_id'],
                           'expires_at' => $proposal['expires_at'], 'updated_at' => $proposal['updated_at']],
                'card' => null, 'revision' => 0];
    }
    $op = $db->prepare('SELECT operation_id,command_type,status,after_version,diff_json,created_at FROM data_operations WHERE user_id=? AND operation_id=?');
    $op->execute([$uid, $executionID]);
    $row = $op->fetch(PDO::FETCH_ASSOC);
    if ($row) {
        return ['data' => ['kind' => 'command', 'status' => $row['status'], 'command_id' => $row['operation_id'],
                           'command_type' => $row['command_type'], 'version' => $row['after_version'],
                           'diff' => json_decode((string)$row['diff_json'], true), 'created_at' => $row['created_at']],
                'card' => null, 'revision' => 0];
    }
    $job = $db->prepare('SELECT client_job_id,kind,completed_at,created_at FROM ai_user_jobs WHERE user_id=? AND (client_job_id=? OR server_job_id=?)');
    $job->execute([$uid, $executionID, $executionID]);
    $jobRow = $job->fetch(PDO::FETCH_ASSOC);
    if ($jobRow) {
        return ['data' => ['kind' => 'job', 'status' => $jobRow['completed_at'] !== null ? 'succeeded' : 'running',
                           'job_id' => $jobRow['client_job_id'], 'job_kind' => $jobRow['kind'],
                           'created_at' => $jobRow['created_at']],
                'card' => null, 'revision' => 0];
    }
    fail('执行记录不存在。', 404);
}

/**
 * Direct execution through the Domain Command service. The router synthesizes
 * a stable operation identity per (user, capability, input) so a retried call
 * never double-applies.
 */
function aiRouterDirect(PDO $db, array $user, string $capability, array $input, array $entry): array {
    $uid = (int)$user['id'];
    foreach ($entry['preconditions'] ?? [] as $gate) {
        if (!appFeatureEnabled($db, $gate)) {
            // Gate closed: degrade to the safe preview mode instead of failing.
            return ['degrade' => true];
        }
    }
    $commandType = $entry['command_type'] ?? null;
    if ($commandType === null) {
        if ($capability === 'action.undo') return aiRouterUndo($db, $user, $input);
        fail('该能力暂不支持直接执行。', 409);
    }
    $payload = $input;
    if(in_array($commandType,DIRECT_COMMAND_TYPES,true) && !actionPreferences($db,$uid)['fast_records']) return ['degrade'=>true];
    if (in_array($commandType, ['BodyWeight.CreateDirect', 'Meal.CreateDirect','BodyWeight.Create','Meal.Create'], true)) {
        $operation=$GLOBALS['boji_action_id']??businessUUID();
        $key = hash('sha256', 'action/'.$uid.'/'.$operation);
        $payload['idempotency_key'] = $key;
        if($commandType==='BodyWeight.CreateDirect')$payload['measurement_id']=actionUUID('measurement/'.$uid.'/'.$operation);
        if($commandType==='Meal.CreateDirect')foreach($payload['meals'] as $i=>&$meal){$meal['entry_id']=actionUUID('meal/'.$uid.'/'.$operation.'/'.$i);}unset($meal);
    }
    if ($commandType === 'PlanReschedule.Confirm') {
        // Confirm-mode capability: the payload carries the proposal id only.
        $payload = ['proposalId' => (string)($input['proposal_id'] ?? '')];
    }
    $result = handleBusinessCommandCore($db, $user, [
        'commandId' => $GLOBALS['boji_action_id']??businessUUID(), 'type' => $commandType, 'payload' => $payload, 'actor' => 'ai',
    ]);
    return ['result' => $result];
}

/**
 * action.undo (spec §2): reverse a direct record within a bounded window using
 * the inverse payload captured at write time. Never touches training facts.
 */
function aiRouterUndo(PDO $db, array $user, array $input): array {
    $uid = (int)$user['id'];
    $commandID = strtolower(trim((string)($input['command_id'] ?? '')));
    if (!preg_match('/^[0-9a-f-]{36}$/D', $commandID)) fail('命令标识不正确。', 400);
    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        $q = $db->prepare('SELECT operation_id,command_type,undo_json,created_at FROM data_operations WHERE user_id=? AND operation_id=? FOR UPDATE');
        $q->execute([$uid, $commandID]);
        $row = $q->fetch(PDO::FETCH_ASSOC);
        if (!$row) { $db->rollBack(); fail('执行记录不存在。', 404); }
        if (!in_array($row['command_type'], ['BodyWeight.CreateDirect', 'Meal.CreateDirect','BodyWeight.Create','Meal.Create'], true)) {
            $db->rollBack(); fail('只有直执行记录可以撤销。', 409);
        }
        if (strtotime($row['created_at'] . ' UTC') < time() - 86400) {
            $db->rollBack(); fail('撤销窗口已过（24 小时）。', 409);
        }
        $prior=$db->prepare("SELECT operation_id,after_version FROM data_operations WHERE user_id=? AND command_type='Action.Undo' AND aggregate_id=? LIMIT 1");$prior->execute([$uid,$commandID]);$priorUndo=$prior->fetch(PDO::FETCH_ASSOC);if($priorUndo){$db->commit();return ['result'=>['commandId'=>$priorUndo['operation_id'],'status'=>'succeeded','idempotent'=>true]];}
        $undo = json_decode((string)$row['undo_json'], true);
        if (!is_array($undo)) { $db->rollBack(); fail('这笔记录没有可撤销的内容。', 409); }
        if(!isset($undo['measurement_id']) && in_array($row['command_type'],['BodyWeight.CreateDirect','BodyWeight.Create'],true)){ $db->rollBack();fail('旧记录缺少测量实体标识，请在记录详情中修改。',409);}
        // A command can only be undone once: consume the inverse payload.
        $db->prepare('UPDATE data_operations SET undo_json=NULL WHERE user_id=? AND operation_id=?')
            ->execute([$uid, $commandID]);
        $stateQ = $db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE');
        $stateQ->execute([$uid]);
        $stateRow = $stateQ->fetch(PDO::FETCH_ASSOC);
        $state = businessStateRead($db, $uid, json_decode((string)($stateRow['state_json'] ?? '{}'), true), [$undo['date']]);
        $date = $undo['date'];
        if(in_array($row['command_type'],['BodyWeight.CreateDirect','BodyWeight.Create'],true)){
            $day=&$state['days'][$date];actionMeasurementMigrate($day,$date);
            $day['deletedBodyMeasurementIDs']=array_values(array_unique(array_merge($day['deletedBodyMeasurementIDs']??[],[$undo['measurement_id']])));
            actionMeasurementProject($day);unset($day);
        }else{
            foreach($undo['written_meals']??[] as $id=>$expected){
                foreach($state['days'][$date]['meals']??[] as $current)if(strtolower($current['id'])===strtolower($id)&&$current!=$expected)fail('这餐已修改，请在记录页核对后操作。',409);
            }
            $remove=array_map('strtolower',$undo['removed_meal_ids']??[]);
            $state['days'][$date]['meals']=array_values(array_filter($state['days'][$date]['meals']??[],fn($m)=>!in_array(strtolower($m['id']),$remove,true)));
            $state['deletedMealIDs']=array_values(array_unique(array_merge($state['deletedMealIDs']??[],$remove)));
        }
        $aggregateKey=in_array($row['command_type'],['BodyWeight.CreateDirect','BodyWeight.Create'],true)?'_body_version':'_meal_version';
        $state['days'][$date][$aggregateKey]=(int)($state['days'][$date][$aggregateKey]??1)+1;
        cloudValidate($state['days'][$date], 'day', "days.{$date}");
        $newRevision = (int)($stateRow['revision'] ?? 0) + 1;
        businessStateWrite($db, $uid, $state, businessStateRead($db, $uid, json_decode((string)($stateRow['state_json'] ?? '{}'), true), [$date]), (json_decode((string)($stateRow['state_json']??'{}'),true)['_partitioned']??null)===2, $newRevision);
        $undoCommandID = businessUUID();
        trainingRecordAudit($db, $uid, $undoCommandID, 'user', 'Action.Undo',
            hash('sha256', json_encode(['Action.Undo', ['command_id' => $commandID]], JSON_UNESCAPED_UNICODE)),
            'action', $commandID, (string)($stateRow['revision'] ?? 0), (string)$newRevision,
            ['undone' => $commandID, 'date' => $date], null);
        $db->prepare('INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,trace_id,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,"pending",0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())')
            ->execute([businessUUID(), $undoCommandID, $uid, 'action', $commandID, $newRevision,
                       $GLOBALS['boji_trace_id'] ?? null, 'ActionUndone.v1',
                       json_encode(['commandId' => $undoCommandID, 'undone' => $commandID, 'date' => $date], JSON_UNESCAPED_UNICODE)]);
        $db->commit();
        return ['result' => ['commandId' => $undoCommandID, 'status' => 'succeeded', 'undone' => $commandID, 'revision' => $newRevision]];
    } catch (Throwable $e) {
        if ($db->inTransaction()) $db->rollBack();
        throw $e;
    }
}

/** Route one validated call. Returns the response entry (never throws for rejects). */
function aiRouterRouteOne(PDO $db, array $user, array $call): array {
    $validated = capabilityCallValid($call);
    if ($validated === null) {
        return ['capability' => is_string($call['capability'] ?? null) ? $call['capability'] : null,
                'status' => 'rejected', 'error' => '能力调用未通过注册表校验。'];
    }
    $GLOBALS['boji_action_id']=$call['_action_id']??businessUUID();
    $capability = $validated['capability'];
    if(in_array($capability,['schedule.commit_change','action.undo'],true))return ['capability'=>$capability,'status'=>'rejected','error'=>'请使用明确的用户确认或撤销入口。'];
    if(str_starts_with($capability,'training.') && !in_array($capability,['training.get_today','training.get_history'],true)){
      $resolved=aiRouterTrainingContext($db,$user,$capability,$validated['input']);
      if(isset($resolved['status']))return $resolved;
      $validated['input']=$resolved;
    }
    $entry = $validated['entry'];
    $mode = $entry['mode'];
    if($mode==='direct'&&isset($call['_user_text'])&&!aiDirectIntentAllowed($capability,(string)$call['_user_text'])) return actionClarify($capability,'请明确确认要记录或执行的操作；目前没有修改任何业务记录。');
    if ($capability === 'profile.preview_change') {
        require_once __DIR__.'/onboarding-v2.php';
        if(isset($validated['input']['plan_start_date'])){
            $date=$validated['input']['plan_start_date'];$parsed=DateTimeImmutable::createFromFormat('!Y-m-d',$date,new DateTimeZone('UTC'));
            if(!$parsed||$parsed->format('Y-m-d')!==$date||$date<gmdate('Y-m-d')||$date>gmdate('Y-m-d',time()+366*86400))throw new RuntimeException('请明确核对未来一年内的计划开始日期。',422);
        }
        $doc=profileFactsRead($db,(int)$user['id']);
        $key=hash('sha256','profile-ai-preview/'.(int)$user['id'].'/'.$GLOBALS['boji_action_id']);
        $preview=profileChangePreview($db,$user,['expected_profile_revision'=>(int)$doc['revision'],'changes'=>$validated['input']['changes'],'plan_start_date'=>$validated['input']['plan_start_date']??null],$key);
        $payload=$preview+['changes'=>$validated['input']['changes'],'plan_start_date'=>$validated['input']['plan_start_date']??null];
        return ['capability'=>$capability,'status'=>'awaiting_confirmation','proposal_id'=>$preview['proposal_id'],
          'card'=>aiRouterCard(['card_type'=>'profile_change','title'=>'核对资料变更','payload'=>$payload,'actions'=>[]], 'profile/'.$preview['proposal_id'],$preview['expires_at'])];
    }

    if ($mode === 'read_only') {
        $out = aiRouterRead($db, $user, $capability, $validated['input']);
        return ['capability' => $capability, 'status' => 'completed', 'data' => $out['data'],
                'card' => $out['card'], 'revision' => $out['revision'] ?? 0];
    }
    if ($mode === 'advisory' && $capability === 'fitness.suggest_progression') {
        return aiRouterProgression($db, $user, $validated['input']);
    }
    if ($mode === 'advisory') {
        $out = aiRouterAdvice($db, $user, $validated['input']);
        return ['capability' => $capability, 'status' => 'completed', 'data' => $out['data'],
                'card' => $out['card'], 'revision' => $out['revision'] ?? 0];
    }
    if ($mode === 'direct') {
        $out = aiRouterDirect($db, $user, $capability, $validated['input'], $entry);
        if (!empty($out['degrade'])) {
            // Gate closed → safe preview path.
            return aiRouterPreview($db, $user, $capability, $validated['input'], $entry);
        }
        return ['capability' => $capability, 'status' => 'completed', 'data' => $out['result'], 'revision' => $out['result']['revision'] ?? 0];
    }
    if($capability==='plan.activate_version' && empty($validated['input']['draft_id'])){
      $drafts=$db->prepare("SELECT execution_id FROM ai_action_jobs WHERE user_id=? AND status='draft_ready' ORDER BY created_at DESC LIMIT 2");$drafts->execute([(int)$user['id']]);$candidates=$drafts->fetchAll(PDO::FETCH_COLUMN);
      if(count($candidates)!==1)return actionClarify($capability,'请打开并选择要启用的候选计划，再核对具体变更。');
      $validated['input']['draft_id']=$candidates[0];
    }
    if($capability==='plan.preview_exercise_swap' && ($validated['input']['scope']??'single_occurrence')==='recurring')return actionRecurringSwapDraft($db,$user,$validated['input'],$GLOBALS['boji_action_id']);
    if ($mode === 'preview' && $capability === 'schedule.preview_compensation') {
        return aiRouterCompensation($db, $user, $validated['input'], $entry);
    }
    if ($mode === 'preview') {
        return aiRouterPreview($db, $user, $capability, $validated['input'], $entry);
    }
    if ($mode === 'async') {
        return aiRouterAsync($db, $user, $capability, $validated['input'], $entry);
    }
    return ['capability' => $capability, 'status' => 'rejected', 'error' => '未知处理模式。'];
}

/**
 * Compensation preview: reverse the latest executed one-off reschedule as a new
 * proposal. It never restores an old snapshot and never bypasses current
 * schedule/version checks; later user changes win.
 */
function aiRouterCompensation(PDO $db, array $user, array $input, array $entry): array {
    $uid = (int)$user['id'];
    $commandId = strtolower(trim((string)($input['command_id'] ?? '')));
    if ($commandId !== '' && !preg_match('/^[0-9a-f-]{36}$/D', $commandId)) return actionClarify('schedule.preview_compensation', '补偿命令编号不正确。');
    $query = $commandId !== ''
        ? $db->prepare("SELECT operation_id,command_type,diff_json,trace_id FROM data_operations WHERE user_id=? AND operation_id=? AND command_type IN ('PlanReschedule.Confirm','PlanVersion.Activate')")
        : $db->prepare("SELECT operation_id,command_type,diff_json,trace_id FROM data_operations WHERE user_id=? AND command_type IN ('PlanReschedule.Confirm','PlanVersion.Activate') ORDER BY created_at DESC,CAST(after_version AS UNSIGNED) DESC LIMIT 1");
    $query->execute($commandId !== '' ? [$uid, $commandId] : [$uid]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    if (!$row) return actionClarify('schedule.preview_compensation', '还没有可补偿的已执行改期。');
    if($row['command_type']==='PlanVersion.Activate'){
        try{
            $inverse=actionPlanInverse($db,$uid,$row['operation_id']);
            $dates=array_column($inverse['sessions'],'date');$state=aiRouterState($db,$uid,$dates)['state'];
            [$sessions,$retained]=actionPlanCompensationSessions($db,$uid,$state,$inverse,$input['keep_date']??null);
            $span=(new DateTimeImmutable(min(array_column($sessions,'date'))))->diff(new DateTimeImmutable(max(array_column($sessions,'date'))))->days+1;
            $payload=['draft_id'=>actionUUID('compensate/'.$uid.'/'.$row['operation_id'].'/'.($GLOBALS['boji_action_id']??businessUUID())),
                'sessions'=>$sessions,'title'=>'补偿上次计划变更','duration'=>$span<=7?7:($span<=14?14:28),
                'effective_start'=>min(array_column($sessions,'date')),'retained_dates'=>$retained,
                'compensates'=>$row['operation_id'],'keep_date'=>$input['keep_date']??null];
            $entry['proposal_kind']='plan_activation';$entry['ui_card_type']='plan_activate_preview';
            return aiRouterPreview($db,$user,'schedule.preview_compensation',$payload,$entry,true);
        }catch(BusinessActionError $error){return ['capability'=>'schedule.preview_compensation','status'=>'rejected','error'=>$error->getMessage()];}
    }
    $diff = json_decode((string)($row['diff_json'] ?? ''), true);
    $moves = is_array($diff['moves'] ?? null) ? $diff['moves'] : [];
    if ($moves === []) return actionClarify('schedule.preview_compensation', '这次改期没有可反向的日期。');
    $reverse = [];
    foreach ($moves as $move) {
        if (!is_array($move) || !is_string($move['from'] ?? null) || !is_string($move['to'] ?? null)) continue;
        $reverse[] = ['from' => $move['to'], 'to' => $move['from']];
    }
    if ($reverse === []) return actionClarify('schedule.preview_compensation', '这次改期没有可反向的日期。');
    if (empty($GLOBALS['boji_trace_id']) && !empty($row['trace_id'])) $GLOBALS['boji_trace_id'] = (string)$row['trace_id'];
    return aiRouterPreview($db, $user, 'schedule.preview_compensation', ['moves' => $reverse, 'compensates' => $row['operation_id']], $entry);
}

/** Advisory progression: authoritative sets + deterministic rule → AdviceCard. */
function aiRouterProgression(PDO $db, array $user, array $input): array {
    $uid = (int)$user['id'];
    $today = actionToday($db, $uid);
    $start = (new DateTimeImmutable($today))->modify('-27 days')->format('Y-m-d');
    $loaded = aiRouterState($db, $uid, [$start, $today]);
    $profile=$loaded['state']['profile']??[];
    $age=$profile['age']??null;
    if(!is_numeric($age)||(float)$age<18||(($profile['nutritionContext']??'普通成人')!=='普通成人')||!empty($loaded['state']['nutritionTarget']['generalGuidanceOnly'])){
        return actionClarify('fitness.suggest_progression','目前资料不足以适用普通成人的加重量规则；特殊情况请结合专业评估，先核对记录，不自动增加负荷。');
    }
    $libraryId = trim((string)($input['library_id'] ?? ''));
    $name = trim((string)($input['exercise_name'] ?? ''));
    $sets = [];
    $matchedName = null;
    $matchedLibrary = null;
    $variants = [];
    if (is_array($loaded['state']['days'] ?? null)) ksort($loaded['state']['days']);
    foreach (($loaded['state']['days'] ?? []) as $date => $day) {
        if (!is_array($day) || $date < $start || $date > $today) continue;
        foreach (($day['exercises'] ?? []) as $exercise) {
            $candidateId = strtolower(trim((string)($exercise['libraryID'] ?? '')));
            if ($libraryId !== '' && strcasecmp($candidateId, $libraryId) !== 0) continue;
            if ($libraryId === '' && ($name === '' || mb_stripos((string)($exercise['name'] ?? ''), $name) === false)) continue;
            if ($candidateId === '') return actionClarify('fitness.suggest_progression', '这项动作缺少器械变体标识，请先核对动作。');
            $variants[$candidateId] = (string)($exercise['name'] ?? '');
            // Only saved, non-cancelled sessions provide comparable facts.
            $sessionId = strtolower((string)($exercise['workoutSessionID'] ?? ''));
            $confirmed = false;
            if (empty($day['workoutSessions'])) {
                $confirmed = !empty($day['workoutSavedAt']) || !empty($day['training_confirmed']);
            } else {
                foreach ($day['workoutSessions'] as $session) {
                    if ($sessionId !== '' && strtolower((string)($session['id'] ?? '')) === $sessionId) {
                        $confirmed = !empty($session['savedAt']) && empty($session['cancelledAt']);
                        break;
                    }
                }
            }
            if (!$confirmed) continue;
            $matchedName = (string)($exercise['name'] ?? '');
            $matchedLibrary = $candidateId;
            foreach (($exercise['sets'] ?? []) as $set) {
                if (($set['completed'] ?? false) !== true) continue;
                $sets[] = ['weight' => (float)($set['weight'] ?? 0), 'reps' => (int)($set['reps'] ?? 0),
                           'duration_seconds' => isset($set['durationSeconds']) ? (int)$set['durationSeconds'] : null,
                           'session_id' => $sessionId !== '' ? $sessionId : 'legacy/' . $date, 'date' => $date,
                           'completed' => true];
            }
        }
    }
    if (count($variants) > 1) return actionClarify('fitness.suggest_progression', '找到了多种器械变体，请指定：' . implode('、', array_values($variants)) . '。不同器械的重量不能合并比较。');
    if ($sets === []) return actionClarify('fitness.suggest_progression', '还没有找到这个动作的已确认完成组，无法比较重量。');
    $engine = engineRequest($GLOBALS['config'] ?? [], '/v1/fitness/progression', [
        'library_id' => $matchedLibrary,
        'sets' => array_slice($sets, -12),
        'target_reps' => (int)($input['target_reps'] ?? 8),
        'effort_acceptable' => $input['effort_acceptable'] ?? null,
        'pain_reported' => ($input['pain_reported'] ?? false) === true,
    ], 1.5);
    $result = is_array($engine['result'] ?? null) ? $engine['result'] : [
        'decision' => 'INSUFFICIENT_EVIDENCE', 'reason' => '规则引擎暂不可用，先保持当前负荷并核对记录。',
        'auto_apply' => false,
    ];
    $decision = (string)($result['decision'] ?? 'INSUFFICIENT_EVIDENCE');
    $options = [];
    if ($decision === 'MAY_SUGGEST_SMALL_PROGRESSION') {
        $options[] = ['choice' => 'normal', 'label' => '保持当前负荷', 'reason' => '先按当前重量完成目标次数；增加重量只是可选建议。'];
        $options[] = ['choice' => 'reduced', 'label' => '暂不增加', 'reason' => '如果动作质量或恢复一般，保持原负荷更稳妥。'];
    } elseif ($decision === 'SAFETY_TRIAGE') {
        $options[] = ['choice' => 'medical', 'label' => '先处理疼痛或不适', 'reason' => '有疼痛信号时不建议加重量。'];
    } elseif ($decision === 'HOLD_CURRENT_LOAD') {
        $options[] = ['choice' => 'normal', 'label' => '保持当前负荷', 'reason' => (string)($result['reason'] ?? '当前证据不足以支持增加重量。')];
    } else {
        $options[] = ['choice' => 'clarify', 'label' => '先核对动作与完成组', 'reason' => (string)($result['reason'] ?? '记录不足，无法比较重量。')];
    }
    $card = aiRouterCard(['card_type' => 'advice', 'title' => '是否尝试小幅加重量',
        'payload' => ['facts' => ['exercise' => $matchedName, 'library_id' => $matchedLibrary,
                                  'completed_sets' => count($sets), 'target_reps' => (int)($input['target_reps'] ?? 8)],
                      'options' => $options, 'engine' => $result,
                      'note' => '仅依据同一器械的已确认完成组；不自动修改计划，也不构成医学建议。']],
        'progression/' . $uid . '/' . $today);
    return ['capability' => 'fitness.suggest_progression', 'status' => 'completed',
            'data' => ['engine' => $result, 'completed_sets' => count($sets)], 'card' => $card, 'revision' => $loaded['revision'] ?? 0];
}

/** Preview mode: create a proposal bound to the live document; write nothing. */
function aiRouterPreview(PDO $db, array $user, string $capability, array $input, array $entry, bool $trustedCompensation = false): array {
    $uid = (int)$user['id'];
    $kind = $entry['proposal_kind'] ?? null;
    if ($kind === null) {
        return ['capability' => $capability, 'status' => 'rejected', 'error' => '该能力没有对应的提案类型。'];
    }
    $payload = $input;
    unset($payload['idempotency_key'],$payload['scope']);
    $key = hash('sha256','preview/'.$uid.'/'.($GLOBALS['boji_action_id']??businessUUID()));
    if($kind==='plan_activation'&&!$trustedCompensation)$payload=actionPlanDraftPayload($db,$uid,$input);
    if($trustedCompensation&&!isset($payload['compensates']))fail('缺少补偿操作依据。',422);
    if($kind==='exercise_swap')$payload['exercises']=actionTrustedExercises($db,$uid,$payload['exercises']);
    $db->beginTransaction();
    try {
        $created = aiProposalCreate($db, $uid, $kind, $payload, [], null, $key);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        if ($error instanceof RuntimeException && $error->getCode() >= 400) {
            return ['capability' => $capability, 'status' => 'rejected', 'error' => $error->getMessage()];
        }
        throw $error;
    }
    $cardType = ['weight_entry'=>'weight_entry','meal_draft'=>'meal_draft','training_finish'=>'schedule_preview'][$kind]??($entry['ui_card_type']??'schedule_preview');
    $storedPreview=aiProposalFetch($db,$uid,$created['proposal_id']);$payload=$storedPreview['payload']??$payload;
    $extraActions=$kind==='training_finish'?[['action_id'=>'discard_training_draft','label'=>'放弃未完成草稿并保留已记录组','kind'=>'dismiss']]:[];
    $previewPayload=$payload+['proposal_id'=>$created['proposal_id'],'kind'=>$kind,'preview'=>$payload,'expires_at'=>actionISO($created['expires_at'])];
    return ['capability' => $capability, 'status' => actionResultStatus($created['status']),
            'proposal_id' => $created['proposal_id'], 'proposal_kind' => $kind,
            'expires_at' => $created['expires_at'],
            'card' => aiRouterCard(['card_type' => $cardType,
                       'title' => aiRouterPreviewTitle($kind),
                       'payload' => $previewPayload,
                       'actions' => array_merge([['action_id'=>'confirm_proposal','label'=>$kind==='training_finish'?'保存已记录组并结束':'确认','kind'=>'confirm'],['action_id'=>'dismiss_proposal','label'=>$kind==='training_finish'?'继续训练':'不采用','kind'=>'dismiss']],$extraActions)],
                       'proposal/' . $created['proposal_id'], $created['expires_at'])];
}

function aiRouterPreviewTitle(string $kind): string {
    return match ($kind) {
        'plan_change_proposal' => '改期预览',
        'exercise_swap' => '换肌群预览（仅这一天）',
        'plan_activation' => '启用新计划预览',
        'meal_draft' => '待确认的饮食记录',
        default => '待确认的操作',
    };
}

/** Async mode: queue the job; 202 means accepted, never business completion. */
function aiRouterAsync(PDO $db, array $user, string $capability, array $input, array $entry): array {
    return actionQueuePlan($db,$user,$input,$GLOBALS['boji_action_id']??businessUUID());
}

/**
 * Projection freshness for one account (spec §8: a lagging projection must be
 * visible, not silently wrong). The authoritative calendar is always read from
 * the domain state; these rows only describe derived projections.
 */
function aiRouterProjectionStatus(PDO $db, int $uid): array {
    $query = $db->prepare('SELECT consumer,last_event_at,processed_events,updated_at FROM domain_projection_state WHERE user_id=? ORDER BY consumer');
    $query->execute([$uid]);
    $rows = [];
    foreach ($query->fetchAll() as $row) {
        $rows[] = ['consumer' => $row['consumer'], 'last_event_at' => $row['last_event_at'],
                   'processed_events' => (int)$row['processed_events'], 'updated_at' => $row['updated_at']];
    }
    $pending = $db->prepare("SELECT COUNT(*) FROM domain_outbox WHERE user_id=? AND status IN ('pending','processing')");
    $pending->execute([$uid]);
    $pendingCount = (int)$pending->fetchColumn();
    $dead = $db->prepare("SELECT COUNT(*) FROM domain_outbox WHERE user_id=? AND status='dead_letter'");
    $dead->execute([$uid]);
    $deadCount = (int)$dead->fetchColumn();
    $gaps=domainProjectionGaps($db,['personal-memory-v1','notifications-v1','club-progress-v1','home-insight-v1'],$uid);$missing=array_sum(array_map('count',$gaps));
    return ['missing_receipts'=>$missing,'consumers' => $rows, 'pending_events' => $pendingCount, 'dead_letter_events' => $deadCount,
            'in_sync' => $pendingCount === 0 && $deadCount === 0 && $missing===0];
}

/**
 * Batch entry used by POST /me/ai/resolve. */
function aiRouterResolve(PDO $db, array $user, array $body): array {
    $calls=$body['calls']??null;$message=$body['message_id']??null;
    if(!is_array($calls)||!array_is_list($calls)||!$calls||count($calls)>8||!is_string($message)||!preg_match('/^[A-Za-z0-9_-]{1,80}$/D',$message))fail('需要稳定的消息编号及 1–8 个能力调用。',400);
    $conversation=is_string($body['conversation_id']??null)?substr($body['conversation_id'],0,80):null;
    $results=[];foreach($calls as $i=>$call){
      if(!is_array($call)){$results[]=['status'=>'rejected','error'=>'能力调用格式错误。'];continue;}
      try{$results[]=actionCallResolve($db,$user,$call,$message,$i,$conversation);}catch(Throwable $e){if($db->inTransaction())$db->rollBack();$results[]=['capability'=>$call['capability']??null,'status'=>$e->getCode()===409?'conflict':'failed_retryable','error'=>$e instanceof BusinessActionError?$e->getMessage():'行动暂未确认，请按原编号查询。'];}
    }
    return ['results'=>$results];
}
