<?php
declare(strict_types=1);

require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/profile-facts.php';
require_once __DIR__ . '/membership-access.php';

/**
 * AI onboarding V2.
 *
 * The client may collect native form values and (separately) show model
 * candidates. Only the explicit profile-confirm route writes confirmed facts.
 * The restricted onboarding_assist purpose is injected here from the session
 * row; a client-supplied purpose string is never trusted.
 */

const ONBOARDING_PROMPT_VERSION = 'boji.onboarding_assist.v1';
const ONBOARDING_CONTEXT_PROMPT_VERSION = 'boji.context_continue.v1';
const ONBOARDING_DRAFT_PROMPT_VERSION = 'boji.draft_correction.v2';
const ONBOARDING_DEFAULT_DAILY_LIMIT = 10;
const ONBOARDING_PROPOSAL_TTL_SECONDS = 1800;

function onboardingConfig(PDO $db): array {
    $config = function_exists('appConfigPublished') ? appConfigPublished($db)['config'] : [];
    return [
        'enabled' => (bool)($config['onboarding_v2_enabled'] ?? true),
        'daily_limit' => max(1, min(100, (int)($config['onboarding_assist_daily_limit'] ?? ONBOARDING_DEFAULT_DAILY_LIMIT))),
        'content_version' => (int)($config['onboarding_content_version'] ?? 1),
        'content' => (function () use ($config) {
            $content = is_array($config['onboarding_content'] ?? null) ? $config['onboarding_content'] : [];
            if (!(bool)($config['contextual_tips_enabled'] ?? true)) $content['tips'] = [];
            return $content;
        })(),
        'contextual_tips' => (bool)($config['contextual_tips_enabled'] ?? true),
    ];
}

function onboardingBasicStatus(PDO $db, int $uid): string {
    $q=$db->prepare('SELECT basic_profile_status FROM user_onboarding_checkpoints WHERE user_id=?');$q->execute([$uid]);
    $status=$q->fetchColumn();
    if (in_array($status,['pending','completed','skipped'],true)) return $status;
    $facts=profileFactsRead($db,$uid)['facts'];
    $status='pending';foreach (['nickname','age_years','sex_for_nutrition','height_cm','profile_weight_kg'] as $field) if (isset($facts[$field])) { $status='completed';break; }
    $db->prepare('INSERT IGNORE INTO user_onboarding_checkpoints(user_id,basic_profile_status,updated_at) VALUES(?,?,UTC_TIMESTAMP())')->execute([$uid,$status]);
    return $status;
}

function onboardingSaveBasicStatus(PDO $db, array $user, array $body, string $key): array {
    $uid=(int)$user['id'];$status=$body['status']??null;
    if (!in_array($status,['completed','skipped'],true)) throw new RuntimeException('资料引导状态不正确。',422);
    return onboardingOperation($db,$uid,'basic_profile.checkpoint',$key,['status'=>$status],function()use($db,$uid,$status){
        if ($status==='completed') { $facts=profileFactsRead($db,$uid)['facts'];if(!array_intersect(array_keys($facts),['nickname','age_years','sex_for_nutrition','height_cm','profile_weight_kg'])) throw new RuntimeException('请先保存资料，或选择稍后填写。',409); }
        $db->prepare('INSERT INTO user_onboarding_checkpoints(user_id,basic_profile_status,updated_at) VALUES(?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE basic_profile_status=VALUES(basic_profile_status),updated_at=UTC_TIMESTAMP()')->execute([$uid,$status]);
        return ['basic_profile_status'=>onboardingBasicStatus($db,$uid)];
    });
}

/** Completion checks authoritative records, never a client checkbox or generated text. */
function onboardingTaskCompleteAvailable(PDO $db, array $session): bool {
    $kind=(string)$session['task_kind'];$uid=(int)$session['user_id'];
    if (in_array($kind,['plan_create','plan_import'],true)) return !empty($session['first_command_id']) && !empty($session['first_job_id']);
    if ($kind==='explore') return true;
    if ($kind==='nutrition_goal') {
        $facts=profileFactsRead($db,$uid)['facts'];
        foreach (profileFactTaskRequired($kind) as $field) if (!isset($facts[$field])) return false;
        return true;
    }
    if (!in_array($kind,['meal_log','workout_log'],true)) return false;
    $draft=onboardingDraft($session);
    if (!isset($draft['_record_baseline'])) return false;
    $old=array_flip(is_array($draft['_record_baseline'])?$draft['_record_baseline']:[]);
    foreach(onboardingSavedRecords133($db,$uid,$kind) as $id) if(!isset($old[$id])) return true;
    return false;
}

/** Canonical, account-owned records; photos/drafts and unsaved sessions do not count. */
function onboardingSavedRecords133(PDO $db,int $uid,string $kind):array {
    $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);$state=json_decode((string)($q->fetchColumn()?:''),true);
    if(is_array($state)&&($state['_partitioned']??null)===2&&function_exists('cloudLegacyState'))$state=cloudLegacyState($db,$uid);
    $ids=[];
    foreach(is_array($state['days']??null)?$state['days']:[] as $day){
        if(!is_array($day))continue;
        foreach(is_array($day[$kind==='meal_log'?'meals':'workoutSessions']??null)?$day[$kind==='meal_log'?'meals':'workoutSessions']:[] as $record){
            if(!is_array($record)||empty($record['id']))continue;
            if($kind==='meal_log'&&trim((string)($record['name']??''))!=='')$ids[]=strtolower((string)$record['id']);
            if($kind==='workout_log'&&!empty($record['savedAt'])&&empty($record['cancelledAt']))$ids[]=strtolower((string)$record['id']);
        }
    }
    return array_values(array_unique($ids));
}

function onboardingEnsureRecordBaseline133(PDO $db,array $session):array {
    $kind=$session['task_kind'];$draft=onboardingDraft($session);
    if(!in_array($kind,['meal_log','workout_log'],true)||isset($draft['_record_baseline']))return $session;
    $draft['_record_baseline']=onboardingSavedRecords133($db,(int)$session['user_id'],$kind);
    $q=$db->prepare('UPDATE user_onboarding_sessions SET draft_json=?,revision=revision+1 WHERE id=? AND revision=?');
    $q->execute([json_encode($draft,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),$session['id'],$session['revision']]);
    return onboardingSessionRead($db,(int)$session['user_id'],$session['id'])??$session;
}

/** A manual edit in AI knowledge supersedes the same unconfirmed onboarding field. */
function onboardingReconcileConfirmedFields(PDO $db, int $uid, array $changes): void {
    $session=onboardingActiveSession($db,$uid,true);
    if (!$session || in_array($session['status'],['completed'],true)) return;
    $draft=onboardingDraft($session);$changed=false;
    foreach($changes as $change){$field=$change['field']??'';if(isset($draft['fields'][$field])){unset($draft['fields'][$field]);$changed=true;}if(in_array($field,$draft['skipped']??[],true))$changed=true;$draft['skipped']=array_values(array_diff($draft['skipped']??[],[$field]));}
    if (!$changed) return;
    $db->prepare("UPDATE user_onboarding_sessions SET draft_json=?,status=IF(status='review','collecting',status),revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")->execute([json_encode($draft,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),$uid,$session['id']]);
    $db->prepare("UPDATE user_onboarding_proposals SET status='superseded',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND session_id=? AND status='awaiting_confirmation'")->execute([$uid,$session['id']]);
}

function onboardingKey(): string {
    $key = trim((string)($_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? ''));
    if ($key === '' || strlen($key) > 120 || !preg_match('/^[A-Za-z0-9._:-]+$/D', $key)) {
        throw new RuntimeException('缺少有效的幂等标识（Idempotency-Key）。', 422);
    }
    return $key;
}

function onboardingCanonical(mixed $value): mixed {
    if (!is_array($value)) return $value;
    if (!array_is_list($value)) ksort($value);
    foreach ($value as $key => $item) $value[$key] = onboardingCanonical($item);
    return $value;
}

function onboardingPayloadHash(array $payload): string {
    return hash('sha256', json_encode(onboardingCanonical($payload), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
}

/**
 * One transaction + idempotency envelope. The closure must not begin or commit
 * a transaction itself. Same key + same hash returns the stored receipt; a
 * different payload under the same key is a 409, never a silent overwrite.
 */
function onboardingOperation(PDO $db, int $uid, string $operation, string $key, array $payload, callable $closure): array {
    $hash = onboardingPayloadHash($payload);
    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        actionAssertParentActive($db,$uid);
        $existing = $db->prepare('SELECT payload_hash,result_json FROM user_onboarding_requests WHERE user_id=? AND operation=? AND idempotency_key=? FOR UPDATE');
        $existing->execute([$uid, $operation, $key]);
        $row = $existing->fetch(PDO::FETCH_ASSOC);
        if ($row) {
            if (!hash_equals((string)$row['payload_hash'], $hash)) throw new RuntimeException('同一操作编号不能用于不同内容。', 409);
            $stored = json_decode((string)$row['result_json'], true);
            if (!is_array($stored) || ($stored['status'] ?? '') !== 'pending_sync') {
                $db->commit();
                return is_array($stored) ? ($stored + ['idempotent' => true]) : ['idempotent' => true];
            }
        }
        $result = $closure();
        $db->prepare('INSERT INTO user_onboarding_requests(user_id,operation,idempotency_key,payload_hash,result_json,created_at) VALUES(?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE result_json=VALUES(result_json)')
            ->execute([$uid, $operation, $key, $hash, json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $db->commit();
        return $result;
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

function onboardingTaskKinds(): array {
    return PROFILE_TARGET_TASKS;
}

function onboardingTaskDraftFields(string $taskKind): array {
    return match ($taskKind) {
        'plan_import' => ['plan_text', 'plan_source', 'plan_image_note', 'first_plan_start_date'],
        'meal_log' => ['meal_date', 'meal_category', 'meal_description', 'meal_photo_note'],
        'workout_log' => ['workout_date', 'exercise', 'sets', 'reps', 'weight_kg', 'duration_minutes'],
        'plan_create' => ['first_plan_start_date', 'availability_note'],
        'nutrition_goal' => [],
        'explore' => [],
        default => [],
    };
}

function onboardingTaskFieldNormalize(string $field, mixed $value, ?string $unit): array {
    if ($field === 'plan_text') {
        if (!is_string($value)) throw new RuntimeException('计划文本格式不正确。', 422);
        $value = trim($value);
        if ($value === '' || mb_strlen($value) > 16000) throw new RuntimeException('计划文本长度不正确。', 422);
        return [$value, null];
    }
    if ($field === 'plan_source') {
        if (!in_array($value, ['text', 'image_ocr'], true)) throw new RuntimeException('计划来源不正确。', 422);
        return [$value, null];
    }
    if (in_array($field, ['plan_image_note', 'meal_photo_note', 'availability_note'], true)) {
        if (!is_string($value) || mb_strlen($value) > 500) throw new RuntimeException('备注长度不正确。', 422);
        return [trim($value), null];
    }
    if ($field === 'meal_date' || $field === 'workout_date' || $field === 'first_plan_start_date') {
        if (!is_string($value) || !preg_match('/^\d{4}-\d{2}-\d{2}$/D', $value)) throw new RuntimeException('日期格式不正确。', 422);
        $date = DateTimeImmutable::createFromFormat('!Y-m-d', $value, new DateTimeZone('UTC'));
        if (!$date || $date->format('Y-m-d') !== $value || $date > new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai'))) throw new RuntimeException('日期不正确。', 422);
        return [$value, null];
    }
    if ($field === 'meal_category') {
        if (!in_array($value, ['早餐', '午餐', '晚餐', '加餐'], true)) throw new RuntimeException('餐次不正确。', 422);
        return [$value, null];
    }
    if ($field === 'meal_description') {
        if (!is_string($value) || trim($value) === '' || mb_strlen($value) > 2000) throw new RuntimeException('饮食描述长度不正确。', 422);
        return [trim($value), null];
    }
    if ($field === 'exercise') {
        if (!is_string($value) || trim($value) === '' || mb_strlen($value) > 80) throw new RuntimeException('动作名称不正确。', 422);
        return [trim($value), null];
    }
    if (in_array($field, ['sets', 'reps'], true)) {
        if (!is_int($value) || $value < 0 || $value > 1000) throw new RuntimeException('训练数值不正确。', 422);
        return [$value, null];
    }
    if ($field === 'weight_kg') {
        if (is_bool($value) || !is_numeric($value) || (float)$value < 0 || (float)$value > 2000) throw new RuntimeException('重量不正确。', 422);
        return [(float)$value, 'kg'];
    }
    if ($field === 'duration_minutes') {
        if (!is_int($value) || $value < 0 || $value > 600) throw new RuntimeException('时长不正确。', 422);
        return [$value, 'minutes'];
    }
    throw new RuntimeException('草稿字段不正确。', 422);
}

function onboardingNormalizeChanges(string $taskKind, mixed $changes, string $origin = 'user_form'): array {
    if (!is_array($changes) || !array_is_list($changes) || !$changes || count($changes) > 30) throw new RuntimeException('需要 1–30 项资料改动。', 422);
    $profileFields = profileFactTaskFields($taskKind);
    $draftFields = onboardingTaskDraftFields($taskKind);
    $out = []; $seen = [];
    foreach ($changes as $change) {
        if (!is_array($change)) throw new RuntimeException('资料改动格式不正确。', 422);
        if(array_diff(array_keys($change),['field','value','unit','measurement_kind','observed_at']))throw new RuntimeException('资料改动包含未允许字段。',422);
        $field = $change['field'] ?? null;
        if (!is_string($field) || isset($seen[$field])) throw new RuntimeException('资料字段不正确或重复。', 422);
        $seen[$field] = true;
        if (in_array($field, $profileFields, true)) {
            if (array_key_exists('value', $change) && $change['value'] === null) { $out[] = ['field' => $field, 'value' => null, 'unit' => null, 'remove' => true]; continue; }
            [$value, $unit] = profileFactNormalizeValue($field, $change['value'] ?? null, $change['unit'] ?? null);
            $entry = ['field' => $field, 'value' => $value, 'unit' => $unit, 'origin' => $origin];
            if (in_array($field, ['profile_weight_kg', 'target_weight_kg'], true)) {
                if (isset($change['measurement_kind'])) {
                    if (!in_array($change['measurement_kind'], ['measured', 'estimated'], true)) throw new RuntimeException('体重性质不正确。', 422);
                    $entry['measurement_kind'] = $change['measurement_kind'];
                }
                if (isset($change['observed_at'])) {
                    [$observed] = profileFactNormalizeValue('weight_observed_at', $change['observed_at'], null);
                    $entry['observed_at'] = $observed;
                }
            }
            $out[] = $entry;
            continue;
        }
        if (in_array($field, $draftFields, true)) {
            if (array_key_exists('value', $change) && $change['value'] === null) { $out[] = ['field' => $field, 'value' => null, 'unit' => null, 'remove' => true]; continue; }
            [$value, $unit] = onboardingTaskFieldNormalize($field, $change['value'] ?? null, $change['unit'] ?? null);
            $out[] = ['field' => $field, 'value' => $value, 'unit' => $unit, 'origin' => $origin];
            continue;
        }
        throw new RuntimeException('该字段不属于当前任务。', 422);
    }
    return $out;
}

function onboardingDraftInitial(string $taskKind): array {
    return ['task_kind' => $taskKind, 'fields' => [], 'skipped' => [], 'artifacts' => [], 'first_plan' => []];
}

function onboardingSessionRead(PDO $db, int $uid, string $sessionId, bool $forUpdate = false): ?array {
    if (!preg_match('/^[0-9a-f-]{36}$/iD', $sessionId)) return null;
    $query = $db->prepare('SELECT * FROM user_onboarding_sessions WHERE user_id=? AND id=?' . ($forUpdate ? ' FOR UPDATE' : ''));
    $query->execute([$uid, strtolower($sessionId)]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function onboardingActiveSession(PDO $db, int $uid, bool $forUpdate = false): ?array {
    $head = $db->prepare('SELECT active_session_id FROM user_onboarding_heads WHERE user_id=?' . ($forUpdate ? ' FOR UPDATE' : ''));
    $head->execute([$uid]);
    $sessionId = $head->fetchColumn();
    if (!is_string($sessionId) || $sessionId === '') return null;
    return onboardingSessionRead($db, $uid, $sessionId, $forUpdate);
}

function onboardingDraft(array $session): array {
    $draft = json_decode((string)$session['draft_json'], true);
    if (!is_array($draft)) $draft = onboardingDraftInitial((string)$session['task_kind']);
    $draft['fields'] = is_array($draft['fields'] ?? null) ? $draft['fields'] : [];
    $draft['skipped'] = is_array($draft['skipped'] ?? null) ? array_values(array_unique($draft['skipped'])) : [];
    $draft['artifacts'] = is_array($draft['artifacts'] ?? null) ? $draft['artifacts'] : [];
    $draft['first_plan'] = is_array($draft['first_plan'] ?? null) ? $draft['first_plan'] : [];
    return $draft;
}

function onboardingEffectiveValues(array $facts, array $draft): array {
    $values = [];
    foreach (profileFactFieldDefinitions() as $field => $definition) {
        if (isset($facts[$field])) $values[$field] = $facts[$field]['value'];
    }
    if (isset($values['age_years']) && !isset($values['age_group'])) {
        $values['age_group'] = (int)$values['age_years'] < 18 ? 'minor' : 'adult';
    }
    foreach (($draft['fields'] ?? []) as $field => $entry) {
        if (!is_array($entry) || !array_key_exists('value', $entry)) continue;
        $values[$field] = $entry['value'];
    }
    foreach (($draft['artifacts'] ?? []) as $field => $entry) {
        if (is_array($entry) && array_key_exists('value', $entry)) $values[$field] = $entry['value'];
    }
    return $values;
}

function onboardingRequiredMissing(array $session, array $facts, array $draft): array {
    $values = onboardingEffectiveValues($facts, $draft);
    $required = profileFactTaskRequired((string)$session['task_kind'], $draft);
    $skipped = array_flip($draft['skipped'] ?? []);
    $missing = [];
    foreach ($required as $field) {
        if (isset($skipped[$field])) continue;
        $value = $values[$field] ?? null;
        if ($value === null || $value === '' || $value === []) $missing[] = $field;
    }
    if($session['task_kind']==='plan_create'&&isset($values['days_per_week'],$values['training_days'])&&(int)$values['days_per_week']!==count($values['training_days']))$missing[]='training_days';
    return array_values(array_unique($missing));
}

function onboardingPlanReady(array $session, array $facts, array $draft): bool {
    if ((string)$session['task_kind'] !== 'plan_create') return false;
    // The first plan may only use confirmed facts. Drafts are intentionally not
    // enough: otherwise an unconfirmed/default value could reach generation.
    $values = [];
    foreach (profileFactFieldDefinitions() as $field => $definition) {
        if (isset($facts[$field])) $values[$field] = $facts[$field]['value'];
    }
    if (isset($values['age_years']) && !isset($values['age_group'])) $values['age_group'] = (int)$values['age_years'] < 18 ? 'minor' : 'adult';
    foreach (['goal', 'experience', 'venue', 'days_per_week', 'training_days', 'session_minutes', 'age_group'] as $field) {
        if (!isset($values[$field]) || $values[$field] === '' || $values[$field] === null) return false;
    }
    if (in_array($values['venue'], ['在家', '两者都有'], true) && (($values['equipment'] ?? []) === [] || $values['equipment'] === null)) return false;
    if((int)$values['days_per_week']!==count($values['training_days']))return false;
    if (profileFactSafety(['facts' => $facts], $draft)['safety_blocked']) return false;
    return true;
}

function onboardingAssistUsage(PDO $db, int $uid): array {
    $config = onboardingConfig($db);
    $today = (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
    $query = $db->prepare('SELECT turns FROM onboarding_assist_usage WHERE user_id=? AND usage_day=?');
    $query->execute([$uid, $today]);
    $used = (int)($query->fetchColumn() ?: 0);
    return ['day' => $today, 'used' => $used, 'limit' => $config['daily_limit'], 'remaining' => max(0, $config['daily_limit'] - $used)];
}

/** Must be called inside the run-creation transaction after lockActiveUser. */
function onboardingAssistReserve(PDO $db, int $uid, string $sessionId): array {
    if (!membershipHasActiveEntitlement($db, $uid)) throw new RuntimeException('请先开通会员后使用此功能。', 403);
    $config = onboardingConfig($db);
    if (!$config['enabled']) throw new RuntimeException('新手引导暂不可用，原生资料卡仍可使用。', 503);
    $session = onboardingSessionRead($db, $uid, $sessionId, true);
    if (!$session) throw new RuntimeException('引导会话不存在。', 404);
    if ((string)$session['status'] === 'completed') throw new RuntimeException('引导已经结束，请使用普通对话。', 409);
    if ((string)$session['status'] === 'deferred') {
        $db->prepare("UPDATE user_onboarding_sessions SET status='collecting',revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$session['id']]);
        $session['status'] = 'collecting';
        $session['revision'] = (int)$session['revision'] + 1;
    }
    $usage = onboardingAssistUsage($db, $uid);
    if ($usage['remaining'] <= 0) {
        $retry = max(60, 86400 - ((time() + 8 * 3600) % 86400));
        header('Retry-After: ' . $retry);
        throw new RuntimeException('今天的引导 AI 次数已用完，明天恢复；现在仍可继续填写原生资料卡。', 429);
    }
    $insert = $db->prepare('INSERT INTO onboarding_assist_usage(user_id,usage_day,turns,updated_at) VALUES(?,?,1,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE turns=turns+1,updated_at=UTC_TIMESTAMP()');
    $insert->execute([$uid, $usage['day']]);
    $after = onboardingAssistUsage($db, $uid);
    return ['session' => $session, 'usage' => $after];
}

function onboardingAssistAllowedFields(string $taskKind): array {
    $fields = profileFactTaskFields($taskKind);
    return array_values(array_intersect($fields, array_keys(profileFactFieldDefinitions())));
}

function onboardingAssistContext(PDO $db, int $uid, array $session, string $question): array {
    $document = profileFactsRead($db, $uid);
    $draft = onboardingDraft($session);
    $taskKind = (string)$session['task_kind'];
    $safety = profileFactSafety($document, $draft);
    $config = onboardingConfig($db);
    $promptFacts = profileFactsForPrompt($document, $taskKind);
    if ($promptFacts === []) $promptFacts = new stdClass();
    $draftFields = array_map(fn($entry) => ['value' => $entry['value'] ?? null, 'unit' => $entry['unit'] ?? null, 'origin' => $entry['origin'] ?? 'user_form'], $draft['fields']);
    if ($draftFields === []) $draftFields = new stdClass();
    return [
        'schema_version' => 1,
        'prompt_version' => ONBOARDING_PROMPT_VERSION,
        'task_kind' => $taskKind,
        'session_id' => (string)$session['id'],
        'session_revision' => (int)$session['revision'],
        'profile_revision' => (int)$document['revision'],
        'confirmed_facts' => $promptFacts,
        'draft_fields' => $draftFields,
        'skipped_fields' => $draft['skipped'],
        'required_missing_fields' => onboardingRequiredMissing($session, is_array($document['facts'] ?? null) ? $document['facts'] : [], $draft),
        'allowlisted_fields' => onboardingAssistAllowedFields($taskKind),
        'allowed_source_ids' => [],
        'content_version' => $config['content_version'],
        'safety_blocked' => $safety['safety_blocked'],
        'safety_message' => $safety['safety_message'],
        'question' => $question,
    ];
}

function onboardingCapabilityWhitelist(): array {
    if (!function_exists('capabilityRegistry')) return [];
    $allowed = ['training.get_today', 'training.get_history', 'club.get_progress'];
    $out = [];
    foreach (capabilityRegistry() as $name => $entry) {
        if (!in_array($name, $allowed, true)) continue;
        $out[] = ['capability' => $name, 'description' => $entry['description'], 'input' => $entry['input_schema']];
    }
    return $out;
}

/** Apply model candidates inside the worker's completion transaction. */
function onboardingApplyModelCandidates(PDO $db, int $uid, string $sessionId, array $candidates, string $question, string $runId): array {
    $session = onboardingSessionRead($db, $uid, $sessionId, true);
    if (!$session) return ['applied' => 0];
    if ((string)$session['status'] === 'completed') return ['applied' => 0];
    $taskKind = (string)$session['task_kind'];
    $allowed = array_flip(onboardingAssistAllowedFields($taskKind));
    $draft = onboardingDraft($session);
    $applied = 0;
    foreach ($candidates as $candidate) {
        if (!is_array($candidate)) continue;
        $field = $candidate['field'] ?? null;
        $quote = $candidate['evidence_quote'] ?? null;
        if (!is_string($field) || !isset($allowed[$field])) continue;
        if (!is_string($quote) || $quote === '' || mb_strpos($question, $quote) === false) continue;
        try { [$value, $unit] = profileFactNormalizeValue($field, $candidate['value'] ?? null, $candidate['unit'] ?? null); }
        catch (Throwable) { continue; }
        $draft['fields'][$field] = ['value' => $value, 'unit' => $unit, 'origin' => 'model_candidate',
            'evidence_quote' => mb_substr($quote, 0, 160), 'source_ref' => 'run/' . $runId, 'updated_at' => gmdate('c')];
        $draft['skipped'] = array_values(array_filter($draft['skipped'], fn($item) => $item !== $field));
        $applied++;
    }
    if ($applied > 0) {
        $db->prepare("UPDATE user_onboarding_sessions SET draft_json=?,revision=revision+1,status=IF(status='task_selected','collecting',status),updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")
            ->execute([json_encode($draft, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $uid, $sessionId]);
    }
    return ['applied' => $applied, 'revision' => (int)$session['revision'] + ($applied ? 1 : 0)];
}

function onboardingAssistRecordTurn(PDO $db, int $uid, string $sessionId, string $role, string $content): void {
    if (!in_array($role, ['user', 'assistant'], true) || $content === '') return;
    $db->prepare('INSERT INTO user_onboarding_messages(session_id,user_id,role,content,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP())')
        ->execute([$sessionId, $uid, $role, mb_substr($content, 0, 4000)]);
}

function onboardingAssistHistory(PDO $db, int $uid, string $sessionId, int $limit = 10): array {
    $query = $db->prepare('SELECT role,content FROM user_onboarding_messages WHERE user_id=? AND session_id=? ORDER BY id DESC LIMIT ' . max(2, min(12, $limit)));
    $query->execute([$uid, $sessionId]);
    $rows = array_reverse($query->fetchAll(PDO::FETCH_ASSOC));
    return array_map(fn($row) => ['role' => $row['role'], 'text' => (string)$row['content']], $rows);
}

function onboardingInitialPlanCount(PDO $db, int $uid): int {
    $query = $db->prepare("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id=? AND kind IN ('generate_plan','parse_plan')");
    $query->execute([$uid]);
    return (int)$query->fetchColumn();
}

function onboardingSessionPublic(PDO $db, array $session): array {
    $session=onboardingEnsureRecordBaseline133($db,$session);
    $uid = (int)$session['user_id'];
    $document = profileFactsRead($db, $uid);
    $draft = onboardingDraft($session);
    $config = onboardingConfig($db);
    $usage = onboardingAssistUsage($db, $uid);
    $missing = onboardingRequiredMissing($session, is_array($document['facts'] ?? null) ? $document['facts'] : [], $draft);
    $planReady = onboardingPlanReady($session, is_array($document['facts'] ?? null) ? $document['facts'] : [], $draft);
    $safety = profileFactSafety($document, $draft);
    $hasMembership = membershipHasActiveEntitlement($db, $uid);
    $planCount = onboardingInitialPlanCount($db, $uid);
    $required = profileFactTaskRequired((string)$session['task_kind'], $draft);
    $values = onboardingEffectiveValues(is_array($document['facts'] ?? null) ? $document['facts'] : [], $draft);
    return [
        'basic_profile_status' => onboardingBasicStatus($db,$uid),
        'task_complete_available' => onboardingTaskCompleteAvailable($db,$session),
        'assist_usage' => $usage,
        'session' => [
            'id' => (string)$session['id'], 'schema_version' => (int)$session['schema_version'],
            'revision' => (int)$session['revision'], 'status' => (string)$session['status'],
            'task_kind' => (string)$session['task_kind'], 'conversation_id' => $session['conversation_id'],
            'first_job_id' => $session['first_job_id'], 'first_proposal_id' => $session['first_proposal_id'],
            'first_command_id' => $session['first_command_id'],
            'created_at' => $session['created_at'], 'updated_at' => $session['updated_at'],
            'completed_at' => $session['completed_at'], 'deferred_at' => $session['deferred_at'],
        ],
        'pending_profile_proposal'=>onboardingPendingProfileProposal($db,$session),
        'profile_revision' => (int)$document['revision'],
        'confirmed_facts' => profileFactsForPrompt($document, (string)$session['task_kind']),
        'draft' => $draft,
        'skipped_fields' => $draft['skipped'],
        'required_fields' => $required,
        'required_missing_fields' => array_values(array_diff($missing, $draft['skipped'])),
        'plan_ready' => $planReady,
        'safety_blocked' => $safety['safety_blocked'],
        'safety_message' => $safety['safety_message'],
        'capabilities' => [
            'assist_available' => $hasMembership && $config['enabled'] && (string)$session['status'] !== 'completed' && $usage['remaining'] > 0,
            'assist_budget_remaining' => $hasMembership ? $usage['remaining'] : 0,
            'initial_plan_available' => $hasMembership && $config['enabled'] && (string)$session['status'] !== 'completed' && $planReady && $planCount < 5,
            'initial_plan_jobs_used' => $planCount,
            'initial_plan_limit' => $hasMembership ? 5 : 0,
            'membership_active' => $hasMembership,
        ],
        'content_version' => $config['content_version'],
        'content' => $config['content'],
        'recent_messages' => onboardingAssistRecentMessages($db, $uid, (string)$session['id']),
        'prompt_version' => ONBOARDING_PROMPT_VERSION,
        'receipt_id' => 'onboarding-state/' . $session['id'] . '/' . $session['revision'],
    ];
}

function onboardingCreateSession(PDO $db, array $user, array $body, string $key): array {
    $uid = (int)$user['id'];
    $taskKind = (string)($body['task_kind'] ?? '');
    if (!in_array($taskKind, onboardingTaskKinds(), true)) throw new RuntimeException('首任务类型不正确。', 422);
    if ((int)($body['schema_version'] ?? 1) !== 1) throw new RuntimeException('引导版本不支持。', 422);
    return onboardingOperation($db, $uid, 'session.create', $key, ['task_kind' => $taskKind, 'schema_version' => 1,'expected_session_revision'=>$body['expected_session_revision']??null], function () use ($db, $uid, $taskKind,$body) {
        $session = onboardingActiveSession($db, $uid, true);
        if ($session) {
            $status = (string)$session['status'];
            if ($status !== 'completed' && (string)$session['task_kind'] !== $taskKind) {
                if (!isset($body['expected_session_revision']) || (int)$body['expected_session_revision'] !== (int)$session['revision']) throw new RuntimeException('切换任务前请刷新当前草稿。',409);
                $previous=onboardingDraft($session);$saved=$previous['task_drafts']??[];
                $old=$previous;unset($old['task_drafts']);$saved[$session['task_kind']]=$old;
                $draft=$saved[$taskKind]??onboardingDraftInitial($taskKind);$draft['task_drafts']=$saved;
                $db->prepare("UPDATE user_onboarding_sessions SET task_kind=?,draft_json=?,status='collecting',revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE id=?")
                   ->execute([$taskKind,json_encode($draft,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),$session['id']]);
                $session=onboardingSessionRead($db,$uid,$session['id'],true);
            }
            return onboardingSessionPublic($db, $session) + ['created' => false];
        }
        $id = actionUUID('onboarding-session/' . $uid . '/' . $taskKind);
        $conversation = actionUUID('onboarding-conversation/' . $uid . '/' . $id);
        $db->prepare("INSERT INTO user_onboarding_sessions(id,user_id,schema_version,revision,task_kind,status,draft_json,conversation_id,created_at,updated_at) VALUES(?,?,1,1,?,'task_selected',?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
            ->execute([$id, $uid, $taskKind, json_encode(onboardingDraftInitial($taskKind), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $conversation]);
        $db->prepare('INSERT INTO user_onboarding_heads(user_id,active_session_id,updated_at) VALUES(?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE active_session_id=VALUES(active_session_id),updated_at=UTC_TIMESTAMP()')
            ->execute([$uid, $id]);
        $session = onboardingSessionRead($db, $uid, $id, true);
        return onboardingSessionPublic($db, $session) + ['created' => true];
    });
}

function onboardingPatchDraft(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expected = $body['expected_session_revision'] ?? null;
    if (!is_int($expected) || $expected < 0) throw new RuntimeException('缺少会话版本。', 422);
    $changes = $body['changes'] ?? [];
    $skipped = $body['skipped'] ?? [];
    if (!is_array($skipped) || count($skipped) > 20) throw new RuntimeException('跳过项格式不正确。', 422);
    $requestedOrigin = (string)($body['origin'] ?? 'user_form');
    $origin = in_array($requestedOrigin, ['user_form', 'legacy_draft'], true) ? $requestedOrigin : 'user_form';
    return onboardingOperation($db, $uid, 'session.draft', $key, ['session_id' => $sessionId, 'expected' => $expected, 'changes' => $changes, 'skipped' => $skipped, 'origin' => $origin], function () use ($db, $uid, $sessionId, $expected, $changes, $skipped, $origin) {
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        if (!$session) throw new RuntimeException('引导会话不存在。', 404);
        if ((int)$session['revision'] !== $expected) throw new RuntimeException('引导会话已在其他设备更新，请刷新后核对。', 409);
        if (in_array((string)$session['status'], ['completed'], true)) throw new RuntimeException('引导已经结束，不能继续修改草稿。', 409);
        $taskKind = (string)$session['task_kind'];
        $normalized = $changes === [] ? [] : onboardingNormalizeChanges($taskKind, $changes, 'user_form');
        $fieldsForTask = array_flip(array_merge(profileFactTaskFields($taskKind), onboardingTaskDraftFields($taskKind)));
        foreach ($skipped as $field) if (!is_string($field) || !isset($fieldsForTask[$field])) throw new RuntimeException('跳过项不属于当前任务。', 422);
        $draft = onboardingDraft($session);
        foreach ($normalized as $change) {
            $field = $change['field'];
            if (!empty($change['remove'])) { unset($draft['fields'][$field]); continue; }
            $draft['fields'][$field] = ['value' => $change['value'], 'unit' => $change['unit'], 'origin' => $origin, 'updated_at' => gmdate('c')];
        }
        if ($origin === 'legacy_draft') $draft['migration_source'] = 'legacy_local_draft';
        $draft['skipped'] = array_values(array_unique(array_merge($draft['skipped'], $skipped)));
        $status = in_array((string)$session['status'], ['task_selected', 'welcome'], true) ? 'collecting' : (string)$session['status'];
        if ((string)$session['status'] === 'deferred') $status = 'collecting';
        $db->prepare('UPDATE user_onboarding_sessions SET draft_json=?,status=?,revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?')
            ->execute([json_encode($draft, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $status, $uid, $sessionId]);
        return onboardingSessionPublic($db, onboardingSessionRead($db, $uid, $sessionId, true));
    });
}

function onboardingPreview(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expectedProfile = $body['expected_profile_revision'] ?? null;
    $expectedSession = $body['expected_session_revision'] ?? null;
    if (!is_int($expectedProfile) || !is_int($expectedSession)) throw new RuntimeException('缺少资料或会话版本。', 422);
    return onboardingOperation($db, $uid, 'profile.preview', $key, ['session_id' => $sessionId, 'expected_profile' => $expectedProfile, 'expected_session' => $expectedSession, 'changes' => $body['changes'] ?? null], function () use ($db, $uid, $sessionId, $body, $expectedProfile, $expectedSession, $key) {
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        if (!$session) throw new RuntimeException('引导会话不存在。', 404);
        if ((int)$session['revision'] !== $expectedSession) throw new RuntimeException('引导会话已变化，请重新核对。', 409);
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== $expectedProfile) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
        $draft = onboardingDraft($session);
        $settings = onboardingConfig($db);
        if (!$settings['enabled']) throw new RuntimeException('新手引导暂不可用。', 503);
        $taskKind = (string)$session['task_kind'];
        if (isset($body['changes'])) {
            $normalized = onboardingNormalizeChanges($taskKind, $body['changes'], 'user_form');
        } else {
            $changes = [];
            foreach (profileFactTaskFields($taskKind) as $field) {
                if (!isset($draft['fields'][$field])) continue;
                $changes[] = ['field' => $field, 'value' => $draft['fields'][$field]['value'], 'unit' => $draft['fields'][$field]['unit'] ?? null];
            }
            $normalized = onboardingNormalizeChanges($taskKind, $changes, 'user_form');
        }
        if (!$normalized) throw new RuntimeException('还没有可确认的资料。', 422);
        $before = profileFactsPublicDocument($document)['facts'];
        $after = $before;
        foreach ($normalized as $change) {
            $field = $change['field'];
            $after[$field] = ['field' => $field, 'value' => $change['value'], 'unit' => $change['unit'],
                'source_kind' => 'confirmed', 'source_ref' => null, 'confirmed_at' => null,
                'revision' => (int)$document['revision'] + 1,
                'measurement_kind' => $change['measurement_kind'] ?? null,
                'observed_at' => $change['observed_at'] ?? null];
        }
        $proposalId = actionUUID('onboarding-proposal/' . $uid . '/' . $sessionId . '/' . $key);
        $expiresAt = gmdate('Y-m-d H:i:s', time() + ONBOARDING_PROPOSAL_TTL_SECONDS);
        $db->prepare("INSERT INTO user_onboarding_proposals(proposal_id,user_id,session_id,kind,status,changes_json,before_json,profile_revision,session_revision,idempotency_key,expires_at,created_at,updated_at) VALUES(?,?,?,'profile','awaiting_confirmation',?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
            ->execute([$proposalId, $uid, $sessionId,
                json_encode($normalized, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                json_encode($before, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                $expectedProfile, $expectedSession, $key, $expiresAt]);
        $db->prepare("UPDATE user_onboarding_sessions SET status='review',first_proposal_id=?,revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")->execute([$proposalId,$uid, $sessionId]);
        return [
            'proposal_id' => $proposalId, 'schema_version' => 1, 'expires_at' => actionISO($expiresAt),
            'profile_revision' => $expectedProfile, 'session_revision' => $expectedSession + 1,
            'before' => $before, 'after' => $after,
            'unknown_fields' => array_values(array_diff(array_keys(profileFactFieldDefinitions()), array_keys($after))),
        ];
    });
}

function onboardingConfirm(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $proposalId = strtolower(trim((string)($body['proposal_id'] ?? '')));
    if (!preg_match('/^[0-9a-f-]{36}$/D', $proposalId)) throw new RuntimeException('资料提案编号不正确。', 422);
    if (!is_int($body['expected_profile_revision'] ?? null) || !is_int($body['expected_session_revision'] ?? null)) throw new RuntimeException('缺少资料或会话版本。', 422);
    return onboardingOperation($db, $uid, 'profile.confirm', $key, ['session_id' => $sessionId, 'proposal_id' => $proposalId, 'expected_profile' => $body['expected_profile_revision'], 'expected_session' => $body['expected_session_revision']], function () use ($db, $uid, $sessionId, $proposalId, $body, $key) {
        $proposalQuery = $db->prepare('SELECT * FROM user_onboarding_proposals WHERE user_id=? AND proposal_id=? AND session_id=? FOR UPDATE');
        $proposalQuery->execute([$uid, $proposalId, $sessionId]);
        $proposal = $proposalQuery->fetch(PDO::FETCH_ASSOC);
        if (!$proposal) throw new RuntimeException('资料提案不存在。', 404);
        if ((string)$proposal['status'] === 'committed') {
            return ['status' => 'committed', 'profile_revision' => null,
                'receipt' => ['command_id' => $proposal['command_id'], 'committed_at' => actionISO((string)$proposal['confirmed_at'])],
                'effects' => ['profile_updated' => true, 'measurement_created' => false, 'plan_changed' => false], 'idempotent' => true];
        }
        if ((string)$proposal['status'] !== 'awaiting_confirmation') throw new RuntimeException('资料提案已失效，请重新核对。', 409);
        if (strtotime((string)$proposal['expires_at'] . ' UTC') <= time()) {
            $db->prepare("UPDATE user_onboarding_proposals SET status='expired',updated_at=UTC_TIMESTAMP() WHERE proposal_id=?")->execute([$proposalId]);
            throw new RuntimeException('资料提案已过期，请重新生成预览。', 410);
        }
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        if (!$session) throw new RuntimeException('引导会话不存在。', 404);
        if ((int)$session['revision'] !== (int)$body['expected_session_revision']) throw new RuntimeException('引导会话已变化，请重新核对。', 409);
        if ((int)$session['revision'] !== (int)$proposal['session_revision'] + 1) throw new RuntimeException('预览之后的资料已变化，请重新生成预览。',409);
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== (int)$body['expected_profile_revision'] || (int)$document['revision'] !== (int)$proposal['profile_revision']) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
        $changes = json_decode((string)$proposal['changes_json'], true);
        if (!is_array($changes) || !$changes) throw new RuntimeException('资料提案内容不完整。', 422);
        $next = (int)$document['revision'] + 1;
        $facts = profileFactsApplyChanges($document, $changes, 'confirmed', 'proposal/' . $proposalId, $next);
        $newRevision = profileFactsWrite($db, $uid, $facts, (int)$document['revision']);
        profileFactsRestoreConfirmedFields($db,$uid,$changes ?? []);
        profileFactsProjectLegacy($db, $uid, $facts);
        $commandId = actionUUID('profile-confirm/' . $uid . '/' . $proposalId);
        $now = gmdate('Y-m-d H:i:s');
        $db->prepare("UPDATE user_onboarding_proposals SET status='committed',confirmed_at=?,command_id=?,updated_at=UTC_TIMESTAMP() WHERE proposal_id=?")
            ->execute([$now, $commandId, $proposalId]);
        $draft = onboardingDraft($session);
        foreach ($changes as $change) { unset($draft['fields'][$change['field']]); }
        $db->prepare("UPDATE user_onboarding_sessions SET draft_json=?,revision=revision+1,status=IF(status='review','first_task_ready',status),updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")
            ->execute([json_encode($draft, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $uid, $sessionId]);
        if (function_exists('trainingRecordAudit')) {
            trainingRecordAudit($db, $uid, $commandId, 'user', 'ProfileFacts.Confirm',
                hash('sha256', json_encode(['ProfileFacts.Confirm', $changes, $proposalId], JSON_UNESCAPED_UNICODE)),
                'profile', 'profile', (string)$document['revision'], (string)$newRevision,
                ['proposal_id' => $proposalId, 'fields' => array_map(fn($c) => $c['field'], $changes)], $key);
        }
        $sessionAfter = onboardingSessionRead($db, $uid, $sessionId, true);
        return [
            'status' => 'committed', 'profile_revision' => $newRevision,
            'session_revision' => (int)$sessionAfter['revision'],
            'receipt' => ['command_id' => $commandId, 'committed_at' => actionISO($now)],
            'effects' => ['profile_updated' => true, 'measurement_created' => false, 'plan_changed' => false],
            'state' => onboardingSessionPublic($db, $sessionAfter),
        ];
    });
}

function onboardingDefer(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expected = $body['expected_session_revision'] ?? null;
    if (!is_int($expected)) throw new RuntimeException('缺少会话版本。', 422);
    return onboardingOperation($db, $uid, 'session.defer', $key, ['session_id' => $sessionId, 'expected' => $expected], function () use ($db, $uid, $sessionId, $expected) {
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        if (!$session) throw new RuntimeException('引导会话不存在。', 404);
        if ((int)$session['revision'] !== $expected) throw new RuntimeException('引导会话已变化，请刷新。', 409);
        if ((string)$session['status'] === 'completed') throw new RuntimeException('引导已经结束。', 409);
        $db->prepare("UPDATE user_onboarding_sessions SET status='deferred',deferred_at=UTC_TIMESTAMP(),revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")
            ->execute([$uid, $sessionId]);
        return onboardingSessionPublic($db, onboardingSessionRead($db, $uid, $sessionId, true)) + ['deferred' => true];
    });
}

function onboardingComplete(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expected = $body['expected_session_revision'] ?? null;
    $covenant = trim((string)($body['covenant_version'] ?? ''));
    if (!is_int($expected)) throw new RuntimeException('缺少会话版本。', 422);
    if ($covenant === '' || mb_strlen($covenant) > 40) throw new RuntimeException('请先单独确认当前协议版本。', 422);
    return onboardingOperation($db, $uid, 'session.complete', $key, ['session_id' => $sessionId, 'expected' => $expected, 'covenant_version' => $covenant], function () use ($db, $uid, $sessionId, $expected, $covenant) {
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        if (!$session) throw new RuntimeException('引导会话不存在。', 404);
        if ((int)$session['revision'] !== $expected) throw new RuntimeException('引导会话已变化，请刷新。', 409);
        if ((string)$session['status'] === 'completed') return onboardingSessionPublic($db, $session) + ['already_completed' => true];
        if (!onboardingTaskCompleteAvailable($db,$session)) throw new RuntimeException('这项任务尚未完成。资料和草稿已保留，可以稍后继续。',409);
        $planMode = (string)$session['task_kind'] === 'plan_import' ? 'parse_plan' : 'generate_plan';
        $db->prepare("INSERT INTO onboarding(user_id,plan_mode,covenant_version,started_at,updated_at,completed_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE covenant_version=VALUES(covenant_version),completed_at=COALESCE(completed_at,UTC_TIMESTAMP()),updated_at=UTC_TIMESTAMP()")
            ->execute([$uid, $planMode, $covenant]);
        $db->prepare("UPDATE user_onboarding_sessions SET status='completed',completed_at=UTC_TIMESTAMP(),covenant_version=?,covenant_accepted_at=UTC_TIMESTAMP(),revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")
            ->execute([$covenant, $uid, $sessionId]);
        $session = onboardingSessionRead($db, $uid, $sessionId, true);
        return onboardingSessionPublic($db, $session) + ['completed' => true, 'user' => userPayload($db, $uid)];
    });
}

/** Onboarding status for GET /me/onboarding/v2 (empty is a success state). */
function onboardingState(PDO $db, int $uid): array {
    $settings = onboardingConfig($db);
    $session = onboardingActiveSession($db, $uid);
    $usage = onboardingAssistUsage($db, $uid);
    if (!$session) {
        return ['schema_version' => 1, 'basic_profile_status' => onboardingBasicStatus($db,$uid), 'session' => null, 'profile_revision' => profileFactsRead($db, $uid)['revision'],
            'capabilities' => ['assist_available' => false, 'assist_budget_remaining' => $usage['remaining'],
                'initial_plan_available' => false, 'membership_active' => false],
            'empty' => true, 'enabled' => $settings['enabled'], 'content_version' => $settings['content_version'],
            'content' => $settings['content'], 'assist_usage' => $usage, 'prompt_version' => ONBOARDING_PROMPT_VERSION];
    }
    $public = onboardingSessionPublic($db, $session);
    $public['assist_usage'] = $usage;
    $public['enabled'] = $settings['enabled'];
    $public['empty'] = false;
    return $public;
}

/** General (non-onboarding) profile change preview/confirm for existing members. */
function profileChangePreview(PDO $db, array $user, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expected = $body['expected_profile_revision'] ?? null;
    if (!is_int($expected)) throw new RuntimeException('缺少资料版本。', 422);
    if (!is_array($body['changes'] ?? null) || !array_is_list($body['changes']) || count($body['changes'])>30) throw new RuntimeException('资料改动需为最多30项的列表。', 422);
    $planStart=$body['plan_start_date']??null;
    if($planStart!==null){
        if(!is_string($planStart)||!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$planStart))throw new RuntimeException('计划起始日不正确。',422);
        $parsed=DateTimeImmutable::createFromFormat('!Y-m-d',$planStart,new DateTimeZone('UTC'));
        if(!$parsed||$parsed->format('Y-m-d')!==$planStart||$planStart<gmdate('Y-m-d'))throw new RuntimeException('计划起始日需为今天或未来日期。',422);
    }
    return onboardingOperation($db, $uid, 'profile.change.preview', $key, ['expected' => $expected, 'changes' => $body['changes'],'plan_start_date'=>$planStart], function () use ($db, $uid, $body, $expected, $key, $planStart) {
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== $expected) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
        $normalized = []; $seenFields=[];
        foreach ($body['changes'] as $change) {
            if (!is_array($change) || !is_string($change['field'] ?? null)) throw new RuntimeException('资料改动格式不正确。', 422);
            if(array_diff(array_keys($change),['field','value','unit','measurement_kind','observed_at']))throw new RuntimeException('资料改动包含未允许字段。',422);
            if(isset($seenFields[$change['field']]))throw new RuntimeException('同一资料字段不能重复。',422);
            $seenFields[$change['field']]=true;
            [$value, $unit] = profileFactNormalizeValue($change['field'], $change['value'] ?? null, $change['unit'] ?? null);
            $entry = ['field' => $change['field'], 'value' => $value, 'unit' => $unit];
            if (in_array($change['field'], ['profile_weight_kg', 'target_weight_kg'], true)) {
                if (isset($change['measurement_kind'])) {
                    if (!in_array($change['measurement_kind'], ['measured', 'estimated'], true)) throw new RuntimeException('体重性质不正确。', 422);
                    $entry['measurement_kind'] = $change['measurement_kind'];
                }
                if (isset($change['observed_at'])) {
                    [$observed] = profileFactNormalizeValue('weight_observed_at', $change['observed_at'], null);
                    $entry['observed_at'] = $observed;
                }
            }
            $normalized[] = $entry;
        }
        if (!$normalized) throw new RuntimeException('还没有可确认的资料。', 422);
        $proposalId = actionUUID('profile-change/' . $uid . '/' . $key);
        $expires = gmdate('Y-m-d H:i:s', time() + ONBOARDING_PROPOSAL_TTL_SECONDS);
        $db->prepare("INSERT INTO user_onboarding_proposals(proposal_id,user_id,session_id,kind,status,changes_json,before_json,profile_revision,session_revision,idempotency_key,expires_at,created_at,updated_at) VALUES(?,?,NULL,'profile','awaiting_confirmation',?,?,?,NULL,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
            ->execute([$proposalId, $uid, json_encode($normalized, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                json_encode(profileFactsPublicDocument($document)['facts'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                $expected, $key, $expires]);
        if($planStart!==null)$db->prepare('UPDATE user_onboarding_proposals SET plan_start_date=? WHERE user_id=? AND proposal_id=?')->execute([$planStart,$uid,$proposalId]);
        return ['proposal_id' => $proposalId, 'expires_at' => actionISO($expires), 'profile_revision' => $expected,
            'before' => profileFactsPublicDocument($document)['facts'],'plan_start_date'=>$planStart,
            'plan_adjustment_available' => true, 'plan_changed' => false];
    });
}

function profileChangeConfirm(PDO $db, array $user, array $body, string $key): array {
    $uid = (int)$user['id'];
    $proposalId = strtolower(trim((string)($body['proposal_id'] ?? '')));
    if (!preg_match('/^[0-9a-f-]{36}$/D', $proposalId)) throw new RuntimeException('资料提案编号不正确。', 422);
    if (!is_int($body['expected_profile_revision'] ?? null)) throw new RuntimeException('缺少资料版本。', 422);
    return onboardingOperation($db, $uid, 'profile.change.confirm', $key, ['proposal_id' => $proposalId, 'expected' => $body['expected_profile_revision']], function () use ($db, $uid, $proposalId, $body, $key) {
        $query = $db->prepare('SELECT * FROM user_onboarding_proposals WHERE user_id=? AND proposal_id=? FOR UPDATE');
        $query->execute([$uid, $proposalId]);
        $proposal = $query->fetch(PDO::FETCH_ASSOC);
        if (!$proposal || $proposal['session_id'] !== null) throw new RuntimeException('资料提案不存在。', 404);
        if ((string)$proposal['status'] === 'committed') return ['status' => 'committed', 'receipt' => ['command_id' => $proposal['command_id'], 'committed_at' => actionISO((string)$proposal['confirmed_at'])], 'effects' => ['profile_updated' => true, 'measurement_created' => false, 'plan_changed' => false], 'idempotent' => true];
        if ((string)$proposal['status'] !== 'awaiting_confirmation') throw new RuntimeException('资料提案已失效。', 409);
        if (strtotime((string)$proposal['expires_at'] . ' UTC') <= time()) throw new RuntimeException('资料提案已过期，请重新预览。', 410);
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== (int)$body['expected_profile_revision'] || (int)$document['revision'] !== (int)$proposal['profile_revision']) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
        $changes = json_decode((string)$proposal['changes_json'], true);
        if (!is_array($changes) || !$changes) throw new RuntimeException('资料提案内容不完整。', 422);
        $facts = profileFactsApplyChanges($document, $changes, 'confirmed', 'proposal/' . $proposalId, (int)$document['revision'] + 1);
        $newRevision = profileFactsWrite($db, $uid, $facts, (int)$document['revision']);
        profileFactsRestoreConfirmedFields($db,$uid,$changes ?? []);
        profileFactsProjectLegacy($db, $uid, $facts);
        onboardingReconcileConfirmedFields($db,$uid,$changes);
        $commandId = actionUUID('profile-confirm/' . $uid . '/' . $proposalId);
        $now = gmdate('Y-m-d H:i:s');
        $db->prepare("UPDATE user_onboarding_proposals SET status='committed',confirmed_at=?,command_id=?,updated_at=UTC_TIMESTAMP() WHERE proposal_id=?")->execute([$now, $commandId, $proposalId]);
        if (function_exists('trainingRecordAudit')) {
            trainingRecordAudit($db, $uid, $commandId, 'user', 'ProfileFacts.Confirm',
                hash('sha256', json_encode(['ProfileFacts.Confirm', $changes, $proposalId], JSON_UNESCAPED_UNICODE)),
                'profile', 'profile', (string)$document['revision'], (string)$newRevision,
                ['proposal_id' => $proposalId, 'fields' => array_map(fn($c) => $c['field'], $changes)], $key);
        }
        return ['status' => 'committed', 'profile_revision' => $newRevision,
            'receipt' => ['command_id' => $commandId, 'committed_at' => actionISO($now)],
            'effects' => ['profile_updated' => true, 'measurement_created' => false, 'plan_changed' => false],
            'profile' => profileFactsPublicDocument(['revision' => $newRevision, 'facts' => $facts])];
    });
}

function profileFactsClear(PDO $db, array $user, array $body, string $key): array {
    $uid = (int)$user['id'];
    $field = (string)($body['field'] ?? '');
    $expected = $body['expected_profile_revision'] ?? null;
    if (!is_int($expected)) throw new RuntimeException('缺少资料版本。', 422);
    return onboardingOperation($db, $uid, 'profile.clear', $key, ['field' => $field, 'expected' => $expected], function () use ($db, $uid, $field, $expected) {
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== $expected) throw new RuntimeException('资料刚刚发生变化，请刷新。', 409);
        $facts = profileFactsClearField($document, $field);
        $db->prepare('INSERT INTO user_profile_tombstones(user_id,field_name,revision,deleted_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE revision=VALUES(revision),deleted_at=UTC_TIMESTAMP()')->execute([$uid,$field,$expected+1]);
        $newRevision = profileFactsWrite($db, $uid, $facts, (int)$document['revision']);
        profileFactsProjectLegacy($db, $uid, $facts);
        onboardingReconcileConfirmedFields($db,$uid,[["field"=>$field]]);
        return ['status' => 'cleared', 'field' => $field, 'profile_revision' => $newRevision,
            'profile' => profileFactsPublicDocument(['revision' => $newRevision, 'facts' => $facts])];
    });
}

/**
 * Record that the first plan was adopted by the user. This binds a server
 * receipt to the existing job/app-state adoption; it never applies a plan by
 * itself and never creates a second business write.
 */
function onboardingPlanAdopted(PDO $db, array $user, string $sessionId, array $body, string $key): array {
    $uid = (int)$user['id'];
    $expected = $body['expected_session_revision'] ?? null;
    $jobId = strtolower(trim((string)($body['job_id'] ?? '')));
    $commandId = isset($body['command_id']) && is_string($body['command_id']) ? strtolower(trim($body['command_id'])) : null;
    if (!is_int($expected)) throw new RuntimeException('缺少会话版本。', 422);
    if (!preg_match('/^[0-9a-f-]{36}$/D', $jobId)) throw new RuntimeException('计划任务编号不正确。', 422);
    if ($commandId !== null && !preg_match('/^[0-9a-f-]{36}$/D', $commandId)) throw new RuntimeException('命令编号不正确。', 422);
    return onboardingOperation($db, $uid, 'session.plan_adopted', $key,
        ['session_id' => $sessionId, 'expected' => $expected, 'job_id' => $jobId, 'command_id' => $commandId],
        function () use ($db, $uid, $sessionId, $expected, $jobId, $commandId) {
            $session = onboardingSessionRead($db, $uid, $sessionId, true);
            if (!$session) throw new RuntimeException('引导会话不存在。', 404);
            if ((int)$session['revision'] !== $expected) throw new RuntimeException('引导会话已变化，请刷新。', 409);
            $job = $db->prepare("SELECT client_job_id,kind,completed_at,onboarding_session_id FROM ai_user_jobs WHERE user_id=? AND client_job_id=? AND kind IN ('generate_plan','parse_plan')");
            $job->execute([$uid, $jobId]);
            $jobRow = $job->fetch(PDO::FETCH_ASSOC);
            if (!$jobRow || $jobRow['completed_at'] === null) throw new RuntimeException('计划任务尚未在服务端完成。', 409);
            // A receipt is only issued after the adoption is visible in an
            // authoritative server record: a succeeded command, or the synced
            // app_state appliedAIJobs list. A local tap alone is not a receipt.
            $authoritative = false;
            if (($jobRow['onboarding_session_id'] ?? null) !== $sessionId && strtolower((string)($session['first_job_id'] ?? '')) !== $jobId) throw new RuntimeException('计划不属于本次引导。',409);
            if ($commandId !== null) {
                $op = $db->prepare("SELECT 1 FROM data_operations WHERE user_id=? AND operation_id=? AND status='succeeded' AND command_type='PlanVersion.Activate'");
                $op->execute([$uid, $commandId]);
                if (!$op->fetchColumn()) throw new RuntimeException('命令不是本次计划采用的有效凭据。',409);
            }
            $stateRow = $db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=?');
            $stateRow->execute([$uid]);
            $stored = $stateRow->fetch(PDO::FETCH_ASSOC) ?: [];
            $state = json_decode((string)($stored['state_json'] ?? ''), true);
            if (is_array($state) && ($state['_partitioned'] ?? null) === 2 && function_exists('cloudLegacyState')) $state = cloudLegacyState($db, $uid);
            if (is_array($state) && in_array($jobId, array_map('strtolower', is_array($state['appliedAIJobs'] ?? null) ? $state['appliedAIJobs'] : []), true)) $authoritative = true;
            $db->prepare('UPDATE user_onboarding_sessions SET first_job_id=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=? AND (first_job_id IS NULL OR first_job_id=?)')
                ->execute([$jobId, $uid, $sessionId, $jobId]);
            if (!$authoritative) {
                return onboardingSessionPublic($db, onboardingSessionRead($db, $uid, $sessionId, true))
                    + ['status' => 'pending_sync', 'receipt' => null,
                       'message' => '已在本机采用计划，但服务端尚未看到同步完成的记录；同步完成后才会生成回执。'];
            }
            $receipt = $commandId ?? actionUUID('onboarding-plan-receipt/' . $uid . '/' . $sessionId . '/' . $jobId);
            $db->prepare("UPDATE user_onboarding_sessions SET first_command_id=?,status='first_task_ready',revision=revision+1,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND id=?")
                ->execute([$receipt, $uid, $sessionId]);
            return onboardingSessionPublic($db, onboardingSessionRead($db, $uid, $sessionId, true))
                + ['status' => 'committed', 'receipt' => ['command_id' => $receipt, 'job_id' => $jobId, 'committed_at' => gmdate('c')]];
        });
}


function onboardingAssistRecentMessages(PDO $db, int $uid, string $sessionId): array {
    $query = $db->prepare('SELECT role,content,created_at FROM user_onboarding_messages WHERE user_id=? AND session_id=? ORDER BY id DESC LIMIT 12');
    $query->execute([$uid, $sessionId]);
    return array_reverse(array_map(fn($row) => ['role' => $row['role'], 'text' => $row['content'], 'created_at' => $row['created_at']], $query->fetchAll(PDO::FETCH_ASSOC)));
}

function profileProposalPublic(PDO $db,int $uid,string $id):array {
 $q=$db->prepare('SELECT proposal_id,session_id,session_revision,status,changes_json,before_json,profile_revision,expires_at,command_id,confirmed_at,plan_start_date FROM user_onboarding_proposals WHERE user_id=? AND proposal_id=?');$q->execute([$uid,$id]);$p=$q->fetch(PDO::FETCH_ASSOC);
 if(!$p)throw new RuntimeException('资料提案不存在。',404);
 $p['profile_revision']=(int)$p['profile_revision'];
 $p['session_revision']=$p['session_revision']===null?null:(int)$p['session_revision']+1;
 if($p['status']==='awaiting_confirmation'&&strtotime($p['expires_at'].' UTC')<=time())$p['status']='expired';
 $p['expires_at']=actionISO($p['expires_at']);
 $p['changes']=json_decode($p['changes_json'],true);$p['before']=json_decode($p['before_json'],true);unset($p['changes_json'],$p['before_json']);
 return $p;
}

function onboardingPendingProfileProposal(PDO $db,array $session):?array {
 if(empty($session['first_proposal_id'])||$session['status']!=='review')return null;
 $q=$db->prepare("SELECT * FROM user_onboarding_proposals WHERE user_id=? AND session_id=? AND proposal_id=? AND status='awaiting_confirmation'");$q->execute([$session['user_id'],$session['id'],$session['first_proposal_id']]);$p=$q->fetch(PDO::FETCH_ASSOC);
 if(!$p||strtotime($p['expires_at'].' UTC')<=time()||(int)$session['revision']!==(int)$p['session_revision']+1)return null;
 $before=json_decode($p['before_json'],true)?:[];$after=$before;
 foreach(json_decode($p['changes_json'],true)?:[] as $c)$after[$c['field']]=['value'=>$c['value'],'unit'=>$c['unit']??null,'source_kind'=>'draft'];
 return ['proposal_id'=>$p['proposal_id'],'expires_at'=>actionISO($p['expires_at']),'profile_revision'=>(int)$p['profile_revision'],'session_revision'=>(int)$p['session_revision']+1,'before'=>$before?:new stdClass(),'after'=>$after?:new stdClass(),'unknown_fields'=>[]];
}

/** Explicitly decline an owned proposal; no business fact or plan is mutated. */
function profileChangeDismiss(PDO $db,array $user,array $body,string $key):array {
 $uid=(int)$user['id'];$id=strtolower((string)($body['proposal_id']??''));
 if(!preg_match('/^[a-f0-9-]{36}$/D',$id))throw new RuntimeException('资料提案编号不正确。',422);
 return onboardingOperation($db,$uid,'profile.change.dismiss',$key,['proposal_id'=>$id],function()use($db,$uid,$id){
  $q=$db->prepare('SELECT status FROM user_onboarding_proposals WHERE user_id=? AND proposal_id=? FOR UPDATE');$q->execute([$uid,$id]);$status=$q->fetchColumn();
  if(!$status)throw new RuntimeException('资料提案不存在。',404);
  if($status==='committed')throw new RuntimeException('资料已确认，不能撤销为未采用；请重新预览资料变更。',409);
  $db->prepare("UPDATE user_onboarding_proposals SET status='dismissed',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=?")->execute([$uid,$id]);
  return ['status'=>'dismissed','proposal_id'=>$id,'profile_changed'=>false,'plan_changed'=>false];
 });
}
