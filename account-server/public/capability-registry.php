<?php
declare(strict_types=1);

/**
 * Phase 2: unified Capability Registry (spec §2).
 *
 * The single source of truth for what the AI may request. The model never sees
 * business logic: it may only request capabilities from this whitelist, and
 * every request is validated against the entry below before any routing.
 *
 * Fields per capability (spec §2):
 *   name, version, description, input_schema, permissions, risk_level,
 *   needs_confirmation, preconditions, domain_owner, output_schema,
 *   ui_card_type, timeout, idempotency_policy, audit_policy
 *
 * risk_level:  read_only | advisory | low | high
 * mode:        read_only | advisory | direct | preview | async
 *   read_only  execute immediately from authoritative state
 *   advisory   answer only; NEVER mutates schedule or records
 *   direct     low-risk write; requires the matching rollout gate
 *   preview    creates a proposal; nothing is written before confirmation
 *   async      queued job (ai_user_jobs); 202 + execution id only
 *
 * Keep this list small and tested: a capability ships only with a matching
 * command/proposal kind and automated coverage (spec §2 closing note).
 */

function capabilityRegistry(): array {
    $uuid = ['type' => 'string', 'pattern' => '^[0-9a-fA-F-]{36}$'];
    $date = ['type' => 'string', 'pattern' => '^\d{4}-\d{2}-\d{2}$'];
    $registry = [
        'profile.preview_change' => [
            'version'=>1, 'description'=>'用户明确要求修改身体资料、训练目标或训练条件时，生成资料差异供确认。不会直接保存资料或修改日历；未来计划需另行预览。',
            'input_schema'=>['type'=>'object','properties'=>['changes'=>['type'=>'array','minItems'=>1,'maxItems'=>20,'items'=>['type'=>'object','properties'=>['field'=>['type'=>'string','enum'=>['goal','experience','venue','equipment','equipment_exclusions','days_per_week','training_days','session_minutes','age_group','age_years','sex_for_nutrition','height_cm','profile_weight_kg','target_weight_kg','limitations','nutrition_context','daily_activity','focus']],'value'=>['type'=>['string','number','integer','array'],'maxItems'=>20,'items'=>['type'=>['string','integer']]],'unit'=>['type'=>['string','null']]],'required'=>['field','value']]],'plan_start_date'=>$date],'required'=>['changes']],
            'permissions'=>['self'],'risk_level'=>'high','needs_confirmation'=>true,'preconditions'=>[],
            'domain_owner'=>'profile','output_schema'=>['type'=>'object'],'ui_card_type'=>'profile_change',
            'timeout'=>10,'idempotency_policy'=>'proposal','audit_policy'=>'data_operations','mode'=>'preview',
        ],
        'training.get_today' => [
            'version' => 1,
            'description' => '今天（或指定日期）的安排与进行中的训练',
            'input_schema' => ['type' => 'object', 'properties' => ['date' => $date], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'read_only',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'training',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'today_training',
            'timeout' => 5,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'read_only',
        ],
        'training.get_history' => [
            'version' => 1,
            'description' => '近期已确认的训练事实（组数、日期）',
            'input_schema' => ['type' => 'object', 'properties' => ['days' => ['type' => 'integer', 'minimum' => 1, 'maximum' => 28],'exercise_name'=>['type'=>'string','maxLength'=>200]], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'read_only',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'training',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'training_progress',
            'timeout' => 5,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'read_only',
        ],
        'training.start_session' => [
            'version' => 1,
            'description' => '开始训练（单活跃会话；已有会话则恢复）',
            'input_schema' => ['type' => 'object', 'properties' => ['date' => $date, 'session_id' => $uuid], 'required' => ['date']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => ['training_commands'],
            'domain_owner' => 'training',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 10,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'Training.SessionStart',
        ],
        'training.finish_session' => [
            'version' => 1,
            'description' => '结束并确认训练（应用集合快照一次）',
            'input_schema' => ['type' => 'object', 'properties' => ['date' => $date, 'session_id' => $uuid], 'required' => ['date']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => ['training_commands'],
            'domain_owner' => 'training',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 15,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'Training.SessionFinish',
        ],
        'training.log_set' => [
            'version' => 1,
            'description' => '记录一组（动作、重量、次数/时长）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'date' => $date, 'session_id' => $uuid, 'exercise_id' => $uuid, 'set_id' => $uuid, 'exercise_name'=>['type'=>'string','maxLength'=>200],
                'weight' => ['type' => 'number', 'minimum' => 0, 'maximum' => 2000],
                'reps' => ['type' => 'integer', 'minimum' => 0, 'maximum' => 1000],
                'duration_seconds' => ['type' => 'integer', 'minimum' => 0, 'maximum' => 21600],
                'completed'=>['type'=>'boolean'],
            ], 'required' => ['date']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => ['training_commands'],
            'domain_owner' => 'training',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 10,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'Training.LogSet',
        ],
        'schedule.preview_change' => [
            'version' => 1,
            'description' => '预览改期（一次性移动；不写任何数据）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'moves' => ['type' => 'array', 'items' => ['type' => 'object', 'properties' => ['from' => $date, 'to' => $date]], 'minItems' => 1, 'maxItems' => 7],
            ], 'required' => ['moves']],
            'permissions' => ['self'],
            'risk_level' => 'high',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'schedule',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'schedule_preview',
            'timeout' => 10,
            'idempotency_policy' => 'proposal',
            'audit_policy' => 'proposal',
            'mode' => 'preview',
            'proposal_kind' => 'plan_change_proposal',
        ],
        'schedule.commit_change' => [
            'version' => 1,
            'description' => '确认执行改期提案',
            'input_schema' => ['type' => 'object', 'properties' => ['proposal_id' => $uuid], 'required' => ['proposal_id']],
            'permissions' => ['self'],
            'risk_level' => 'high',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'schedule',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 15,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'PlanReschedule.Confirm',
        ],
        'plan.preview_exercise_swap' => [
            'version' => 1,
            'description' => '预览单次换肌群（只影响指定日期）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'date' => $date,
                'exercises' => ['type' => 'array', 'items' => ['type' => 'object'], 'minItems' => 1, 'maxItems' => 30],
            ], 'required' => ['date', 'exercises']],
            'permissions' => ['self'],
            'risk_level' => 'high',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'plan',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'plan_swap_preview',
            'timeout' => 10,
            'idempotency_policy' => 'proposal',
            'audit_policy' => 'proposal',
            'mode' => 'preview',
            'proposal_kind' => 'exercise_swap',
        ],
        'plan.generate_draft' => [
            'version' => 1,
            'description' => '异步生成候选计划草稿（不启用）',
            'input_schema' => ['type' => 'object', 'properties' => ['goal' => ['type' => 'string']], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'plan',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 600,
            'idempotency_policy' => 'job',
            'audit_policy' => 'ai_user_jobs',
            'mode' => 'async',
        ],
        'plan.activate_version' => [
            'version' => 1,
            'description' => '预览并确认启用候选计划版本',
            'input_schema' => ['type' => 'object', 'properties' => ['draft_id' => $uuid], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'high',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'plan',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'plan_activate_preview',
            'timeout' => 15,
            'idempotency_policy' => 'proposal',
            'audit_policy' => 'proposal',
            'mode' => 'preview',
            'proposal_kind' => 'plan_activation',
        ],
        'schedule.preview_compensation' => [
            'version' => 1,
            'description' => '为已执行改期或长期计划变更创建补偿预览；只保留某一天的变更时传keep_date，不覆盖后续编辑，需确认',
            'input_schema' => ['type' => 'object', 'properties' => [
                'keep_date' => $date,
                'command_id' => ['type' => 'string', 'maxLength' => 36],
            ], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'high',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'schedule',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'schedule_preview',
            'timeout' => 10,
            'idempotency_policy' => 'proposal',
            'audit_policy' => 'proposal',
            'mode' => 'preview',
            'proposal_kind' => 'plan_change_proposal',
        ],
        'nutrition.lookup_food' => [
            'version'=>1, 'description'=>'查询真实食品营养库候选。需核对食物与做法，不能称为照片实测。',
            'input_schema'=>['type'=>'object','properties'=>['query'=>['type'=>'string','minLength'=>1,'maxLength'=>120]],'required'=>['query']],
            'permissions'=>['self'], 'risk_level'=>'read_only', 'needs_confirmation'=>false,
            'preconditions'=>[], 'domain_owner'=>'nutrition', 'output_schema'=>['type'=>'object'],
            'ui_card_type'=>null, 'timeout'=>5, 'idempotency_policy'=>'none', 'audit_policy'=>'none', 'mode'=>'read_only',
        ],
        'nutrition.create_draft' => [
            'version' => 1,
            'description' => '生成待确认的饮食记录草稿',
            'input_schema' => ['type' => 'object', 'properties' => [
                'date' => $date,
                'meals' => ['type' => 'array', 'items' => ['type' => 'object'], 'minItems' => 1, 'maxItems' => 10],
            ], 'required' => ['date', 'meals']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => true,
            'preconditions' => [],
            'domain_owner' => 'nutrition',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'meal_draft',
            'timeout' => 10,
            'idempotency_policy' => 'proposal',
            'audit_policy' => 'proposal',
            'mode' => 'preview',
            'proposal_kind' => 'meal_draft',
        ],
        'nutrition.save_entry' => [
            'version' => 1,
            'description' => '保存一顿已确认的饮食（直执行，按开关）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'date' => $date,
                'meals' => ['type' => 'array', 'items' => ['type' => 'object'], 'minItems' => 1, 'maxItems' => 10],
            ], 'required' => ['date', 'meals']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => ['direct_records'],
            'domain_owner' => 'nutrition',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 10,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'Meal.CreateDirect',
            'proposal_kind' => 'meal_draft',
        ],
        'body.record_weight' => [
            'version' => 1,
            'description' => '记录体重（直执行，按开关；同日可多次）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'date' => $date,
                'kilograms' => ['type' => 'number', 'minimum' => 20, 'maximum' => 400],
                'bodyFatPercentage' => ['type' => 'number', 'minimum' => 0, 'maximum' => 70],
                'waistCircumferenceCM' => ['type' => 'number', 'minimum' => 30, 'maximum' => 300],
            ], 'required' => ['date', 'kilograms']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => ['direct_records'],
            'domain_owner' => 'body',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'weight_entry',
            'timeout' => 10,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
            'command_type' => 'BodyWeight.CreateDirect',
            'proposal_kind' => 'weight_entry',
        ],
        'coach.assess_readiness' => [
            'version' => 1,
            'description' => '疲劳/恢复评估：只给建议，绝不改日程',
            'input_schema' => ['type' => 'object', 'properties' => ['question' => ['type' => 'string']], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'advisory',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'coach',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'advice',
            'timeout' => 20,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'advisory',
        ],
        'fitness.suggest_progression' => [
            'version' => 1,
            'description' => '基于同一器械的有效组给出是否尝试小幅加重量的建议（仅建议，不改计划）',
            'input_schema' => ['type' => 'object', 'properties' => [
                'library_id' => ['type' => 'string', 'maxLength' => 40],
                'exercise_name' => ['type' => 'string', 'maxLength' => 200],
                'target_reps' => ['type' => 'integer', 'minimum' => 1, 'maximum' => 100],
                'effort_acceptable' => ['type' => 'boolean'],
                'pain_reported' => ['type' => 'boolean'],
            ], 'required' => []],
            'permissions' => ['self'],
            'risk_level' => 'advisory',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'fitness',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'advice',
            'timeout' => 10,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'advisory',
        ],
        'club.get_progress' => [
            'version' => 1,
            'description' => '俱乐部成长季进度（只读）',
            'input_schema' => ['type' => 'object', 'properties' => [], 'required' => []],
            'permissions' => ['self', 'membership'],
            'risk_level' => 'read_only',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'club',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => 'club_progress',
            'timeout' => 10,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'read_only',
        ],
        'action.get_status' => [
            'version' => 1,
            'description' => '查询一次操作/提案/异步任务的执行状态',
            'input_schema' => ['type' => 'object', 'properties' => ['execution_id' => ['type' => 'string']], 'required' => ['execution_id']],
            'permissions' => ['self'],
            'risk_level' => 'read_only',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'action',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 5,
            'idempotency_policy' => 'none',
            'audit_policy' => 'none',
            'mode' => 'read_only',
        ],
        'action.undo' => [
            'version' => 1,
            'description' => '撤销一笔本账号的低风险直执行记录（限时窗口）',
            'input_schema' => ['type' => 'object', 'properties' => ['command_id' => $uuid], 'required' => ['command_id']],
            'permissions' => ['self'],
            'risk_level' => 'low',
            'needs_confirmation' => false,
            'preconditions' => [],
            'domain_owner' => 'action',
            'output_schema' => ['type' => 'object'],
            'ui_card_type' => null,
            'timeout' => 10,
            'idempotency_policy' => 'command',
            'audit_policy' => 'data_operations',
            'mode' => 'direct',
        ],
    ];
    $meal=['type'=>'object','properties'=>['name'=>['type'=>'string','minLength'=>1,'maxLength'=>100],'category'=>['type'=>'string','enum'=>['早餐','午餐','晚餐','加餐']],'calories'=>['type'=>'number','minimum'=>0,'maximum'=>10000],'protein'=>['type'=>'number','minimum'=>0,'maximum'=>2000],'carbs'=>['type'=>'number','minimum'=>0,'maximum'=>2000],'fat'=>['type'=>'number','minimum'=>0,'maximum'=>2000],'requiresReview'=>['type'=>'boolean'],'nutritionSources'=>['type'=>'array','maxItems'=>8,'items'=>['type'=>'string','maxLength'=>100]],'estimated'=>['type'=>'boolean'],'portion'=>['type'=>'string','maxLength'=>100],'confidence'=>['type'=>'number','minimum'=>0,'maximum'=>1]],'required'=>['name','category']];
    foreach(['nutrition.create_draft','nutrition.save_entry'] as $key)$registry[$key]['input_schema']['properties']['meals']['items']=$meal;
    $set=['type'=>'object','properties'=>['weight'=>['type'=>'number','minimum'=>0,'maximum'=>2000],'reps'=>['type'=>'integer','minimum'=>0,'maximum'=>1000],'duration_seconds'=>['type'=>'integer','minimum'=>0,'maximum'=>21600],'durationSeconds'=>['type'=>'integer','minimum'=>0,'maximum'=>21600]],'required'=>['reps']];
    $exercise=['type'=>'object','properties'=>['name'=>['type'=>'string','maxLength'=>200],'muscle'=>['type'=>'string','maxLength'=>40],'library_id'=>['type'=>'string','maxLength'=>40],'library_query'=>['type'=>'string','maxLength'=>200],'custom_id'=>$uuid,'custom_unit'=>['type'=>'string','enum'=>['reps','time']],'sets'=>['type'=>'array','minItems'=>1,'maxItems'=>50,'items'=>$set]],'required'=>['name','sets']];
    $registry['plan.preview_exercise_swap']['input_schema']['properties']['exercises']['items']=$exercise;
    $registry['plan.preview_exercise_swap']['input_schema']['properties']['scope']=['type'=>'string','enum'=>['single_occurrence','recurring']];
    $registry['schedule.preview_change']['input_schema']['properties']['moves']['items']['required']=['from','to'];
    $registry['plan.generate_draft']['input_schema']['properties']+=['start_date'=>$date,'plan_days'=>['type'=>'integer','enum'=>[7,14,28]]];
    return $registry;
}

function capabilityRegistryEntry(string $name): ?array {
    $registry = capabilityRegistry();
    if (!isset($registry[$name])) return null;
    return [$name => $registry[$name]] + $registry[$name];
}

/**
 * Validate a model- or client-supplied capability call against the registry.
 * Returns [capability, input] or throws via fail(). Schema compliance is NOT
 * business safety: routing still re-checks preconditions and state (spec §10).
 */
function capabilityCallValid(mixed $call): ?array {
    if (!is_array($call)) return null;
    $name = $call['capability'] ?? $call['name'] ?? null;
    if (!is_string($name)) return null;
    $entry = capabilityRegistryEntry($name);
    if ($entry === null) return null;
    $input = $call['input'] ?? $call['intent'] ?? [];
    if (!is_array($input)) return null;
    $schema=$entry['input_schema'];
    if(!capabilitySchemaValid($input,$schema))return null;
    return ['capability' => $name, 'input' => $input, 'entry' => $entry];
}

/** Serialize the whitelist the model may request (no secrets, no SQL surface). */
function capabilityWhitelistForModel(): array {
    $out = [];
    foreach (capabilityRegistry() as $name => $entry) {
        if(in_array($name,['schedule.commit_change','action.undo'],true))continue;
        if ($entry['mode'] === 'read_only' || $entry['mode'] === 'advisory') {
            $out[] = ['capability' => $name, 'description' => $entry['description'], 'input' => $entry['input_schema']];
        }
        if (in_array($entry['mode'], ['direct', 'preview', 'async'], true)) {
            $out[] = ['capability' => $name, 'description' => $entry['description'], 'input' => $entry['input_schema']];
        }
    }
    return $out;
}

/** Recursive JSON-schema subset used by both model requests and native tools. */
function capabilitySchemaValid(mixed $value,array $rule): bool {
 $type=$rule['type']??'';
 if(is_array($type)){foreach($type as $choice){$one=$rule;$one['type']=$choice;if(capabilitySchemaValid($value,$one))return true;}return false;}
 if($type==='null')return $value===null;
 if($type==='object'){
  if(!is_array($value)||($value&&array_is_list($value)))return false;
  foreach($rule['required']??[] as $k)if(!array_key_exists($k,$value))return false;
  $properties=$rule['properties']??null;
  foreach($value as $k=>$v){if($properties!==null&&!isset($properties[$k]))return false;if($properties!==null&&!capabilitySchemaValid($v,$properties[$k]))return false;}
 }elseif($type==='array'){
  if(!is_array($value)||!array_is_list($value)||count($value)<($rule['minItems']??0)||count($value)>($rule['maxItems']??100))return false;
  foreach($value as $v)if(!capabilitySchemaValid($v,$rule['items']??[]))return false;
 }elseif($type==='string'){
  if(!is_string($value)||mb_strlen($value)>($rule['maxLength']??2000)||mb_strlen($value)<($rule['minLength']??0))return false;
  if(isset($rule['pattern'])&&preg_match('/'.$rule['pattern'].'/D',$value)!==1)return false;
 }elseif($type==='boolean'){if(!is_bool($value))return false;
 }elseif($type==='number'||$type==='integer'){
  if(is_bool($value)||(!is_int($value)&&!is_float($value))||!is_finite((float)$value)||($type==='integer'&&!is_int($value)))return false;
  if($value<($rule['minimum']??-INF)||$value>($rule['maximum']??INF))return false;
 }else return false;
 return !isset($rule['enum'])||in_array($value,$rule['enum'],true);
}

/** Images/OCR are untrusted input; image turns expose only read/advisory tools. */
function capabilityWhitelistForChatImages(array $payload): array {
    $list=capabilityWhitelistForModel();
    if(empty($payload['images']))return $list;
    return array_values(array_filter($list,function($item){
        $entry=capabilityRegistryEntry($item['capability']);
        return $entry && in_array($entry['mode'],['read_only','advisory'],true);
    }));
}
