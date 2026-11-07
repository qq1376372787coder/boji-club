<?php
declare(strict_types=1);

/**
 * Phase 1: Domain Commands for the training lifecycle + proposal-free direct
 * records (unified write entry, P0-1/P0-2).
 *
 * Command types implemented here (dispatched from commands.php):
 *   Training.SessionStart    claim the single active session (DB invariant)
 *   Training.SessionFinish   apply the session snapshot once, release the claim
 *   Training.LogSet          incremental set logging into the active session
 *   BodyWeight.CreateDirect  low-risk direct record (idempotency_key required)
 *   Meal.CreateDirect        direct meal record, convergent by client entry id
 *
 * Invariants enforced here:
 * - One active workout session per user (active_workout_sessions PK user_id),
 *   claimed and released inside the account command transaction. A second
 *   device/start never creates a parallel session: it resumes or conflicts.
 * - A finished (saved) training day is never re-confirmed or overwritten by a
 *   new command; only the original commandId may replay its stored result.
 * - Direct records are idempotent at the operation level (data_operations
 *   idempotency_key) and convergent at the document level (meal entry ids).
 *
 * Function-only module: every helper takes an explicit PDO so tests can drive
 * them without the HTTP router. Document field contracts live in
 * cloud-validation.php (cloudSchemas) and are re-validated after each mutation.
 */

require_once __DIR__ . '/business-state.php';
require_once __DIR__ . '/action-support.php';

function trainingSessionIDValid(mixed $value): bool {
    return is_string($value) && preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/Di', $value) === 1;
}

/** 2001-epoch document timestamps (mirrors cloud-validation 'timestamp'). */
function trainingStampValid(mixed $value): bool {
    return !is_bool($value) && (is_int($value) || is_float($value)) && is_finite((float)$value)
        && $value >= -978307200 && $value <= 10000000000;
}

function trainingStartPayloadValid(mixed $payload): ?array {
    if (!is_array($payload)) return null;
    $date = $payload['date'] ?? null;
    $sessionID = $payload['session_id'] ?? null;
    if (!aiProposalDateValid($date) || !trainingSessionIDValid($sessionID)) return null;
    $clean=['date'=>(string)$date,'session_id'=>strtolower((string)$sessionID)];
    if(isset($payload['exercises'])){
      if(!is_array($payload['exercises'])||count($payload['exercises'])>30)return null;
      $clean['exercises']=[];foreach($payload['exercises'] as $e){$v=trainingExerciseSnapshotValid($e);if(!$v)return null;$clean['exercises'][]=$v;}
    }
    return $clean;
}

function trainingFinishPayloadValid(mixed $payload): ?array {
    if (!is_array($payload)) return null;
    $date = $payload['date'] ?? null;
    $sessionID = $payload['session_id'] ?? null;
    if (!aiProposalDateValid($date) || !trainingSessionIDValid($sessionID)) return null;
    $clean = ['date' => (string)$date, 'session_id' => strtolower((string)$sessionID)];
    foreach (['started_at', 'ended_at', 'saved_at'] as $key) {
        if (array_key_exists($key, $payload) && $payload[$key] !== null) {
            if (!trainingStampValid($payload[$key])) return null;
            $clean[$key] = (int)$payload[$key];
        }
    }
    if (isset($payload['exercises'])) {
        if (!is_array($payload['exercises']) || !$payload['exercises'] || count($payload['exercises']) > 30) return null;
        $exercises = [];
        foreach ($payload['exercises'] as $exercise) {
            $normalized = trainingExerciseSnapshotValid($exercise);
            if ($normalized === null) return null;
            $exercises[] = $normalized;
        }
        $clean['exercises'] = $exercises;
    }
    return $clean;
}

/** One exercise's set snapshot; ids come from the client and stay stable. */
function trainingExerciseSnapshotValid(mixed $exercise): ?array {
    if (!is_array($exercise)) return null;
    $id = $exercise['id'] ?? null;
    $name = $exercise['name'] ?? null;
    $muscle = $exercise['muscle'] ?? null;
    $sets = $exercise['sets'] ?? null;
    if (!trainingSessionIDValid($id)) return null;
    if (!is_string($name) || trim($name) === '' || mb_strlen($name) > 200) return null;
    if (!is_string($muscle) || mb_strlen($muscle) > 40) return null;
    if (!is_array($sets) || !$sets || count($sets) > 50) return null;
    $clean = ['id' => strtolower((string)$id), 'name' => trim((string)$name), 'muscle' => (string)$muscle, 'sets' => []];
    foreach(['libraryID','libraryQuery','customExerciseID','customUnit','planID','restSeconds'] as $key)if(isset($exercise[$key]))$clean[$key]=$exercise[$key];
    foreach ($sets as $set) {
        $normalized = trainingSetPayloadValid($set);
        if ($normalized === null) return null;
        $clean['sets'][] = $normalized;
    }
    return $clean;
}

function trainingSetPayloadValid(mixed $set): ?array {
    if (!is_array($set)) return null;
    $id = $set['id'] ?? null;
    if (!trainingSessionIDValid($id)) return null;
    $weight = $set['weight'] ?? null;
    $reps = $set['reps'] ?? null;
    $completed = $set['completed'] ?? false;
    if (!is_int($weight) && !is_float($weight)) $weight = 0;
    if (!is_int($reps)) $reps = 0;
    if (!is_bool($completed)) return null;
    $weight = (float)$weight; $reps = (int)$reps;
    if (!is_finite($weight) || $weight < 0 || $weight > 2000) return null;
    if ($reps < 0 || $reps > 1000) return null;
    $clean = ['id' => strtolower((string)$id), 'weight' => round($weight, 2), 'reps' => $reps, 'completed' => $completed];
    // Document field names follow cloudSchemas ('durationSeconds'); the wire
    // payload may also carry the snake_case alias from the client.
    $seconds = $set['durationSeconds'] ?? $set['duration_seconds'] ?? null;
    if ($seconds !== null) {
        if (!is_int($seconds) || $seconds < 0 || $seconds > 21600) return null;
        $clean['durationSeconds'] = $seconds;
    }
    $effective = $clean['durationSeconds'] ?? 0;
    if ($completed && $reps <= 0 && $effective <= 0) return null; // a completed set needs reps or duration
    return $clean;
}

function trainingLogSetPayloadValid(mixed $payload): ?array {
    if (!is_array($payload)) return null;
    if (!aiProposalDateValid($payload['date'] ?? null)) return null;
    foreach (['session_id', 'exercise_id', 'set_id'] as $key) {
        if (!trainingSessionIDValid($payload[$key] ?? null)) return null;
    }
    $set = $payload;
    $set['id'] = $payload['set_id'];
    $normalized = trainingSetPayloadValid($set);
    if ($normalized === null) return null;
    return [
        'date' => (string)$payload['date'],
        'session_id' => strtolower((string)$payload['session_id']),
        'exercise_id' => strtolower((string)$payload['exercise_id']),
        'set' => $normalized,
    ];
}

/**
 * Direct body-weight record: same bounds as the weight_entry proposal, plus an
 * optional sampling time. All-nil payloads are rejected (deletion stays on the
 * legacy path until a tombstone command exists).
 */
function trainingDirectWeightPayloadValid(mixed $payload): ?array {
    if (!is_array($payload)) return null;
    $base = $payload;
    unset($base['idempotency_key'], $base['recorded_at'], $base['measurement_id']);
    $normalized = aiProposalPayloadValid('weight_entry', $base);
    if ($normalized === null) return null;
    if (array_key_exists('recorded_at', $payload) && $payload['recorded_at'] !== null) {
        if (!trainingStampValid($payload['recorded_at'])) return null;
        $normalized['recorded_at'] = (float)$payload['recorded_at'];
    }
    if(isset($payload['measurement_id'])) {if(!trainingSessionIDValid($payload['measurement_id'])) return null; $normalized['measurement_id']=strtolower($payload['measurement_id']);}
    return $normalized;
}

/**
 * Direct meal record: client-supplied stable entry ids make re-application
 * convergent (the same operation never produces a second meal), while two real
 * meals always carry different entry ids.
 */
function trainingDirectMealPayloadValid(mixed $payload): ?array {
    if (!is_array($payload)) return null;
    $date = $payload['date'] ?? null;
    $meals = $payload['meals'] ?? null;
    if (!aiProposalDateValid($date) || !is_array($meals) || count($meals) < 1 || count($meals) > 10) return null;
    $clean = [];
    foreach ($meals as $meal) {
        if (!is_array($meal)) return null;
        $entryID = $meal['entry_id'] ?? null;
        $name = trim((string)($meal['name'] ?? ''));
        $category = $meal['category'] ?? null;
        if (!trainingSessionIDValid($entryID)) return null;
        if ($name === '' || mb_strlen($name) > 100) return null;
        if (!in_array($category, ['早餐', '午餐', '晚餐', '加餐'], true)) return null;
        $entry = ['entry_id' => strtolower((string)$entryID), 'name' => $name, 'category' => (string)$category];
        foreach (['calories' => [0, 100000], 'protein' => [0, 100000], 'carbs' => [0, 100000], 'fat' => [0, 100000]] as $key => [$lo, $hi]) {
            if (!array_key_exists($key, $meal)) continue;
            $value = $meal[$key];
            if (!is_int($value) && !is_float($value)) return null;
            if (!is_finite((float)$value) || $value < $lo || $value > $hi) return null;
            $entry[$key] = round((float)$value, 1);
        }
        if (array_key_exists('nutrition_known', $meal)) {
            if (!is_bool($meal['nutrition_known'])) return null;
            $entry['nutritionKnown'] = (bool)$meal['nutrition_known'];
        }
        if (array_key_exists('nutritionKnown', $meal)) {
            if (!is_bool($meal['nutritionKnown'])) return null;
            $entry['nutritionKnown'] = (bool)$meal['nutritionKnown'];
        }
        foreach(['sourceAIJobID','estimated','portion','confidence'] as $k)if(isset($meal[$k]))$entry[$k]=$meal[$k];
        if(isset($meal['components'])&&is_array($meal['components']))$entry['components']=array_slice($meal['components'],0,30);
        if(isset($meal['requiresReview']))$entry['requiresReview']=(bool)$meal['requiresReview'];
        if(isset($meal['nutritionSources'])&&is_array($meal['nutritionSources']))$entry['nutritionSources']=array_slice(array_values(array_filter($meal['nutritionSources'],'is_string')),0,8);
        $clean[] = $entry;
    }
    return ['date' => (string)$date, 'meals' => $clean];
}

// ---------------------------------------------------------------- active claim

function trainingActiveFetch(PDO $db, int $userId): ?array {
    $q = $db->prepare('SELECT session_id,date_key,started_at FROM active_workout_sessions WHERE user_id=?');
    $q->execute([$userId]);
    $row = $q->fetch(PDO::FETCH_ASSOC);
    if (!$row) return null;
    $row['session_id'] = strtolower((string)$row['session_id']);
    return $row;
}

/**
 * Claim the single active slot. Returns the pre-existing row when present
 * (caller decides resume vs conflict); the caller holds the account lock, so a
 * plain INSERT is race-free and the PK is the final defence.
 */
function trainingActiveClaim(PDO $db, int $userId, string $sessionID, string $dateKey): ?array {
    $existing = trainingActiveFetch($db, $userId);
    if ($existing !== null) return $existing;
    try {
        $db->prepare('INSERT INTO active_workout_sessions(user_id,session_id,date_key,started_at,updated_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
            ->execute([$userId, $sessionID, $dateKey]);
    } catch (PDOException $error) {
        if ((int)($error->errorInfo[1] ?? 0) === 1062) {
            $again = trainingActiveFetch($db, $userId);
            if ($again !== null) return $again;
        }
        throw $error;
    }
    return null;
}

function trainingActiveRelease(PDO $db, int $userId, string $sessionID): void {
    $db->prepare('DELETE FROM active_workout_sessions WHERE user_id=? AND session_id=?')->execute([$userId, $sessionID]);
}

// ------------------------------------------------------------- document writes

/** Start: create/select the day session and mark it started. */
function trainingApplyStart(array &$state, array $payload, string $sessionID): array {
    $date = $payload['date'];
    $now = businessDocumentNow();
    if (!isset($state['days'][$date]) || !is_array($state['days'][$date])) {
        $state['days'][$date] = ['exercises' => [], 'meals' => []];
    }
    $day = &$state['days'][$date];
    if (!isset($day['exercises']) || !is_array($day['exercises'])) $day['exercises'] = [];
    $targets = $payload['exercises'] ?? [];
    $targetIDs = array_map(fn($e)=>strtolower($e['id']), $targets);
    // Bind the existing plan, preserving stable IDs and all target values. A
    // different session's history must never be relabelled as this session.
    foreach ($day['exercises'] as &$existing) {
        $explicit = in_array(strtolower($existing['id']), $targetIDs, true);
        $owner = strtolower((string)($existing['workoutSessionID'] ?? ''));
        $hasActual = (bool)array_filter($existing['sets'] ?? [], fn($s)=>!empty($s['completed']) || ($s['actualEntered'] ?? false) === true);
        if ($explicit && $owner !== '' && $owner !== strtolower($sessionID)) {
            businessReject(409, ['error'=>'动作属于另一场训练，不能重新关联。']);
        }
        if ($owner === '' && ($explicit || !$targets)) {
            if ($hasActual) {
                if ($explicit) businessReject(409, ['error'=>'动作已有未关联的实际记录，请先核对训练场次。']);
                continue;
            }
            $existing['workoutSessionID'] = strtoupper($sessionID);
        }
    }
    unset($existing);
    foreach ($targets as $target) {
        $known = array_filter($day['exercises'], fn($e)=>strtolower($e['id'])===strtolower($target['id']));
        if (!$known) {
            $target['id']=strtoupper($target['id']); $target['workoutSessionID']=strtoupper($sessionID);
            foreach($target['sets'] as &$set) $set['id']=strtoupper($set['id']);
            unset($set); $day['exercises'][]=$target;
        }
    }

    if (!isset($day['meals']) || !is_array($day['meals'])) $day['meals'] = [];
    $sessions = is_array($day['workoutSessions'] ?? null) ? $day['workoutSessions'] : [];
    $found = false;
    foreach ($sessions as $session) {
        if (is_array($session) && strtolower((string)($session['id'] ?? '')) === $sessionID) { $found = true; break; }
    }
    if (!$found) $sessions[] = ['id' => strtoupper($sessionID), 'startedAt' => $now];
    $day['workoutSessions'] = array_values($sessions);
    $day['activeWorkoutSessionID'] = strtoupper($sessionID);
    $day['workoutStartedAt'] = $now;
    unset($day['workoutSavedAt']);
    unset($day['workoutEndedAt']);
    $day['_schedule_version'] = (int)($day['_schedule_version'] ?? 1) + 1;
    return ['session_id' => $sessionID, 'date' => $date, 'started_at' => $now];
}

/**
 * Finish: apply the client's set snapshot for matched exercises (append unseen
 * ones with their stable ids), stamp the session, and mark the day saved. The
 * caller must have rejected already-saved days before calling.
 */
function trainingApplyFinish(array &$state, array $payload): array {
    $date = $payload['date'];
    $sessionID = $payload['session_id'];
    $now = businessDocumentNow();
    if (!isset($state['days'][$date]) || !is_array($state['days'][$date])) {
        $state['days'][$date] = ['exercises' => [], 'meals' => []];
    }
    $day = &$state['days'][$date];
    if (!isset($day['exercises']) || !is_array($day['exercises'])) $day['exercises'] = [];
    if (!isset($day['meals']) || !is_array($day['meals'])) $day['meals'] = [];

    $startedAt = $payload['started_at'] ?? ($day['workoutStartedAt'] ?? $now);
    $endedAt = $payload['ended_at'] ?? $now;
    $savedAt = $payload['saved_at'] ?? $now;

    $updated = 0; $appended = 0; $completedSets = 0;
    foreach ($payload['exercises'] ?? [] as $exercise) {
        $match = null;
        foreach ($day['exercises'] as $index => $candidate) {
            if (strtolower((string)($candidate['id'] ?? '')) === $exercise['id']) { $match = $index; break; }
        }
        if ($match === null) {
            $day['exercises'][] = [
                'id' => strtoupper($exercise['id']), 'name' => $exercise['name'], 'muscle' => $exercise['muscle'],
                'sets' => array_map(fn($set) => array_merge($set, ['id' => strtoupper($set['id'])]), $exercise['sets']),
                'workoutSessionID' => strtoupper($sessionID),
            ];
            $appended++;
        } else {
            if(!empty($day['exercises'][$match]['workoutSessionID'])&&strtolower($day['exercises'][$match]['workoutSessionID'])!==$sessionID)fail('动作属于另一场训练，不能覆盖。',409);
            foreach($day['exercises'][$match]['sets'] as $known)if(!empty($known['completed']))foreach($exercise['sets'] as $incoming)if(strtolower($known['id'])===$incoming['id']){
                foreach(['completed','weight','reps','durationSeconds'] as $field)if(($known[$field]??null)!=($incoming[$field]??null))fail('已记录训练组与本机快照不同，请先核对冲突，再结束训练。',409);
            }
            $extra=array_filter($day['exercises'][$match]['sets'],fn($s)=>!in_array(strtolower($s['id']),array_column($exercise['sets'],'id'),true));
            $day['exercises'][$match]['sets'] = array_map(fn($set) => array_merge($set, ['id' => strtoupper($set['id'])]), $exercise['sets']);
            $day['exercises'][$match]['sets']=array_merge($day['exercises'][$match]['sets'],array_values($extra));
            $day['exercises'][$match]['workoutSessionID'] = strtoupper($sessionID);
            $updated++;
        }
        foreach ($exercise['sets'] as $set) if ($set['completed']) $completedSets++;
    }
    $day['exercises'] = array_values($day['exercises']);
    $completedSets=0;foreach($day['exercises'] as $e)if(empty($e['workoutSessionID'])||strtolower($e['workoutSessionID'])===$sessionID)foreach($e['sets'] as $set)if(!empty($set['completed']))$completedSets++;
    if($completedSets===0)fail('没有已记录的完成组，请继续训练或明确放弃草稿。',422);

    $sessions = is_array($day['workoutSessions'] ?? null) ? $day['workoutSessions'] : [];
    $found = false;
    foreach ($sessions as $index => $session) {
        if (!is_array($session) || strtolower((string)($session['id'] ?? '')) !== $sessionID) continue;
        $sessions[$index]['startedAt'] = $startedAt;
        $sessions[$index]['endedAt'] = $endedAt;
        $sessions[$index]['savedAt'] = $savedAt;
        $found = true;
        break;
    }
    if (!$found) $sessions[] = ['id' => strtoupper($sessionID), 'startedAt' => $startedAt, 'endedAt' => $endedAt, 'savedAt' => $savedAt];
    $day['workoutSessions'] = array_values($sessions);
    $day['activeWorkoutSessionID'] = strtoupper($sessionID);
    $day['workoutStartedAt'] = $startedAt;
    $day['workoutEndedAt'] = $endedAt;
    $day['workoutSavedAt'] = $savedAt;
    $day['_schedule_version'] = (int)($day['_schedule_version'] ?? 1) + 1;

    return [
        'session_id' => $sessionID, 'date' => $date,
        'exercises_updated' => $updated, 'exercises_appended' => $appended,
        'completed_sets' => $completedSets, 'saved_at' => $savedAt,
    ];
}

/** Log one set into the active session; unseen sets are appended. */
function trainingApplyLogSet(array &$state, array $payload): ?array {
    $date = $payload['date'];
    $day = $state['days'][$date] ?? null;
    if (!is_array($day) || !is_array($day['exercises'] ?? null)) return null;
    $exerciseIndex = null;
    foreach ($day['exercises'] as $index => $exercise) {
        if (strtolower((string)($exercise['id'] ?? '')) === $payload['exercise_id']) { $exerciseIndex = $index; break; }
    }
    if ($exerciseIndex === null) return null;
    $set = $payload['set'];
    $sets = is_array($day['exercises'][$exerciseIndex]['sets'] ?? null) ? $day['exercises'][$exerciseIndex]['sets'] : [];
    $match = null;
    foreach ($sets as $index => $candidate) {
        if (strtolower((string)($candidate['id'] ?? '')) === $set['id']) { $match = $index; break; }
    }
    $record = array_merge($set, ['id' => strtoupper($set['id'])]);
    if ($match === null) {
        if (count($sets) >= 50) return null;
        $sets[] = $record;
    } else {
        $sets[$match] = $record;
    }
    $state['days'][$date]['exercises'][$exerciseIndex]['sets'] = array_values($sets);
    $state['days'][$date]['exercises'][$exerciseIndex]['workoutSessionID'] = strtoupper($payload['session_id']);
    $state['days'][$date]['_schedule_version'] = (int)($state['days'][$date]['_schedule_version'] ?? 1) + 1;
    return ['exercise_id' => $payload['exercise_id'], 'set_id' => $set['id'], 'completed' => $set['completed']];
}

/** Direct body-weight record (replace semantics; convergent under re-apply). */
function trainingApplyDirectWeight(array &$state, array $payload): array {
    $date = $payload['date'];
    $now = microtime(true) - 978307200;
    if (!isset($state['days'][$date]) || !is_array($state['days'][$date])) {
        $state['days'][$date] = ['exercises' => [], 'meals' => []];
    }
    $day = &$state['days'][$date];
    if (!isset($day['exercises']) || !is_array($day['exercises'])) $day['exercises'] = [];
    if (!isset($day['meals']) || !is_array($day['meals'])) $day['meals'] = [];
    $entry = ['kilograms' => round((float)$payload['kilograms'], 1), 'updatedAt' => $now];
    foreach (['bodyFatPercentage', 'waistCircumferenceCM'] as $key) {
        if (isset($payload[$key])) $entry[$key] = round((float)$payload[$key], 1);
    }
    $entry['recordedAt'] = $payload['recorded_at'] ?? $now;
    $entry['source'] = 'manual';
    actionMeasurementMigrate($day,$date);
    $entry['id']=$payload['measurement_id']??actionUUID('measurement/'.$date.'/'.json_encode($payload));
    $day['bodyMeasurements']=array_values(array_filter($day['bodyMeasurements'],fn($v)=>strtolower($v['id'])!==strtolower($entry['id'])));
    $day['bodyMeasurements'][]=$entry;
    actionMeasurementProject($day);
    $day['_body_version'] = (int)($day['_body_version'] ?? 1) + 1;
    return ['date' => $date, 'kilograms' => $entry['kilograms']];
}

/** Direct meal record: same entry id replaces, a new id appends. */
function trainingApplyDirectMeal(array &$state, array $payload, string $operationID): array {
    $date = $payload['date'];
    if (!isset($state['days'][$date]) || !is_array($state['days'][$date])) {
        $state['days'][$date] = ['exercises' => [], 'meals' => []];
    }
    $day = &$state['days'][$date];
    if (!isset($day['exercises']) || !is_array($day['exercises'])) $day['exercises'] = [];
    if (!isset($day['meals']) || !is_array($day['meals'])) $day['meals'] = [];
    $added = 0; $replaced = 0; $appendedIDs = [];
    foreach ($payload['meals'] as $meal) {
        $record = [
            'id' => strtoupper($meal['entry_id']), 'name' => $meal['name'], 'category' => $meal['category'],
            'calories' => (float)($meal['calories'] ?? 0), 'protein' => (float)($meal['protein'] ?? 0),
            'carbs' => (float)($meal['carbs'] ?? 0), 'fat' => (float)($meal['fat'] ?? 0),
            'sourceAIJobID' => $meal['sourceAIJobID']??$operationID, 'estimated' => $meal['estimated']??false,
            'portion'=>$meal['portion']??null,'recognitionConfidence'=>$meal['confidence']??null,
            'nutritionKnown' => array_key_exists('nutritionKnown', $meal) ? (bool)$meal['nutritionKnown'] : (array_key_exists('nutrition_known', $meal) ? (bool)$meal['nutrition_known'] : false),
            'components' => is_array($meal['components'] ?? null) ? $meal['components'] : null,
            'requiresReview' => !empty($meal['requiresReview']),
            'nutritionSources' => is_array($meal['nutritionSources'] ?? null) ? $meal['nutritionSources'] : null,
        ];
        $match = null;
        foreach ($day['meals'] as $index => $candidate) {
            if (strtolower((string)($candidate['id'] ?? '')) === $meal['entry_id']) { $match = $index; break; }
        }
        if ($match === null) { $day['meals'][] = $record; $added++; $appendedIDs[] = strtolower($meal['entry_id']); }
        else { $day['meals'][$match] = array_merge($day['meals'][$match], $record); $replaced++; }
    }
    $day['meals'] = array_values($day['meals']);
    $day['_meal_version'] = (int)($day['_meal_version'] ?? 1) + 1;
    return ['date' => $date, 'added' => $added, 'replaced' => $replaced, 'appended_ids' => $appendedIDs];
}

// ------------------------------------------------------------------- audit row

/** Audit-only operation (resume/adopt): records the outcome without mutation. */
function trainingRecordAudit(PDO $db, int $userId, string $operationID, string $actor, string $type,
                             string $payloadHash, string $aggregateType, string $aggregateID,
                             string $beforeVersion, string $afterVersion, array $diff, ?string $idempotencyKey, ?string $undoJson = null): void {
    $db->prepare('INSERT INTO data_operations(operation_id,user_id,actor,command_type,payload_hash,idempotency_key,aggregate_type,aggregate_id,before_version,after_version,diff_json,undo_json,status,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,"succeeded",UTC_TIMESTAMP())')
        ->execute([$operationID, $userId, $actor, $type, $payloadHash, $idempotencyKey,
                   $aggregateType, $aggregateID, $beforeVersion, $afterVersion,
                   json_encode($diff, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $undoJson]);
}

// --------------------------------------------- full-state sync guard (PUT path)

/**
 * Keep the single-active-session invariant true for legacy full-state syncs:
 * backfill the claim for a document-started session, release it when the
 * document no longer has one, and refuse (caller answers 409) any upload that
 * would silently create or replace a different active session. Called inside
 * the PUT transaction while the account row is locked. Returns an error
 * message when the upload must be refused, otherwise null.
 */
function trainingGuardFullStateSync(PDO $db, int $uid, array $incoming): ?string {
    $active = [];
    foreach (($incoming['days'] ?? []) as $date => $day) {
        if (!is_array($day) || empty($day['workoutStartedAt']) || !empty($day['workoutSavedAt'])) continue;
        $sessionID = $day['activeWorkoutSessionID'] ?? null;
        if (!is_string($sessionID) || $sessionID === '') continue;
        $active[(string)$date] = ['session_id' => strtolower($sessionID), 'started_at' => (float)($day['workoutStartedAt'] ?? 0)];
    }
    $existing = trainingActiveFetch($db, $uid);
    if ($existing === null) {
        if (count($active) === 1) {
            $date = array_key_first($active);
            $db->prepare('INSERT INTO active_workout_sessions(user_id,session_id,date_key,started_at,updated_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
                ->execute([$uid, $active[$date]['session_id'], $date]);
        }
        return count($active)>1 ? '同时存在多场进行中训练，请选择保留的会话后重新同步。' : null;
    }
    $matchesTable = isset($active[$existing['date_key']]) && $active[$existing['date_key']]['session_id'] === $existing['session_id'];
    if (count($active) === 1 && $matchesTable) return null;
    if (empty($active)) {
        trainingActiveRelease($db, $uid, $existing['session_id']);
        return null;
    }
    return '其他设备有进行中的训练（' . $existing['date_key'] . '），请先结束或等待同步后再试。';
}

/** Recovery only when the active claim survives an earlier document upload. */
function trainingFinishFactsMatch130(array $day,array $payload): bool {
    $known=[];$incoming=[];
    foreach($day['exercises']??[] as $e)if(strtolower((string)($e['workoutSessionID']??''))===$payload['session_id']) {
        $sets=[];foreach($e['sets']??[] as $v)$sets[strtolower($v['id'])]=[$v['weight'],$v['reps'],(bool)$v['completed'],$v['durationSeconds']??null];ksort($sets);$known[strtolower($e['id'])]=$sets;
    }
    foreach($payload['exercises']??[] as $e){$sets=[];foreach($e['sets']??[] as $v)$sets[strtolower($v['id'])]=[$v['weight'],$v['reps'],(bool)$v['completed'],$v['durationSeconds']??null];ksort($sets);$incoming[strtolower($e['id'])]=$sets;}
    ksort($known);ksort($incoming);return $known!==[] && $known==$incoming;
}
