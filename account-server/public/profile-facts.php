<?php
declare(strict_types=1);

/**
 * Authoritative V2 profile facts.
 *
 * Every confirmed field lives in user_profile_documents. The legacy profiles
 * table and the client's app_state.profile are compatibility projections only:
 * they may be refreshed from the facts document, never the other way around for
 * an already-confirmed field. Legacy PUT /me/onboarding and PUT /me/state are
 * imported with source_kind=legacy_recorded; they do not receive a confirmation
 * time and do not masquerade as verified measurements.
 *
 * Models may submit candidates elsewhere (onboarding drafts); this file is the
 * only place that writes a confirmed fact, and callers must have an explicit
 * user-confirmed proposal id.
 */

const PROFILE_FACTS_SCHEMA_VERSION = 1;
const PROFILE_FACT_SOURCES = ['confirmed', 'legacy_recorded'];
const PROFILE_TARGET_TASKS = ['plan_create', 'plan_import', 'meal_log', 'workout_log', 'explore', 'nutrition_goal'];

function profileFactFieldDefinitions(): array {
    return [
        'nickname' => ['type'=>'text','maxLength'=>40,'projection'=>'nickname'],
        'personal_preferences' => ['type'=>'text','maxLength'=>500],
        'equipment_other' => ['type'=>'text','maxLength'=>100,'projection'=>'equipmentOther'],
        'home_training_days' => ['type'=>'int_list','itemsMin'=>1,'itemsMax'=>7,'maxItems'=>7,'projection'=>'homeTrainingDays'],
        'goal' => ['type' => 'enum', 'values' => ['增肌塑形', '减脂瘦身', '紧致线条', '提升力量', '养成运动习惯'], 'projection' => 'goal'],
        'experience' => ['type' => 'enum', 'values' => ['新手', '有基础', '进阶'], 'projection' => 'experience'],
        'venue' => ['type' => 'enum', 'values' => ['健身房', '在家', '两者都有'], 'projection' => 'venue'],
        'equipment' => ['type' => 'string_list', 'maxItems' => 10, 'maxLength' => 40, 'projection' => 'equipment'],
        'equipment_exclusions' => ['type' => 'string_list', 'maxItems' => 10, 'maxLength' => 40,'projection'=>'equipmentExclusions'],
        'days_per_week' => ['type' => 'int', 'min' => 1, 'max' => 7, 'unit' => 'days_per_week', 'projection' => 'daysPerWeek'],
        'training_days' => ['type' => 'int_list', 'itemsMin' => 1, 'itemsMax' => 7, 'maxItems' => 7, 'projection' => 'trainingDays'],
        'session_minutes' => ['type' => 'int', 'min' => 15, 'max' => 180, 'unit' => 'minutes', 'projection' => 'sessionMinutes'],
        'age_group' => ['type' => 'enum', 'values' => ['adult', 'minor'], 'projection'=>'ageGroup'],
        'age_years' => ['type' => 'int', 'min' => 13, 'max' => 100, 'unit' => 'years', 'projection' => 'age'],
        'sex_for_nutrition' => ['type' => 'enum', 'values' => ['男', '女', '不愿提供'], 'projection' => 'gender'],
        'height_cm' => ['type' => 'number', 'min' => 50, 'max' => 250, 'unit' => 'cm', 'projection' => 'height'],
        'profile_weight_kg' => ['type' => 'number', 'min' => 20, 'max' => 400, 'unit' => 'kg', 'projection' => 'weight'],
        'target_weight_kg' => ['type' => 'number', 'min' => 20, 'max' => 400, 'unit' => 'kg', 'projection' => 'targetWeightKg'],
        'weight_measurement_kind' => ['type' => 'enum', 'values' => ['measured', 'estimated']],
        'weight_observed_at' => ['type' => 'date'],
        'limitations' => ['type' => 'text', 'maxLength' => 500, 'projection' => 'limitations'],
        'nutrition_context' => ['type' => 'enum', 'values' => ['普通成人', '孕期或哺乳期', '需按医生建议饮食'], 'projection' => 'nutritionContext'],
        'daily_activity' => ['type' => 'enum', 'values' => ['主要久坐', '经常站立走动', '日常体力活动较多'], 'projection' => 'dailyActivity'],
        'focus' => ['type' => 'text', 'maxLength' => 100, 'projection' => 'focus'],
    ];
}

function profileFactTaskFields(string $taskKind): array {
    return match ($taskKind) {
        'plan_create' => ['goal', 'experience', 'venue', 'equipment', 'equipment_exclusions', 'equipment_other', 'home_training_days', 'days_per_week', 'training_days', 'session_minutes', 'age_group', 'age_years', 'limitations', 'focus'],
        'plan_import' => ['goal', 'experience', 'venue', 'equipment', 'session_minutes', 'age_group'],
        'meal_log' => [],
        'workout_log' => [],
        'explore' => [],
        'nutrition_goal' => ['goal', 'sex_for_nutrition', 'age_years', 'age_group', 'height_cm', 'profile_weight_kg', 'target_weight_kg', 'daily_activity', 'nutrition_context'],
        default => [],
    };
}

function profileFactTaskRequired(string $taskKind, array $draft = []): array {
    $required = match ($taskKind) {
        'plan_create' => ['goal', 'experience', 'venue', 'days_per_week', 'training_days', 'session_minutes', 'age_group'],
        'plan_import' => ['plan_text'],
        'meal_log' => ['meal_date', 'meal_category', 'meal_description'],
        'workout_log' => ['workout_date', 'exercise'],
        'explore' => [],
        'nutrition_goal' => ['sex_for_nutrition', 'age_years', 'height_cm', 'profile_weight_kg', 'daily_activity'],
        default => [],
    };
    $venue = $draft['fields']['venue']['value'] ?? null;
    if ($taskKind === 'plan_create' && in_array($venue, ['在家', '两者都有'], true)) $required[] = 'equipment';
    return $required;
}

function profileFactNormalizeValue(string $field, mixed $value, ?string $unit): array {
    $definition = profileFactFieldDefinitions()[$field] ?? null;
    if ($definition === null) throw new RuntimeException('资料字段不正确。', 422);
    $type = $definition['type'];
    if ($type === 'enum') {
        if (!is_string($value) || !in_array($value, $definition['values'], true)) throw new RuntimeException('资料选项不正确。', 422);
        return [$value, null];
    }
    if ($type === 'text') {
        if (!is_string($value)) throw new RuntimeException('资料内容格式不正确。', 422);
        $value = trim($value);
        if ($value === '' || mb_strlen($value) > (int)$definition['maxLength']) throw new RuntimeException('资料内容长度不正确。', 422);
        if (preg_match('/[\x00-\x1F\x7F]/u', $value)) throw new RuntimeException('资料内容包含不可用字符。', 422);
        return [$value, null];
    }
    if ($type === 'string_list') {
        if (!is_array($value) || !array_is_list($value) || count($value) > (int)$definition['maxItems']) throw new RuntimeException('器械列表不正确。', 422);
        $out = [];
        foreach ($value as $item) {
            if (!is_string($item)) throw new RuntimeException('器械名称不正确。', 422);
            $item = trim($item);
            if ($item === '' || mb_strlen($item) > (int)($definition['maxLength'] ?? 40)) throw new RuntimeException('器械名称不正确。', 422);
            if (!in_array($item, $out, true)) $out[] = $item;
        }
        return [$out, null];
    }
    if ($type === 'int_list') {
        if (!is_array($value) || !array_is_list($value) || count($value) > (int)$definition['maxItems']) throw new RuntimeException('训练日不正确。', 422);
        $out = [];
        foreach ($value as $item) {
            if (!is_int($item) || $item < (int)$definition['itemsMin'] || $item > (int)$definition['itemsMax']) throw new RuntimeException('训练日不正确。', 422);
            if (!in_array($item, $out, true)) $out[] = $item;
        }
        sort($out);
        return [$out, null];
    }
    if ($type === 'int') {
        if (!is_int($value) || $value < (int)$definition['min'] || $value > (int)$definition['max']) throw new RuntimeException('资料数值不正确。', 422);
        return [$value, $definition['unit'] ?? null];
    }
    if ($type === 'number') {
        if (is_bool($value) || (!is_int($value) && !is_float($value)) || !is_finite((float)$value)) throw new RuntimeException('资料数值不正确。', 422);
        $value = (float)$value;
        if ($value < (float)$definition['min'] || $value > (float)$definition['max']) throw new RuntimeException('资料数值不正确。', 422);
        return [$value, $definition['unit'] ?? null];
    }
    if ($type === 'date') {
        if (!is_string($value) || !preg_match('/^\d{4}-\d{2}-\d{2}$/D', $value)) throw new RuntimeException('日期格式不正确。', 422);
        $date = DateTimeImmutable::createFromFormat('!Y-m-d', $value, new DateTimeZone('UTC'));
        if (!$date || $date->format('Y-m-d') !== $value) throw new RuntimeException('日期格式不正确。', 422);
        if ($date > new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai'))) throw new RuntimeException('测量日期不能是未来。', 422);
        return [$value, null];
    }
    throw new RuntimeException('资料字段类型不支持。', 422);
}

function profileFactsEmptyDocument(): array {
    return ['schema_version' => PROFILE_FACTS_SCHEMA_VERSION, 'revision' => 0, 'facts' => []];
}

function profileFactsRead(PDO $db, int $userId, bool $forUpdate = false): array {
    $query = $db->prepare('SELECT schema_version,revision,facts_json FROM user_profile_documents WHERE user_id=?' . ($forUpdate ? ' FOR UPDATE' : ''));
    $query->execute([$userId]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    if (!$row) return profileFactsEmptyDocument();
    $facts = json_decode((string)$row['facts_json'], true);
    return [
        'schema_version' => (int)$row['schema_version'],
        'revision' => (int)$row['revision'],
        'facts' => is_array($facts) ? $facts : [],
    ];
}

function profileFactsWrite(PDO $db, int $userId, array $facts, int $expectedRevision): int {
    $query = $db->prepare('SELECT revision FROM user_profile_documents WHERE user_id=? FOR UPDATE');
    $query->execute([$userId]);
    $current = $query->fetchColumn();
    if ($current === false) {
        if ($expectedRevision !== 0) throw new RuntimeException('资料版本已变化，请刷新后核对。', 409);
        $db->prepare('INSERT INTO user_profile_documents(user_id,schema_version,revision,facts_json,updated_at) VALUES(?,?,1,?,UTC_TIMESTAMP())')
            ->execute([$userId, PROFILE_FACTS_SCHEMA_VERSION, json_encode($facts, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        return 1;
    }
    if ((int)$current !== $expectedRevision) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
    $next = $expectedRevision + 1;
    $db->prepare('UPDATE user_profile_documents SET schema_version=?,revision=?,facts_json=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?')
        ->execute([PROFILE_FACTS_SCHEMA_VERSION, $next, json_encode($facts, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR), $userId]);
    return $next;
}

function profileFactsPublicDocument(array $document): array {
    $facts = [];
    foreach (($document['facts'] ?? []) as $field => $fact) {
        if (!is_array($fact)) continue;
        $facts[$field] = [
            'field' => $field,
            'value' => $fact['value'] ?? null,
            'unit' => $fact['unit'] ?? null,
            'source_kind' => (string)($fact['source_kind'] ?? 'legacy_recorded'),
            'source_ref' => $fact['source_ref'] ?? null,
            'confirmed_at' => $fact['confirmed_at'] ?? null,
            'revision' => (int)($fact['revision'] ?? 0),
            'measurement_kind' => $fact['measurement_kind'] ?? null,
            'observed_at' => $fact['observed_at'] ?? null,
            'updated_at' => $fact['updated_at'] ?? null,
        ];
    }
    ksort($facts);
    return ['schema_version' => PROFILE_FACTS_SCHEMA_VERSION, 'revision' => (int)($document['revision'] ?? 0), 'facts' => $facts];
}

function profileFactsTaskSummary(array $document, string $taskKind): array {
    $out = [];
    foreach (profileFactTaskFields($taskKind) as $field) {
        if (isset($document['facts'][$field])) $out[$field] = $document['facts'][$field]['value'];
    }
    return $out;
}

/** Merge only the fields that were explicitly chosen; never invent missing keys. */
function profileFactsApplyChanges(array $document, array $changes, string $sourceKind, ?string $sourceRef, int $nextRevision): array {
    $facts = is_array($document['facts'] ?? null) ? $document['facts'] : [];
    // A new profile weight must not inherit the date/type of an older reading.
    // Historical body measurements are stored separately and are never changed here.
    $fields = array_column($changes, 'field');
    foreach ($changes as $change) {
        if (($change['field'] ?? '') !== 'profile_weight_kg') continue;
        if (!isset($change['measurement_kind']) && !in_array('weight_measurement_kind', $fields, true)) unset($facts['weight_measurement_kind']);
        if (!isset($change['observed_at']) && !in_array('weight_observed_at', $fields, true)) unset($facts['weight_observed_at']);
    }
    $now = gmdate('c');
    foreach ($changes as $change) {
        $field = (string)($change['field'] ?? '');
        [$value, $unit] = profileFactNormalizeValue($field, $change['value'] ?? null, $change['unit'] ?? null);
        $fact = [
            'value' => $value, 'unit' => $unit, 'source_kind' => $sourceKind,
            'source_ref' => $sourceRef, 'confirmed_at' => $sourceKind === 'confirmed' ? $now : null,
            'revision' => $nextRevision, 'updated_at' => $now,
        ];
        if (in_array($field, ['profile_weight_kg', 'target_weight_kg'], true) && !empty($change['measurement_kind'])) {
            $fact['measurement_kind'] = $change['measurement_kind'];
        }
        if (!empty($change['observed_at'])) $fact['observed_at'] = $change['observed_at'];
        $facts[$field] = $fact;
    }
    if(isset($facts['age_years'],$facts['age_group'])){
        $group=(int)$facts['age_years']['value']<18?'minor':'adult';
        if($facts['age_group']['value']!==$group)throw new RuntimeException('年龄与适用年龄范围不一致，请核对。',422);
    }
    if (isset($facts['home_training_days'],$facts['training_days']) && array_diff($facts['home_training_days']['value'],$facts['training_days']['value'])) throw new RuntimeException('在家训练日必须属于可训练日期。',422);
    return $facts;
}

function profileFactsClearField(array $document, string $field): array {
    if (!isset(profileFactFieldDefinitions()[$field])) throw new RuntimeException('资料字段不正确。', 422);
    $facts = is_array($document['facts'] ?? null) ? $document['facts'] : [];
    unset($facts[$field]);
    return $facts;
}

/**
 * Project confirmed facts onto the legacy profiles row only when the row
 * already exists, or when enough legacy-required fields are genuinely
 * confirmed to satisfy the old NOT NULL contract. Missing fields are never
 * filled with defaults.
 */
function profileFactsProjectLegacy(PDO $db, int $userId, array $facts, bool $syncState = true): void {
    if ($syncState) profileFactsProjectState($db,$userId,$facts);
    $map = [];
    foreach (profileFactFieldDefinitions() as $field => $definition) {
        if (!isset($definition['projection']) || !isset($facts[$field])) continue;
        if ($field === 'sex_for_nutrition' && !in_array($facts[$field]['value'], ['男', '女'], true)) continue;
        $map[$definition['projection']] = $facts[$field]['value'];
    }
    if (!$map) return;
    $exists = $db->prepare('SELECT 1 FROM profiles WHERE user_id=?');
    $exists->execute([$userId]);
    $rowExists = (bool)$exists->fetchColumn();
    if (!$rowExists) {
        $required = ['gender', 'age', 'height', 'weight', 'goal', 'experience', 'venue', 'daysPerWeek'];
        foreach ($required as $key) if (!array_key_exists($key, $map)) return;
    }
    if ($rowExists && isset($map['nickname'])) $db->prepare('UPDATE profiles SET nickname=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?')->execute([$map['nickname'],$userId]);
    $columns = ['gender' => 'gender', 'age' => 'age', 'height' => 'height_cm', 'weight' => 'weight_kg',
        'goal' => 'goal', 'experience' => 'experience', 'venue' => 'venue', 'daysPerWeek' => 'days_per_week',
        'focus' => 'focus', 'equipment' => 'equipment', 'sessionMinutes' => 'session_minutes',
        'limitations' => 'limitations'];
    $sets = []; $args = [];
    foreach ($columns as $key => $column) {
        if (!array_key_exists($key, $map)) continue;
        $value = $map[$key];
        $sets[] = "`$column`=?";
        $args[] = is_array($value) ? implode('、', $value) : $value;
    }
    if (isset($map['trainingDays']) && is_array($map['trainingDays'])) { $sets[] = '`training_days`=?'; $args[] = implode(',', $map['trainingDays']); }
    if (!$sets) return;
    if ($rowExists) {
        $args[] = $userId;
        $db->prepare('UPDATE profiles SET ' . implode(',', $sets) . ',updated_at=UTC_TIMESTAMP() WHERE user_id=?')->execute($args);
    } else {
        $columnsList = [];
        foreach ($sets as $set) {
            preg_match('/`([^`]+)`/', $set, $m);
            $columnsList[] = '`' . $m[1] . '`';
        }
        $one = array_fill(0, count($columnsList), '?');
        $db->prepare('INSERT INTO profiles(user_id,nickname,' . implode(',', $columnsList) . ',updated_at) VALUES(?,?,' . implode(',', $one) . ',UTC_TIMESTAMP())')
            ->execute(array_merge([$userId, $map['nickname'] ?? '薄肌成员'], $args));
    }
}

/**
 * Legacy full questionnaire / cloud profile import. It never overwrites a
 * newer confirmed fact. `$sourceKind` is legacy_recorded for sync imports and
 * confirmed only for the explicit legacy PUT questionnaire.
 */
function profileFactsImportLegacyProfile(PDO $db, int $userId, array $profile, string $sourceKind = 'legacy_recorded', ?string $sourceRef = 'legacy_profile'): void {
    if (!in_array($sourceKind, PROFILE_FACT_SOURCES, true)) $sourceKind = 'legacy_recorded';
    $document = profileFactsRead($db, $userId, true);
    $facts = is_array($document['facts'] ?? null) ? $document['facts'] : [];
    $factState = is_array($profile['factState'] ?? null) ? $profile['factState'] : null;
    $now = gmdate('c');
    $t = $db->prepare('SELECT field_name FROM user_profile_tombstones WHERE user_id=?');$t->execute([$userId]);$withdrawn=array_flip($t->fetchAll(PDO::FETCH_COLUMN));
    $next = (int)$document['revision'] + 1;
    $changed = false;
    $mapping = [
        'goal' => $profile['goal'] ?? null, 'experience' => $profile['experience'] ?? null,
        'venue' => $profile['venue'] ?? null, 'focus' => $profile['focus'] ?? null,
        'days_per_week' => $profile['daysPerWeek'] ?? null, 'session_minutes' => $profile['sessionMinutes'] ?? null,
        'height_cm' => $profile['height'] ?? null, 'profile_weight_kg' => $profile['weight'] ?? null,
        'age_years' => $profile['age'] ?? null, 'sex_for_nutrition' => $profile['gender'] ?? null,
        'limitations' => $profile['limitations'] ?? null,
        'equipment_other' => $profile['equipmentOther'] ?? null,
        'home_training_days' => isset($profile['trainingDays']) ? array_values(array_intersect($profile['homeTrainingDays'] ?? [], $profile['trainingDays'])) : null,
        'nutrition_context' => $profile['nutritionContext'] ?? null, 'daily_activity' => $profile['dailyActivity'] ?? null,
    ];
    foreach ($mapping as $field => $value) {
        if(isset($withdrawn[$field]))continue;
        if ($value === null || $value === '') continue;
        if ($factState !== null) {
            $meta = $factState[$field] ?? null;
            if (!is_array($meta) || !in_array(($meta['source_kind'] ?? $meta['sourceKind'] ?? 'unknown'),['confirmed','legacy_recorded'],true)) continue;
        }
        if (isset($facts[$field]) && ($facts[$field]['source_kind'] ?? '') === 'confirmed' && $sourceKind === 'legacy_recorded') continue;
        try { [$clean, $unit] = profileFactNormalizeValue($field, $value, null); }
        catch (Throwable) { continue; }
        if (isset($facts[$field]) && $facts[$field]['value'] === $clean) continue;
        $facts[$field] = ['value' => $clean, 'unit' => $unit, 'source_kind' => $sourceKind,
            'source_ref' => $sourceRef, 'confirmed_at' => $sourceKind === 'confirmed' ? $now : null,
            'revision' => $next, 'updated_at' => $now];
        $changed = true;
    }
    foreach (['equipment', 'training_days'] as $field) {
        if(isset($withdrawn[$field]))continue;
        $value = $field === 'equipment' ? ($profile['equipment'] ?? null) : ($profile['trainingDays'] ?? null);
        if ($value === null || $value === '' || $value === []) continue;
        if ($factState !== null) {
            $meta = $factState[$field] ?? null;
            if (!is_array($meta) || !in_array(($meta['source_kind'] ?? $meta['sourceKind'] ?? 'unknown'),['confirmed','legacy_recorded'],true)) continue;
        }
        if ($field === 'equipment' && is_string($value)) $value = array_values(array_filter(explode('、', $value), fn($x) => $x !== ''));
        try { [$clean, $unit] = profileFactNormalizeValue($field, $value, null); }
        catch (Throwable) { continue; }
        if (isset($facts[$field]) && $facts[$field]['value'] === $clean && ($facts[$field]['source_kind'] ?? '') === $sourceKind) continue;
        if (isset($facts[$field]) && ($facts[$field]['source_kind'] ?? '') === 'confirmed' && $sourceKind === 'legacy_recorded') continue;
        $facts[$field] = ['value' => $clean, 'unit' => $unit, 'source_kind' => $sourceKind,
            'source_ref' => $sourceRef, 'confirmed_at' => $sourceKind === 'confirmed' ? $now : null,
            'revision' => $next, 'updated_at' => $now];
        $changed = true;
    }
    if (!$changed) return;
    $newRevision = profileFactsWrite($db, $userId, $facts, (int)$document['revision']);
    profileFactsProjectLegacy($db, $userId, $facts, $sourceRef !== 'cloud_sync');
}

/** Profile-fact summary for the coach/onboarding prompt. Only allowed task fields. */
function profileFactsForPrompt(array $document, string $taskKind): array {
    $out = [];
    foreach (profileFactTaskFields($taskKind) as $field) {
        $fact = $document['facts'][$field] ?? null;
        if (!is_array($fact)) continue;
        $out[$field] = ['value' => $fact['value'], 'unit' => $fact['unit'] ?? null,
            'source_kind' => $fact['source_kind'] ?? 'legacy_recorded',
            'observed_at' => $fact['observed_at'] ?? null];
    }
    return $out;
}

/**
 * 急性风险词表（唯一来源）。
 *
 * 同一份有序选择同时构造「否定剥离」和「命中匹配」两侧。2026-11 P0 回归的根因正是
 * 两份列表分叉：匹配侧早已包含 晕厥/晕倒/骨折/高烧/发热/剧痛/眼前发黑/心悸/心慌，
 * 而否定表只覆盖 8 个短语，于是「没有骨折」什么都没被剥掉、随后被当成阳性拦截。
 * 此后新增任何风险词都只会改动这一处，两侧不会再不同步。
 *
 * 前缀否定只处理紧邻情形，语义对齐 backend/fitness_intelligence.py::_signal_negated；
 * 子句级分析（否定范围、双重否定、既往史）以该 Python 实现为准，不要在此分叉。
 */
function profileFactAcutePattern(): string {
    return '胸部疼痛|胸前区疼痛|(?:喘|呼吸).{0,8}(?:厉害|困难|急促)|(?:说不出|无法说|不能说).{0,4}(?:整句|完整)|不能呼吸|胸痛|胸闷|喘不上气|呼吸困难|晕厥|晕倒|骨折|高烧|发热|剧痛|眼前发黑|心悸|心慌|怀孕|孕期|哺乳';
}

/** 剥离成员在同一段文字里明确否认掉的急性词，例如「没有骨折」「无晕厥」。 */
function profileFactStripDeniedAcute(string $limitations): string {
    // 否定词按长度优先（不再有 先于 不），避免被拆成半个否定。
    $denials = '没有|不再有|没|无|否认|未见|不';
    $stripped = preg_replace('/(?:' . $denials . ')(?:' . profileFactAcutePattern() . ')/u', '', $limitations);
    // 正则失败（例如非法 UTF-8）时保留原文：宁可照常拦截，也不静默放行。
    return is_string($stripped) ? $stripped : $limitations;
}

function profileFactSafety(array $document, array $draft): array {
    // New unconfirmed risk must never be hidden by an older confirmed "none".
    $limitationValues = [$document['facts']['limitations']['value'] ?? '', $draft['fields']['limitations']['value'] ?? ''];
    $nutritionValues = [$document['facts']['nutrition_context']['value'] ?? '', $draft['fields']['nutrition_context']['value'] ?? ''];
    $acute = false;
    foreach ($limitationValues as $limitations) {
        $screened = profileFactStripDeniedAcute((string)$limitations);
        if (preg_match('/' . profileFactAcutePattern() . '/u', $screened) === 1) $acute = true;
    }
    $special = (bool)array_intersect($nutritionValues, ['孕期或哺乳期', '需按医生建议饮食']);
    $blocked = $acute || $special;
    return [
        'safety_blocked' => $blocked,
        'safety_message' => $blocked
            ? ($acute
                ? '你填写的情况不适合由应用直接安排训练强度。请先咨询医生或专业人员；现在仍可记录饮食与休息，或仅浏览一般功能。'
                : '你填写的饮食评估情况需要专业评估，暂不生成个性化训练强度或热量处方；仍可记录饮食和一般活动。')
            : null,
    ];
}

/** The only confirmed-fact write entry used by onboarding/profile change routes. */
function profileFactsConfirmChanges(PDO $db, array $user, array $changes, array $expected, ?array $session, string $operation): array {
    $uid = (int)$user['id'];
    $db->beginTransaction();
    try {
        lockActiveUser($db, $uid);
        $document = profileFactsRead($db, $uid, true);
        if ((int)$document['revision'] !== (int)$expected['profile_revision']) throw new RuntimeException('资料刚刚发生变化，请核对最新内容。', 409);
        if ($session !== null) {
            $locked = $db->prepare('SELECT revision,status FROM user_onboarding_sessions WHERE user_id=? AND id=? FOR UPDATE');
            $locked->execute([$uid, (string)$session['id']]);
            $row = $locked->fetch(PDO::FETCH_ASSOC);
            if (!$row || (int)$row['revision'] !== (int)$expected['session_revision']) throw new RuntimeException('引导会话已变化，请重新核对。', 409);
        }
        $next = (int)$document['revision'] + 1;
        $facts = profileFactsApplyChanges($document, $changes, 'confirmed', $operation, $next);
        $newRevision = profileFactsWrite($db, $uid, $facts, (int)$document['revision']);
        profileFactsRestoreConfirmedFields($db,$uid,$changes);
        profileFactsProjectLegacy($db, $uid, $facts);
        $commandId = actionUUID('profile-confirm/' . $uid . '/' . $operation);
        if (function_exists('trainingRecordAudit')) {
            trainingRecordAudit($db, $uid, $commandId, 'user', 'ProfileFacts.Confirm',
                hash('sha256', json_encode(['ProfileFacts.Confirm', $changes], JSON_UNESCAPED_UNICODE)),
                'profile', 'profile', (string)$document['revision'], (string)$newRevision,
                ['fields' => array_values(array_map(fn($change) => (string)$change['field'], $changes)), 'source' => $operation], $operation);
        }
        $db->commit();
        return ['command_id' => $commandId, 'profile_revision' => $newRevision, 'facts' => $facts];
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

/** Public field metadata for native controls; never includes internal allowlists. */
function profileFactDefinitionsPublic(): array {
    $out = [];
    foreach (profileFactFieldDefinitions() as $field => $definition) {
        $entry = ['type' => $definition['type']];
        foreach (['values', 'min', 'max', 'maxLength', 'unit'] as $key) {
            if (array_key_exists($key, $definition)) $entry[$key] = $definition[$key];
        }
        $out[$field] = $entry;
    }
    return $out;
}

/** Keep the legacy full-state profile projection aligned with confirmed facts. */
function profileFactsOverlayStateProfile(array $profile, array $facts): array {
    foreach (profileFactFieldDefinitions() as $field => $definition) {
        if (!isset($definition['projection']) || !isset($facts[$field])) continue;
        $value = $facts[$field]['value'];
        if ($field === 'sex_for_nutrition' && !in_array($value, ['男', '女'], true)) { unset($profile['gender']); continue; }
        $projection = $definition['projection'];
        if ($projection === 'trainingDays') $profile['trainingDays'] = is_array($value) ? array_values(array_map('intval', $value)) : [];
        elseif ($projection === 'equipment') $profile['equipment'] = is_array($value) ? implode('、', $value) : $value;
        elseif ($projection === 'height') $profile['height'] = (float)$value;
        elseif ($projection === 'weight') $profile['weight'] = (float)$value;
        else $profile[$projection] = $value;
    }
    $meta=[];foreach($facts as $field=>$fact)$meta[$field]=['sourceKind'=>$fact['source_kind']??'legacy_recorded','revision'=>$fact['revision']??0];
    $profile['factState']=$meta?:new stdClass();
    return $profile;
}


function profileFactsRestoreConfirmedFields(PDO $db,int $uid,array $changes):void {
    $q=$db->prepare('DELETE FROM user_profile_tombstones WHERE user_id=? AND field_name=?');
    foreach($changes as $c)if(isset($c['field']))$q->execute([$uid,$c['field']]);
}
function profileFactsProjectState(PDO $db,int $uid,array $facts):void {
    $q=$db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE');$q->execute([$uid]);$row=$q->fetch(PDO::FETCH_ASSOC);
    if(!$row)return;
    $state=json_decode($row['state_json'],true,64,JSON_THROW_ON_ERROR);
    $before=$state['profile']??[];
    $state['profile']=profileFactsOverlayStateProfile(is_array($before)?$before:[],$facts);
    if(json_encode($before)===json_encode($state['profile']))return;
    if(($state['_partitioned']??null)===2){
        require_once __DIR__.'/cloud-parts.php';
        $meta=$state;unset($meta['_partitioned'],$meta['days'],$meta['aiJobs']);cloudPartPut($db,$uid,'meta',$meta);
    }
    if(isset($state['days'])&&$state['days']===[])$state['days']=new stdClass();
    $db->prepare('UPDATE app_states SET revision=revision+1,state_json=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?')->execute([json_encode($state,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),$uid]);
}

/** Planning reads the authoritative facts; body/safety values cannot be client overrides. */
function profileFactsPlanningPayload(PDO $db,int $uid,array $raw=[],bool $allowPlanningOverrides=false):array {
 $doc=profileFactsRead($db,$uid);$facts=$doc['facts'];$profile=[];
 $map=['goal'=>'goal','experience'=>'experience','venue'=>'venue','focus'=>'focus','limitations'=>'limitations','session_minutes'=>'sessionMinutes','age_years'=>'age','height_cm'=>'height','profile_weight_kg'=>'weight','equipment'=>'equipment','equipment_exclusions'=>'equipmentExclusions','equipment_other'=>'equipmentOther','home_training_days'=>'homeTrainingDays','training_days'=>'trainingDays','age_group'=>'ageGroup'];
 foreach($map as $field=>$key)if(isset($facts[$field]))$profile[$key]=$facts[$field]['value'];
 if(isset($profile['age'])&&!isset($profile['ageGroup']))$profile['ageGroup']=(int)$profile['age']<18?'minor':'adult';
 if($allowPlanningOverrides){
   foreach(['goal','experience','venue','focus','session_minutes','equipment','equipment_other','home_training_days','training_days'] as $field){$key=$map[$field];if(array_key_exists($key,$raw)){[$value]=profileFactNormalizeValue($field,$raw[$key],null);$profile[$key]=$value;}}
 }
 $profile['trainingDays']=$profile['trainingDays']??[];$profile['daysPerWeek']=count($profile['trainingDays']);$profile['equipmentOther']=$profile['equipmentOther']??'';
 return $profile;
}

function profileFactsMeasuredPlanWeight(PDO $db,int $uid,array $reference):array {
 $date=$reference['date']??'';$kg=$reference['kilograms']??null;
 if(!is_string($date)||!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$date)||!is_numeric($kg)||!is_finite((float)$kg))throw new RuntimeException('实测体重引用无效。',422);
 $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);$state=json_decode((string)$q->fetchColumn(),true);
 if(!is_array($state))throw new RuntimeException('请先同步所选的实测体重。',409);
 require_once __DIR__.'/business-state.php';$state=businessStateRead($db,$uid,$state,[$date]);$day=$state['days'][$date]??[];
 $records=is_array($day['bodyMeasurements']??null)?$day['bodyMeasurements']:[];
 if(is_array($day['bodyWeight']??null))$records[]=$day['bodyWeight'];
 foreach($records as $record)if(isset($record['kilograms'])&&($record['source']??'manual')!=='estimated'&&abs((float)$record['kilograms']-(float)$kg)<0.05)return ['date'=>$date,'kilograms'=>(float)$record['kilograms']];
 throw new RuntimeException('所选实测体重已变化或尚未同步，请重新核对。',409);
}
