<?php
declare(strict_types=1);
require_once __DIR__ . '/engine-proxy.php';

/**
 * Phase 4 §5.1 / D-10: long-term memory engine (v1).
 *
 * Extraction is DETERMINISTIC and data-minimising: only confirmed facts and
 * behaviour counts from the synced document become memory statements — never
 * raw health measurements (weights/body-fat values stay in the document; the
 * memory layer stores derived, human-readable statements only). User actions
 * (correct/suspend/withdraw) always outrank re-extraction: items carry a
 * stable idempotency key so a sweep updates content but never resurrects a
 * decision the member made about it.
 *
 * Six kinds (D-10, 可推翻): fact / habit / preference / goal / constraint /
 * correction. Page columns map to: 确认事实 = fact+goal+constraint;
 * 观察习惯 = habit+preference; 待确认推断 = low-confidence items.
 *
 * Function-only module; helpers take an explicit PDO.
 */

const AI_MEMORY_MIN_SESSIONS_FOR_TIMING = 5;

/** Portable UUIDv4: the CLI SAPI may lack the uuid extension (FPM has it). */
function aiMemoryUUID(): string {
    if (function_exists('uuid_create')) return (string)uuid_create();
    $bytes = random_bytes(16);
    $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
    $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
    $hex = bin2hex($bytes);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}
const AI_MEMORY_FREQUENT_TRAINING_WEEKS = 4;
const AI_MEMORY_CONTEXT_ITEMS = 6;

function aiMemoryKey(int $userId, string $kind, string $slug): string {
    return hash_hmac('sha256', 'memory:' . $kind, $userId . ':' . $slug);
}

function aiMemoryUpsert(PDO $db, int $userId, string $kind, string $content, int $confidence,
                        array $evidenceRefs, string $slug, int $revision): string {
    $key = aiMemoryKey($userId, $kind, $slug);
    $existing = $db->prepare('SELECT memory_id,status,origin,content,confidence FROM user_memory_items WHERE user_id=? AND idempotency_key=?');
    $existing->execute([$userId, $key]);
    $row = $existing->fetch(PDO::FETCH_ASSOC);
    if ($row) {
        // Member decisions are terminal: suspended/withdrawn/corrected rows are
        // left exactly as the member left them.
        if (in_array($row['status'], ['suspended', 'withdrawn', 'corrected'], true)) {
            return $row['memory_id'];
        }
        // User-authored content outranks extracted statements.
        if ($row['origin'] === 'user' && trim((string)$row['content']) !== trim($content)) return (string)$row['memory_id'];
        // Apply the deterministic trust policy when the engine is available.
        $policy = engineRequest($GLOBALS['config'] ?? [], '/v1/personal/memories/resolve', [
            'existing' => [
                'key' => $key, 'kind' => $kind === 'goal' || $kind === 'fact' || $kind === 'constraint' ? 'profile_fact' : ($kind === 'preference' ? 'preference' : 'behavior_feature'),
                'value' => (string)$row['content'], 'status' => ($row['origin'] ?? 'extracted') === 'user' ? 'confirmed' : 'tentative',
                'confidence' => max(0, min(1, ((int)$row['confidence']) / 100)), 'source' => 'user',
                'evidence_refs' => [],
            ],
            'incoming' => [
                'key' => $key, 'kind' => $kind === 'goal' || $kind === 'fact' || $kind === 'constraint' ? 'profile_fact' : ($kind === 'preference' ? 'preference' : 'behavior_feature'),
                'value' => $content, 'status' => 'tentative',
                'confidence' => max(0, min(1, $confidence / 100)), 'source' => 'ai',
                'evidence_refs' => $evidenceRefs,
            ],
        ], 1.0);
        if (is_array($policy['result'] ?? null) && ($policy['result']['action'] ?? '') === 'reject') {
            return (string)$row['memory_id'];
        }
        $db->prepare('UPDATE user_memory_items SET content=?,confidence=?,evidence_json=?,source_revision=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND idempotency_key=?')
            ->execute([$content, $confidence,
                       json_encode($evidenceRefs, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                       $revision, $userId, $key]);
        return (string)$row['memory_id'];
    }
    $memoryId = aiMemoryUUID();
    $db->prepare('INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,source_revision,created_at,updated_at)
                  VALUES(?,?,?,\'active\',\'extracted\',?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute([$memoryId, $userId, $kind, $content, max(0, min(100, $confidence)),
                   json_encode($evidenceRefs, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                   $key, $revision]);
    return $memoryId;
}

/**
 * Deterministic extraction from the synced document. Thresholds reuse the
 * automation "minimum sample" idea: statements about behaviour require enough
 * confirmed observations, else they are not stated at all.
 */
function aiMemoryExtract(PDO $db, int $userId, array $state, string $today, int $revision): void {
    $validKeys = [];
    $remember = function (string $kind, string $content, int $confidence, array $refs, string $slug, int $sourceRevision) use ($db, $userId, &$validKeys): string {
        $validKeys[] = aiMemoryKey($userId, $kind, $slug);
        return aiMemoryUpsert($db, $userId, $kind, $content, $confidence, $refs, $slug, $sourceRevision);
    };
    $profile = is_array($state['profile'] ?? null) ? $state['profile'] : [];
    // One fact source: V2 facts when present. The client state profile is a
    // compatibility projection and may still contain legacy defaults.
    if (function_exists('profileFactsRead')) {
        $document = profileFactsRead($db, $userId);
        $facts = is_array($document['facts'] ?? null) ? $document['facts'] : [];
        if ($facts || (int)($document['revision'] ?? 0) > 0) {
            $profile = [
                'goal' => $facts['goal']['value'] ?? null,
                'limitations' => $facts['limitations']['value'] ?? null,
                'daysPerWeek' => $facts['days_per_week']['value'] ?? null,
            ];
        }
    }

    // Facts from the member's own profile (confidence 100, declared not inferred).
    $goal = trim((string)($profile['goal'] ?? ''));
    if ($goal !== '') {
        $remember('goal', '当前目标：' . mb_substr($goal, 0, 30), 100,
            ['profile/goal'], 'goal', $revision);
    }
    $limitation = trim((string)($profile['limitations'] ?? ''));
    if ($limitation !== '') {
        $remember('constraint', '训练限制：' . mb_substr($limitation, 0, 80), 100,
            ['profile/limitations'], 'limitation', $revision);
    }
    $daysPerWeek = (int)($profile['daysPerWeek'] ?? 0);
    if ($daysPerWeek >= 1 && $daysPerWeek <= 7) {
        $remember('fact', '计划每周训练 ' . $daysPerWeek . ' 天', 100,
            ['profile/daysPerWeek'], 'days-per-week', $revision);
    }

    // Confirmed sessions over the last 4 weeks (same confirmation semantics as
    // club progress: a valid completed set + a saved/confirmed session).
    $windowStart = (new DateTimeImmutable($today))->modify('-27 days')->format('Y-m-d');
    $sessions = [];
    $mealDays = 0;
    foreach (($state['days'] ?? []) as $date => $day) {
        if (!is_string($date) || $date > $today || $date < $windowStart || !is_array($day)) continue;
        $trained = false;
        foreach (($day['exercises'] ?? []) as $exercise) {
            foreach (($exercise['sets'] ?? []) as $set) {
                if (!empty($set['completed']) && (isset($set['durationSeconds']) ? (int)$set['durationSeconds'] > 0 : (int)($set['reps'] ?? 0) > 0)) {
                    $trained = true; break 2;
                }
            }
        }
        $confirmedAt = $day['workoutSavedAt'] ?? null;
        $confirmed = $trained && !empty($day['workoutSavedAt']);
        if (!empty($day['workoutSessions'])) {
            $confirmed = false;
            foreach (($day['workoutSessions'] ?? []) as $session) {
                if (empty($session['savedAt'])) continue;
                foreach (($day['exercises'] ?? []) as $exercise) {
                    if (strtolower((string)($exercise['workoutSessionID'] ?? '')) !== strtolower((string)$session['id'])) continue;
                    foreach (($exercise['sets'] ?? []) as $set) {
                        if (!empty($set['completed']) && (isset($set['durationSeconds']) ? (int)$set['durationSeconds'] > 0 : (int)($set['reps'] ?? 0) > 0)) {
                            $confirmed = true; $confirmedAt = $session['savedAt']; break 3;
                        }
                    }
                }
            }
        }
        if ($confirmed) {
            $sessions[$date] = true;
            $zone = new DateTimeZone('Asia/Shanghai');
            $hour = (int)(new DateTimeImmutable('@' . ((int)$confirmedAt + 978307200)))->setTimezone($zone)->format('G');
            $sessions[$date] = $hour; // reuse map: date => saved hour
        }
        if (!empty($day['meals']) && is_array($day['meals'])) $mealDays++;
    }
    $count = count($sessions);
    if ($count >= 8) {
        $remember('habit',
            '近四周确认训练 ' . $count . ' 次，训练频率稳定', min(90, 40 + $count * 4),
            array_map(fn($date) => 'day/' . $date, array_keys($sessions)), 'training-frequency', $revision);
    } elseif ($count >= 4) {
        $remember('habit',
            '近四周确认训练 ' . $count . ' 次', 60,
            array_map(fn($date) => 'day/' . $date, array_keys($sessions)), 'training-frequency', $revision);
    }
    if ($count >= AI_MEMORY_MIN_SESSIONS_FOR_TIMING) {
        $buckets = ['清晨' => 0, '白天' => 0, '晚上' => 0];
        foreach ($sessions as $hour) {
            if (!is_int($hour)) continue;
            if ($hour < 11) $buckets['清晨']++;
            elseif ($hour < 17) $buckets['白天']++;
            else $buckets['晚上']++;
        }
        arsort($buckets);
        $top = array_key_first($buckets);
        if ($buckets[$top] >= ceil($count * 0.6)) {
            $remember('habit', '常在' . $top . '训练', 70,
                ['workout-saved-hours'], 'training-time', $revision);
        }
    }
    if ($mealDays >= 10) {
        $remember('habit', '近四周有 ' . $mealDays . ' 天记录了饮食', 65,
            ['meals/window'], 'meal-logging', $revision);
    }
    // A derived claim with no current evidence is no longer eligible for UI/context.
    // Keep the row and stable key for audit; future evidence can refresh it. Never change member decisions.
    $sql = "UPDATE user_memory_items SET confidence=0,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND status='active' AND origin='extracted' AND confidence>0";
    $params = [$userId];
    if ($validKeys) { $sql .= ' AND idempotency_key NOT IN (' . implode(',', array_fill(0, count($validKeys), '?')) . ')'; $params = array_merge($params, $validKeys); }
    $db->prepare($sql)->execute($params);
}

/** The member's memory page: three columns per the UI spec. */
function aiMemoryPage(PDO $db, int $userId): array {
    aiMemorySweepExtract($db, $userId);
    $query = $db->prepare("SELECT memory_id,kind,content,confidence,status,origin,evidence_json,supersedes,updated_at
                           FROM user_memory_items WHERE user_id=? AND (status IN ('suspended','corrected') OR (status='active' AND confidence>0))
                           ORDER BY confidence DESC, updated_at DESC LIMIT 100");
    $query->execute([$userId]);
    $columns = ['confirmed' => [], 'habits' => [], 'inferred' => []];
    $profile = function_exists('profileFactsRead') ? profileFactsRead($db, $userId) : null;
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $row = aiMemoryReconcileProfileRow135($row, $profile);
        if ($row === null) continue;
        $row['evidence_refs'] = json_decode((string)$row['evidence_json'], true);
        unset($row['evidence_json']);
        $kind = $row['kind'];
        if (in_array($kind, ['fact', 'goal', 'constraint', 'correction'], true)) $columns['confirmed'][] = $row;
        elseif (in_array($kind, ['habit', 'preference'], true)) $columns['habits'][] = $row;
        else $columns['inferred'][] = $row;
    }
    return $columns;
}

/** Sweep hook: extraction runs against the live document before reads. */
function aiMemorySweepExtract(PDO $db, int $userId, ?array $state = null): void {
    // Independent active-learning control: confirmed facts stay readable, but
    // no new extraction/learning runs while the member has turned it off.
    if (function_exists('actionPreferences') && !(actionPreferences($db, $userId)['proactive_learning'] ?? true)) return;
    if ($state === null) {
        // clubState() lives in the router; standalone tests pass the state explicitly.
        if (function_exists('clubState')) $state = clubState($db, $userId);
        else {
            $q = $db->prepare('SELECT state_json FROM app_states WHERE user_id=?');
            $q->execute([$userId]);
            $state = json_decode((string)($q->fetchColumn() ?: '{}'), true);
        }
        if (!is_array($state)) $state = [];
    }
    $row = $db->prepare('SELECT revision FROM app_states WHERE user_id=?');
    $row->execute([$userId]);
    $revision = (int)$row->fetchColumn();
    aiMemoryExtract($db, $userId, $state, insightHomeToday(), $revision);
}

/** Member correction: supersedes the target with a user-authored statement. */
function aiMemoryCorrect(PDO $db, int $userId, string $memoryId, string $content): array {
    if (mb_strlen($content) < 2 || mb_strlen($content) > 300) fail('纠正内容长度不正确。', 400);
    $target = aiMemoryFetch($db, $userId, $memoryId);
    if (!$target || $target['status'] === 'withdrawn') fail('记忆不存在或已删除。', 404);
    $correctionId = aiMemoryUUID();
    $key = aiMemoryKey($userId, 'correction', $memoryId . ':' . hash('sha256', $content));
    $db->prepare("UPDATE user_memory_items SET status='corrected',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND memory_id=? AND status='active'")
        ->execute([$userId, $memoryId]);
    $db->prepare('INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,supersedes,created_at,updated_at)
                  VALUES(?,?,\'correction\',\'active\',\'user\',?,100,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')
        ->execute([$correctionId, $userId, $content,
                   json_encode([$target['memory_id']], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                   $key, $target['memory_id']]);
    return ['memory_id' => $correctionId, 'supersedes' => $target['memory_id'], 'status' => 'active'];
}

/**
 * Phase 5 feedback loop: a member's feedback on a memory adjusts its
 * confidence. Explicit corrections/suspensions still win — feedback only moves
 * the confidence of an active, user-reviewable memory.
 */
function aiMemoryApplyFeedback(PDO $db, int $userId, array $event): ?array {
    $name = (string)($event['name'] ?? '');
    $target = (string)($event['target_id'] ?? '');
    $action = (string)($event['action'] ?? '');
    if (!in_array($name, ['memory_feedback'], true) || $target === '') return null;
    $existing = aiMemoryFetch($db, $userId, $target);
    if (!$existing || $existing['status'] !== 'active') return null;
    $delta = match ($action) {
        'helpful' => 10,
        'wrong' => -30,
        default => 0,
    };
    if ($delta === 0) return null;
    $statement = $db->prepare('UPDATE user_memory_items SET confidence=GREATEST(0,LEAST(100,confidence+?)),updated_at=UTC_TIMESTAMP() WHERE user_id=? AND memory_id=?');
    $statement->execute([$delta, $userId, $target]);
    if ($statement->rowCount() === 0) return null;
    $query = $db->prepare('SELECT confidence FROM user_memory_items WHERE user_id=? AND memory_id=?');
    $query->execute([$userId, $target]);
    return ['memory_id' => $target, 'confidence' => (int)$query->fetchColumn()];
}

function aiMemorySetStatus(PDO $db, int $userId, string $memoryId, string $status): bool {
    if (!in_array($status, ['suspended', 'active', 'withdrawn'], true)) fail('状态不正确。', 400);
    $existing = aiMemoryFetch($db, $userId, $memoryId);
    if (!$existing) return false;
    if ($status === 'active' && !in_array($existing['status'], ['suspended', 'active'], true)) fail('已删除或纠正的记忆不能恢复。', 409);
    $statement = $db->prepare('UPDATE user_memory_items SET status=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND memory_id=?');
    $statement->execute([$status, $userId, $memoryId]);
    if ($statement->rowCount() > 0) return true;
    // Already in the requested state is a successful no-op (idempotent taps).
    $current = $db->prepare('SELECT status FROM user_memory_items WHERE user_id=? AND memory_id=?');
    $current->execute([$userId, $memoryId]);
    return $current->fetchColumn() === $status;
}

function aiMemoryFetch(PDO $db, int $userId, string $memoryId): ?array {
    if (!preg_match('/^[0-9a-f-]{36}$/iD', $memoryId)) return null;
    $query = $db->prepare('SELECT id,memory_id,kind,status,origin,content,confidence,supersedes FROM user_memory_items WHERE user_id=? AND memory_id=?');
    $query->execute([$userId, $memoryId]);
    return $query->fetch(PDO::FETCH_ASSOC) ?: null;
}

/**
 * Coach context injection: the member's most confident active statements.
 * Hard caps (≤6 items, ≤120 chars each) keep the prompt contribution bounded.
 */
function aiMemoryForContext(PDO $db, int $userId): array {
    aiMemorySweepExtract($db, $userId);
    $query = $db->prepare("SELECT kind,content,confidence,origin,evidence_json FROM user_memory_items
                           WHERE user_id=? AND status='active' AND confidence>0 ORDER BY confidence DESC, updated_at DESC LIMIT " . AI_MEMORY_CONTEXT_ITEMS);
    $query->execute([$userId]);
    $items = [];
    // Read explicit preferences on every request. Clear/edit takes effect even
    // when proactive learning is disabled; no second mutable memory copy exists.
    if (function_exists('profileFactsRead')) {
        $document = profileFactsRead($db,$userId);
        $declared = aiMemoryDeclaredPreference($document['facts'] ?? []);
        if ($declared !== null) $items[] = $declared;
    }
    $profile = function_exists('profileFactsRead') ? profileFactsRead($db, $userId) : null;
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $row = aiMemoryReconcileProfileRow135($row, $profile);
        if ($row === null) continue;
        if (count($items) >= AI_MEMORY_CONTEXT_ITEMS) break;
        $items[] = ['kind' => (string)$row['kind'], 'text' => mb_substr((string)$row['content'], 0, 120)];
    }
    return $items;
}

/** Profile edits are authoritative even if automatic learning is paused. */
function aiMemoryReconcileProfileRow135(array $row, ?array $document): ?array {
    if (($row['origin'] ?? '') !== 'extracted' || $document === null || (int)($document['revision'] ?? 0) <= 0) return $row;
    // 已纠正/暂停的旧记忆保留原文与状态，不能按当前资料重写后再次显示。
    if (in_array((string)($row['status'] ?? ''), ['corrected', 'suspended', 'withdrawn'], true)) return $row;
    $refs = json_decode((string)($row['evidence_json'] ?? '[]'), true);
    if (!is_array($refs)) return $row;
    $facts = is_array($document['facts'] ?? null) ? $document['facts'] : [];
    foreach (['profile/goal' => 'goal', 'profile/limitations' => 'limitations', 'profile/daysPerWeek' => 'days_per_week'] as $ref => $field) {
        if (!in_array($ref, $refs, true)) continue;
        $value = $facts[$field]['value'] ?? null;
        if ($value === null || $value === '') return null;
        if ($field === 'days_per_week') {
            if (!is_numeric($value) || (int)$value < 1 || (int)$value > 7) return null;
            $row['content'] = '计划每周训练 ' . (int)$value . ' 天';
        } elseif ($field === 'goal') $row['content'] = '当前目标：' . mb_substr((string)$value, 0, 30);
        else $row['content'] = '训练限制：' . mb_substr((string)$value, 0, 80);
        return $row;
    }
    return $row;
}

function aiMemoryDeclaredPreference(array $facts): ?array {
    $fact=$facts['personal_preferences']??null;
    if (!is_array($fact) || !in_array($fact['source_kind']??'', ['confirmed','legacy_recorded'], true)) return null;
    $value=trim((string)($fact['value']??''));
    return $value==='' ? null : ['kind'=>'preference','text'=>'成员明确填写：'.mb_substr($value,0,110)];
}
