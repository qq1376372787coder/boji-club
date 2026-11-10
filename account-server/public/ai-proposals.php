<?php
declare(strict_types=1);

/**
 * Phase 3 §4.1 / M-2: AI action proposal state machine.
 *
 * Lifecycle: draft → validated → awaiting_confirmation → executing → succeeded,
 * bypass: rejected / expired / conflict / failed / cancelled.
 *
 * Invariants (主方案 9.3):
 * - The AI (or a relaying client) can only CREATE proposals; every payload is
 *   strictly validated server-side at creation.
 * - Execution happens ONLY through /me/commands with the proposal id; the
 *   handler re-reads the proposal, its expiry, the current document version
 *   and permissions at confirmation time, and applies the STORED payload —
 *   never a client-supplied payload (no bait-and-switch).
 * - Idempotency: (user_id, idempotency_key) unique per proposal; command-level
 *   idempotency stays in data_operations.
 *
 * Function-only module; every helper takes an explicit PDO.
 */

require_once __DIR__ . '/business-state.php';
require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/action-compensation.php';

const AI_PROPOSAL_TTL_HOURS = 24;

function aiProposalKindValid(mixed $kind): bool {
    return in_array($kind, ['meal_draft', 'weight_entry', 'plan_change_proposal', 'exercise_swap', 'plan_activation', 'training_finish'], true);
}

function aiProposalKeySort(array $value): array {
    ksort($value);
    foreach ($value as $key => $item) if (is_array($item)) $value[$key] = aiProposalKeySort($item);
    return $value;
}

function aiProposalIdempotencyKey(int $userId, string $kind, array $payload): string {
    $canonical = json_encode([$kind, aiProposalKeySort($payload)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    return hash_hmac('sha256', 'proposal:' . $userId, (string)$canonical);
}

function aiProposalDateValid(mixed $value): bool {
    if (!is_string($value) || preg_match('/^\d{4}-\d{2}-\d{2}$/D', $value) !== 1) return false;
    $parsed = DateTimeImmutable::createFromFormat('!Y-m-d', $value);
    return $parsed !== false && $parsed->format('Y-m-d') === $value;
}

/**
 * Strict payload shapes per kind. Returns the normalized payload or null.
 * meal_draft  : {date, meals:[{name, category, calories?, protein?, carbs?, fat?}]}
 * weight_entry: {date, kilograms, bodyFatPercentage?, waistCircumferenceCM?}
 * plan_change_proposal: {moves:[{from,to}]} — dates re-checked against the
 *   live document at creation and again at confirmation.
 * exercise_swap: {date, exercises:[planned]} — single-occurrence replacement.
 * plan_activation: {draft_id, sessions:[{date,label,exercises:[planned]}]}.
 */
function aiProposalMealComponents(mixed $components): ?array {
    if (!is_array($components) || count($components) > 30) return null;
    $clean = [];
    foreach ($components as $item) {
        if (!is_array($item)) return null;
        $name = trim((string)($item['name'] ?? ''));
        if ($name === '' || mb_strlen($name) > 100) return null;
        $row = ['name' => $name, 'details' => []];
        foreach (['id' => 'text', 'unit' => 'text', 'basis' => 'text'] as $key => $type) {
            if (isset($item[$key]) && is_string($item[$key]) && mb_strlen($item[$key]) <= 100) $row[$key] = $item[$key];
        }
        foreach (['amount', 'calories', 'protein', 'carbs', 'fat', 'confidenceLow', 'confidenceHigh', 'edibleGrams'] as $key) {
            if (!array_key_exists($key, $item) || $item[$key] === null) continue;
            if (!is_int($item[$key]) && !is_float($item[$key])) return null;
            $value = (float)$item[$key];
            if (!is_finite($value) || $value < 0 || $value > 100000) return null;
            $row[$key] = round($value, 2);
        }
        if (isset($item['details']) && is_array($item['details'])) {
            $row['details'] = array_slice(array_values(array_filter($item['details'], 'is_string')), 0, 8);
        }
        foreach (['sourceKind', 'sourceRef', 'sourceDatabase', 'sourceVersion', 'nutritionEngine'] as $key) {
            if (isset($item[$key]) && is_string($item[$key]) && mb_strlen($item[$key]) <= 120) $row[$key] = $item[$key];
        }
        if (isset($item['uncertaintyFlags']) && is_array($item['uncertaintyFlags'])) {
            $row['uncertaintyFlags'] = array_slice(array_values(array_filter($item['uncertaintyFlags'], 'is_string')), 0, 12);
        }
        if (array_key_exists('requiresReview', $item)) $row['requiresReview'] = (bool)$item['requiresReview'];
        $clean[] = $row;
    }
    return $clean;
}

function aiProposalPayloadValid(string $kind, mixed $payload): ?array {
    if (!is_array($payload)) return null;
    if($kind==='training_finish'){if(!aiProposalDateValid($payload['date']??null)||!trainingSessionIDValid($payload['session_id']??null))return null;return ['date'=>$payload['date'],'session_id'=>strtolower($payload['session_id']),'remaining_sets'=>(int)($payload['remaining_sets']??0)];}
    if ($kind === 'meal_draft') {
        $date = $payload['date'] ?? null;
        $meals = $payload['meals'] ?? null;
        if (!aiProposalDateValid($date) || !is_array($meals) || count($meals) < 1 || count($meals) > 10) return null;
        $clean = [];
        foreach ($meals as $meal) {
            if (!is_array($meal)) return null;
            $name = trim((string)($meal['name'] ?? ''));
            $category = trim((string)($meal['category'] ?? ''));
            if ($name === '' || mb_strlen($name) > 100) return null;
            if (!in_array($category, ['早餐', '午餐', '晚餐', '加餐'], true)) return null;
            $entry = ['name' => $name, 'category' => $category,'estimated'=>(bool)($meal['estimated']??true)];
            if(isset($meal['portion'])){if(!is_string($meal['portion'])||mb_strlen($meal['portion'])>100)return null;$entry['portion']=trim($meal['portion']);}
            if(isset($meal['confidence'])){if(!is_numeric($meal['confidence'])||$meal['confidence']<0||$meal['confidence']>1)return null;$entry['confidence']=(float)$meal['confidence'];}
            foreach (['calories' => [0, 10000], 'protein' => [0, 2000], 'carbs' => [0, 2000], 'fat' => [0, 2000]] as $key => [$lo, $hi]) {
                if (!array_key_exists($key, $meal)) continue;
                $value = $meal[$key];
                if (!is_int($value) && !is_float($value)) return null;
                if (!is_finite((float)$value) || $value < $lo || $value > $hi) return null;
                $entry[$key] = round((float)$value, 1);
            }
            if (array_key_exists('components', $meal)) {
                $components = aiProposalMealComponents($meal['components']);
                if ($components === null) return null;
                $entry['components'] = $components;
            }
            if (array_key_exists('requiresReview', $meal)) $entry['requiresReview'] = (bool)$meal['requiresReview'];
            if (isset($meal['nutritionSources']) && is_array($meal['nutritionSources'])) {
                $entry['nutritionSources'] = array_slice(array_values(array_filter($meal['nutritionSources'], 'is_string')), 0, 8);
            }
            $clean[] = $entry;
        }
        return ['date' => $date, 'meals' => $clean];
    }
    if ($kind === 'weight_entry') {
        $date = $payload['date'] ?? null;
        $kg = $payload['kilograms'] ?? null;
        if (!aiProposalDateValid($date)) return null;
        if (!is_int($kg) && !is_float($kg)) return null;
        if (!is_finite((float)$kg) || $kg < 20 || $kg > 400) return null;
        $clean = ['date' => $date, 'kilograms' => round((float)$kg, 1)];
        foreach (['bodyFatPercentage' => [0, 70], 'waistCircumferenceCM' => [30, 300]] as $key => [$lo, $hi]) {
            if (!array_key_exists($key, $payload)) continue;
            $value = $payload[$key];
            if (!is_int($value) && !is_float($value)) return null;
            if (!is_finite((float)$value) || $value < $lo || $value > $hi) return null;
            $clean[$key] = round((float)$value, 1);
        }
        return $clean;
    }
    if ($kind === 'plan_change_proposal') {
        $moves = $payload['moves'] ?? null;
        if (!is_array($moves) || count($moves) < 1 || count($moves) > 7) return null;
        $seenFrom = [];
        $seenTo = [];
        $clean = [];
        foreach ($moves as $move) {
            if (!is_array($move)) return null;
            $from = $move['from'] ?? null;
            $to = $move['to'] ?? null;
            if (!aiProposalDateValid($from) || !aiProposalDateValid($to)) return null;
            if ($from === $to) return null;
            if (isset($seenFrom[$from]) || isset($seenTo[$to]) || isset($seenTo[$from]) || isset($seenFrom[$to])) return null;
            $seenFrom[$from] = true;
            $seenTo[$to] = true;
            $clean[] = ['from' => $from, 'to' => $to];
        }
        $result = ['moves' => $clean];
        if (isset($payload['compensates']) && is_string($payload['compensates']) && preg_match('/^[0-9a-f-]{36}$/iD', $payload['compensates'])) {
            $result['compensates'] = strtolower($payload['compensates']);
        }
        return $result;
    }
    if ($kind === 'exercise_swap') {
        $date = $payload['date'] ?? null;
        $exercises = $payload['exercises'] ?? null;
        if (!aiProposalDateValid($date) || !is_array($exercises) || count($exercises) > 30) return null;
        $clean = [];
        foreach ($exercises as $exercise) {
            $normalized = aiPlannedExerciseValid($exercise);
            if ($normalized === null) return null;
            $clean[] = $normalized;
        }
        return ['date' => $date, 'exercises' => $clean];
    }
    if ($kind === 'plan_activation') {
        $draftID = $payload['draft_id'] ?? null;
        $sessions = $payload['sessions'] ?? null;
        if (!is_string($draftID) || strlen($draftID) > 64) return null;
        if (!is_array($sessions) || count($sessions) < 1 || count($sessions) > 28) return null;
        $clean = [];
        foreach ($sessions as $session) {
            if (!is_array($session)) return null;
            $date = $session['date'] ?? null;
            $label = mb_substr(trim((string)($session['label'] ?? '')), 0, 40);
            $exercises = $session['exercises'] ?? null;
            if (!aiProposalDateValid($date) || !is_array($exercises) || count($exercises) > 30) return null;
            $planned = [];
            foreach ($exercises as $exercise) {
                $normalized = aiPlannedExerciseValid($exercise);
                if ($normalized === null) return null;
                $planned[] = $normalized;
            }
            $clean[] = ['date' => $date, 'label' => $label, 'exercises' => $planned];
        }
        $result = ['draft_id'=>$draftID,'sessions'=>$clean,'title'=>mb_substr($payload['title']??'新训练计划',0,80),'duration'=>(int)($payload['duration']??7),'effective_start'=>$payload['effective_start']??min(array_column($clean,'date')),'profile'=>$payload['profile']??null,'nutrition'=>$payload['nutrition']??null,'retained_dates'=>$payload['retained_dates']??[],'requested_sessions'=>$payload['requested_sessions']??$clean,'recurring_weekday'=>$payload['recurring_weekday']??null];
        if(isset($payload['compensates'])){
            if(!is_string($payload['compensates'])||!preg_match('/^[0-9a-f-]{36}$/iD',$payload['compensates']))return null;
            if(isset($payload['keep_date'])&&!aiProposalDateValid($payload['keep_date']))return null;
            $result['compensates']=strtolower($payload['compensates']);$result['keep_date']=$payload['keep_date']??null;
        }
        return $result;
    }
    return null;
}

/** Planned (unstarted) exercise shape shared by exercise_swap / plan_activation. */
function aiPlannedExerciseValid(mixed $exercise): ?array {
    if (!is_array($exercise)) return null;
    $name = trim((string)($exercise['name'] ?? ''));
    $muscle = trim((string)($exercise['muscle'] ?? ''));
    $sets = $exercise['sets'] ?? null;
    if ($name === '' || mb_strlen($name) > 200) return null;
    if (mb_strlen($muscle) > 40) return null;
    if (!is_array($sets) || count($sets) < 1 || count($sets) > 50) return null;
    $clean = ['name' => $name, 'muscle' => $muscle, 'sets' => []];
    foreach(['library_id','library_query','custom_id','custom_unit','rest_seconds'] as $k)if(isset($exercise[$k]))$clean[$k]=$exercise[$k];
    foreach ($sets as $set) {
        if (!is_array($set)) return null;
        $reps = $set['reps'] ?? null;
        $weight = $set['weight'] ?? null;
        $seconds = $set['durationSeconds'] ?? $set['duration_seconds'] ?? null;
        if (!is_int($reps) || $reps < 0 || $reps > 1000) return null;
        if ($weight !== null && (!is_int($weight) && !is_float($weight))) return null;
        if ($weight !== null && (!is_finite((float)$weight) || $weight < 0 || $weight > 2000)) return null;
        if ($seconds !== null && (!is_int($seconds) || $seconds < 0 || $seconds > 21600)) return null;
        $entry = ['reps' => $reps];
        if ($weight !== null) $entry['weight'] = round((float)$weight, 2);
        if ($seconds !== null) $entry['durationSeconds'] = $seconds;
        $clean['sets'][] = $entry;
    }
    return $clean;
}

/** Cross-check plan moves against the live document (same guards as Schedule.Move). */
function aiProposalMovesMatchDocument(array $state, array $moves, ?string $today = null): bool {
    $today = $today ?? (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
    foreach ($moves as $move) {
        if ($move['from'] <= $today || $move['to'] <= $today) return false;
        $fromDay = $state['days'][$move['from']] ?? [];
        $toDay = $state['days'][$move['to']] ?? [];
        if (empty($fromDay['exercises'])) return false;
        if (businessDayProtected($fromDay) || businessDayProtected($toDay)) return false;
        if (!empty($toDay['exercises'])) return false;
    }
    return true;
}

/** Dates a baseline-bound proposal touches (used for state window + fingerprints). */
function aiProposalScopeDates(string $kind, array $payload): array {
    if ($kind === 'plan_change_proposal') {
        return array_values(array_unique(array_merge(array_column($payload['moves'], 'from'), array_column($payload['moves'], 'to'))));
    }
    if (in_array($kind,['exercise_swap','training_finish'],true)) return [$payload['date']];
    if ($kind === 'plan_activation') return array_values(array_unique(array_column($payload['sessions'], 'date')));
    return [];
}

/** Create (or return the existing, by idempotency key) an awaiting_confirmation proposal. Never persists unvalidated payloads. */
function aiProposalCreate(PDO $db, int $userId, string $kind, array $payload, array $evidenceRefs,
                          ?string $conversationId, ?string $idempotencyKey, int $ttlHours = AI_PROPOSAL_TTL_HOURS, ?array $baselineDays = null): array {
    if ($db->inTransaction() && function_exists('lockActiveUser')) lockActiveUser($db, $userId);
    actionAssertParentActive($db, $userId);
    $normalized = aiProposalPayloadValid($kind, $payload);
    if ($normalized === null) fail('提案载荷未通过校验。', 400);
    $key = $idempotencyKey !== null && preg_match('/^[0-9a-f]{64}$/D', $idempotencyKey) === 1
        ? $idempotencyKey : hash('sha256', businessUUID());
    $existing = $db->prepare('SELECT proposal_id,status,expires_at,payload_json FROM ai_action_proposals WHERE user_id=? AND idempotency_key=?');
    $existing->execute([$userId, $key]);
    $row = $existing->fetch(PDO::FETCH_ASSOC);
    if ($row) {
        $previous = json_decode($row['payload_json'], true);
        unset($previous['_expected_days'], $previous['_expected_revision'], $previous['_preview_before']);
        if ($previous != $normalized) fail('同一操作标识不能用于不同的提案内容。', 409);
        return ['proposal_id' => $row['proposal_id'], 'status' => $row['status'],
                'expires_at' => $row['expires_at'], 'idempotent' => true];
    }
    if (in_array($kind, ['plan_change_proposal', 'exercise_swap', 'plan_activation', 'training_finish'], true)) {
        $dates = aiProposalScopeDates($kind, $normalized);
        $query = $db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE');
        $query->execute([$userId]);
        $stateRow = $query->fetch(PDO::FETCH_ASSOC);
        $state = businessStateRead($db, $userId, json_decode((string)($stateRow['state_json'] ?? '{}'), true), $dates);
        $normalized['_expected_revision'] = (int)($stateRow['revision'] ?? 0);
        if ($kind === 'plan_change_proposal') {
            if (isset($normalized['compensates'])) {
                $operation = $db->prepare("SELECT diff_json FROM data_operations WHERE user_id=? AND operation_id=? AND command_type='PlanReschedule.Confirm' AND status='succeeded'");
                $operation->execute([$userId, $normalized['compensates']]);
                $original = json_decode((string)$operation->fetchColumn(), true);
                $expected = $original['after_day_fingerprints'] ?? [];
                $reverse = array_map(fn($m) => ['from'=>$m['to'], 'to'=>$m['from']], $original['moves'] ?? []);
                if (!$expected || $reverse !== $normalized['moves']) fail('原变更缺少可安全补偿的实体依据，请在当前日程中重新选择。',409);
                foreach ($dates as $date) {
                    if (!isset($expected[$date]) || !hash_equals($expected[$date], businessDayFingerprint($state['days'][$date] ?? []))) {
                        fail('原变更之后的安排已修改，不能自动补偿，请重新选择当前安排。',409);
                    }
                }
            }
            if (!aiProposalMovesMatchDocument($state, $normalized['moves'], actionToday($db,$userId))) fail('日程不可移动，请重新预览。', 409);
        } elseif($kind!=='training_finish') {
            if($kind==='plan_activation'&&isset($normalized['compensates']))actionValidatePlanCompensation($db,$userId,$state,$normalized);
            // exercise_swap / plan_activation only touch future, unprotected days.
            $today = actionToday($db,$userId);
            foreach ($dates as $date) {
                if ($date < $today) fail('不能修改过去的安排。', 409);
                $day = $state['days'][$date] ?? [];
                if (businessDayProtected($day)) fail("日期 {$date} 的训练已开始或已完成，受保护不可预览。", 409);
            }
        }
        foreach ($dates as $date) {
            $day = $state['days'][$date] ?? [];
            if ($baselineDays !== null && (!array_key_exists($date, $baselineDays) || businessTrainingSnapshot($day) != businessTrainingSnapshot($baselineDays[$date]))) {
                fail('日程与预览内容不同，请重新预览。', 409);
            }
            $normalized['_expected_days'][$date] = businessDayFingerprint($day);
            $normalized['_preview_before'][$date]=businessTrainingSnapshot($day);
        }
    }
    $proposalId = businessUUID();
    $insert = $db->prepare(
        'INSERT INTO ai_action_proposals(proposal_id,user_id,kind,status,payload_json,evidence_refs_json,conversation_id,trace_id,idempotency_key,expires_at,created_at,updated_at)
         VALUES(?,?,?,\'draft\',?,?,?,?,?,DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? HOUR),UTC_TIMESTAMP(),UTC_TIMESTAMP())');
    $insert->execute([
        $proposalId, $userId, $kind,
        json_encode($normalized, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        json_encode(array_values($evidenceRefs), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        $conversationId, $GLOBALS['boji_trace_id'] ?? null, $key, $ttlHours,
    ]);
    // draft → validated → awaiting_confirmation (validation already ran above).
    $db->prepare("UPDATE ai_action_proposals SET status='awaiting_confirmation',updated_at=UTC_TIMESTAMP() WHERE proposal_id=? AND status='draft'")
        ->execute([$proposalId]);
    $row = $db->prepare('SELECT expires_at FROM ai_action_proposals WHERE proposal_id=?');
    $row->execute([$proposalId]);
    return ['proposal_id' => $proposalId, 'status' => 'awaiting_confirmation',
            'expires_at' => (string)$row->fetchColumn(), 'idempotent' => false];
}

/** Lazy sweep: due awaiting_confirmation proposals of one account become expired. */
function aiProposalExpireDue(PDO $db, int $userId): void {
    $db->prepare("UPDATE ai_action_proposals SET status='expired',updated_at=UTC_TIMESTAMP()
                  WHERE user_id=? AND status='awaiting_confirmation' AND expires_at IS NOT NULL AND expires_at<=UTC_TIMESTAMP()")
        ->execute([$userId]);
}

function aiProposalFetch(PDO $db, int $userId, string $proposalId): ?array {
    if (!preg_match('/^[0-9a-f-]{36}$/iD', $proposalId)) return null;
    $query = $db->prepare('SELECT id,proposal_id,idempotency_key,confirmed_command_id,kind,status,payload_json,evidence_refs_json,conversation_id,trace_id,expires_at,created_at,updated_at
                           FROM ai_action_proposals WHERE user_id=? AND proposal_id=?');
    $query->execute([$userId, $proposalId]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    if (!$row) return null;
    $row['payload'] = json_decode((string)$row['payload_json'], true);
    $row['evidence_refs'] = json_decode((string)$row['evidence_refs_json'], true);
    unset($row['payload_json'], $row['evidence_refs_json']);
    return $row;
}

/** List proposals of one account, newest first (own rows only). */
function aiProposalList(PDO $db, int $userId, ?string $status = null, int $limit = 20): array {
    $limit = max(1, min($limit, 50));
    $sql = 'SELECT proposal_id,kind,status,expires_at,created_at,updated_at FROM ai_action_proposals WHERE user_id=?';
    $params = [$userId];
    if ($status !== null && $status !== '') {
        if (!preg_match('/^[a-z_]+$/', $status)) fail('状态过滤不正确。', 400);
        $sql .= ' AND status=?';
        $params[] = $status;
    }
    $sql .= ' ORDER BY updated_at DESC LIMIT ' . $limit;
    $query = $db->prepare($sql);
    $query->execute($params);
    return $query->fetchAll(PDO::FETCH_ASSOC);
}

/** Terminal-state transition used by the command handler (inside its transaction). */
function aiProposalMarkExecution(PDO $db, int $proposalRowId, int $userId, string $commandId,
                                 string $idempotencyKey, string $status, ?array $detail): void {
    $db->prepare("UPDATE ai_action_proposals SET status='executing',updated_at=UTC_TIMESTAMP() WHERE id=?")
        ->execute([$proposalRowId]);
    $db->prepare('INSERT INTO ai_action_executions(proposal_row_id,user_id,command_id,idempotency_key,status,detail_json,created_at,updated_at)
                  VALUES(?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())
                  ON DUPLICATE KEY UPDATE status=VALUES(status),detail_json=VALUES(detail_json),updated_at=UTC_TIMESTAMP()')
        ->execute([$proposalRowId, $userId, $commandId, $idempotencyKey, $status,
                   $detail === null ? null : json_encode($detail, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)]);
    $db->prepare("UPDATE ai_action_proposals SET status='succeeded',confirmed_command_id=IFNULL(confirmed_command_id,?),updated_at=UTC_TIMESTAMP() WHERE id=?")
        ->execute([$commandId, $proposalRowId]);
}
