<?php
declare(strict_types=1);
require_once __DIR__ . '/cloud-parts.php';

function businessUUID(): string {
    $bytes = random_bytes(16);
    $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
    $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
    $hex = bin2hex($bytes);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}

/** Read only the affected schedule windows; never load the account's AI history. */
function businessStateRead(PDO $db, int $uid, array $stored, array $dates): array {
    if (($stored['_partitioned'] ?? null) !== 2) return $stored;
    $state = cloudPartGet($db, $uid, 'meta') ?? $stored;
    unset($state['_partitioned']);
    $state['days'] = [];
    $keys = [];
    foreach ($dates as $date) {
        if (!is_string($date) || !preg_match('/^\d{4}-\d{2}-\d{2}$/D', $date)) continue;
        $anchor = new DateTimeImmutable($date);
        for ($offset = -6; $offset <= 6; $offset++) $keys[$anchor->modify("$offset days")->format('Y-m-d')] = true;
    }
    foreach (array_keys($keys) as $date) {
        $day = cloudPartGet($db, $uid, 'd/' . $date);
        if ($day !== null) $state['days'][$date] = $day;
    }
    return $state;
}

/** Caller holds the user + app_states locks and owns the command transaction. */
function businessStateWrite(PDO $db, int $uid, array $state, array $before, bool $partitioned, int $revision): void {
    if ($partitioned) {
        foreach ($state['days'] ?? [] as $date => $day) {
            if (($before['days'][$date] ?? null) != $day) cloudPartPut($db, $uid, 'd/' . $date, $day);
        }
        unset($state['days'], $state['aiJobs'], $state['_partitioned']);
        cloudPartPut($db, $uid, 'meta', $state);
        $state = cloudPartMetadata($state);
    }
    $raw = json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE revision=VALUES(revision),state_json=VALUES(state_json),updated_at=VALUES(updated_at)')
        ->execute([$uid, $revision, $raw]);
}

/** Date fields in the existing Swift document use seconds since 2001-01-01. */
function businessDocumentNow(): int { return time() - 978307200; }

function businessTrainingSnapshot(array $day): array {
    $out = [];
    foreach (['exercises', 'workoutSessions', 'activeWorkoutSessionID', 'workoutStartedAt', 'workoutEndedAt',
              'workoutSavedAt', 'planCycle', 'plannedMoveDestination', 'movedFromDate'] as $key) {
        $out[$key] = $day[$key] ?? ($key === 'exercises' ? [] : null);
    }
    return $out;
}
function businessDayFingerprint(array $day): string {
    $snapshot = businessTrainingSnapshot($day);
    $snapshot['_schedule_version'] = (int)($day['_schedule_version'] ?? 1);
    return hash('sha256', json_encode(aiProposalKeySort($snapshot), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
}

function businessDayProtected(array $day): bool {
    foreach (['workoutStartedAt', 'workoutSavedAt', 'training_confirmed'] as $key) if (!empty($day[$key])) return true;
    foreach ($day['workoutSessions'] ?? [] as $session) if (!empty($session['startedAt']) || !empty($session['savedAt'])) return true;
    foreach ($day['exercises'] ?? [] as $exercise) foreach ($exercise['sets'] ?? [] as $set) if (!empty($set['completed'])) return true;
    return false;
}

/** Preserve meals/body/history; copy only unstarted training, with fresh stable-in-transaction IDs. */
function businessMoveSchedule(array &$state, array $moves, string $recordID): void {
    $sourceCycles = []; $destinations = []; $deleted = $state['deletedExerciseIDs'] ?? [];
    foreach ($moves as $move) {
        $from = $move['from']; $to = $move['to'];
        $source = $state['days'][$from];
        $cycle = $source['planCycle'] ?? null;
        if (is_array($cycle)) $sourceCycles[$to] = $cycle['start'];
        $targetCycle = $state['days'][$to]['planCycle'] ?? null;
        if (!is_array($targetCycle)) {
            foreach ($state['days'] as $candidate) {
                $known = $candidate['planCycle'] ?? null;
                if (!is_array($known)) continue;
                $end = $known['endDate'] ?? (new DateTimeImmutable($known['start']))->modify('+6 days')->format('Y-m-d');
                if ($known['start'] <= $to && $to <= $end) { $targetCycle = $known; break; }
            }
        }
        if (!is_array($targetCycle)) {
            $anchor = is_array($cycle) ? new DateTimeImmutable($cycle['start']) : new DateTimeImmutable($to);
            $delta = (int)$anchor->diff(new DateTimeImmutable($to))->format('%r%a');
            $start = $anchor->modify((int)(floor($delta / 7) * 7) . ' days')->format('Y-m-d');
            $targetCycle = ['start' => $start, 'plannedDates' => []];
            foreach (['sourceJobID', 'explanationVersion'] as $key) if (isset($cycle[$key])) $targetCycle[$key] = $cycle[$key];
        }
        $destinations[$to] = $targetCycle;
        $copies = [];
        foreach ($source['exercises'] as $exercise) {
            if (isset($exercise['id'])) $deleted[] = $exercise['id'];
            $exercise['id'] = strtoupper(businessUUID());
            unset($exercise['workoutSessionID'], $exercise['deletedSetIDs']);
            foreach ($exercise['sets'] as &$set) { $set['id'] = strtoupper(businessUUID()); $set['completed'] = false; } unset($set);
            $copies[] = $exercise;
        }
        $sessionID = $copies[0]['id'];
        foreach ($copies as &$exercise) $exercise['workoutSessionID'] = $sessionID; unset($exercise);
        $state['days'][$to] = array_merge(['meals' => []], $state['days'][$to] ?? [], [
            'exercises' => $copies, 'workoutSessions' => [['id' => $sessionID]],
            'activeWorkoutSessionID' => $sessionID, 'movedFromDate' => $from, 'planCycle' => $targetCycle,
            '_schedule_version' => (int)($state['days'][$to]['_schedule_version'] ?? 1) + 1,
        ]);
        unset($state['days'][$to]['plannedMoveDestination']);
        $state['days'][$from]['exercises'] = [];
        $state['days'][$from]['meals'] = $state['days'][$from]['meals'] ?? [];
        $state['days'][$from]['plannedMoveDestination'] = $to;
        $state['days'][$from]['_schedule_version'] = (int)($source['_schedule_version'] ?? 1) + 1;
    }
    $scope = array_values(array_unique(array_merge(array_column($moves, 'from'), array_column($moves, 'to'))));
    sort($scope);
    $record = ['id' => $recordID, 'createdAt' => businessDocumentNow(), 'shiftDays' => 1,
               'moves' => (object)array_column($moves, 'to', 'from'), 'replaced' => (object)[],
               'sourceCycles' => (object)$sourceCycles, 'effectScope' => $scope, 'reason' => 'coach_schedule_shift'];
    foreach ($moves as $move) $record['shiftDays'] = max($record['shiftDays'], abs((int)(new DateTimeImmutable($move['from']))->diff(new DateTimeImmutable($move['to']))->format('%r%a')));
    foreach ($scope as $date) $state['days'][$date]['planShifts'][] = $record;
    $state['deletedExerciseIDs'] = array_values(array_unique($deleted));
    // Recompute affected cycle windows, including their other unchanged dates.
    $cycles = $destinations;
    foreach ($scope as $date) if (isset($state['days'][$date]['planCycle'])) $cycles[] = $state['days'][$date]['planCycle'];
    foreach ($cycles as $cycle) {
        $start = new DateTimeImmutable($cycle['start']); $dates = [];
        for ($i = 0; $i < 7; $i++) {
            $date = $start->modify("+$i days")->format('Y-m-d');
            if ($date <= ($cycle['endDate'] ?? '9999-12-31')) $dates[] = $date;
        }
        $cycle['plannedDates'] = array_values(array_filter($dates, fn($d) => !empty($state['days'][$d]['exercises'])));
        foreach ($dates as $date) {
            $existing = $state['days'][$date]['planCycle']['start'] ?? null;
            if ($existing !== null && $existing !== $cycle['start']) continue;
            $state['days'][$date] = array_merge(['exercises' => [], 'meals' => []], $state['days'][$date] ?? [], ['planCycle' => $cycle]);
        }
    }
}
