<?php
declare(strict_types=1);
require_once __DIR__ . '/engine-proxy.php';

/**
 * Phase 2 §2.5 / D-09: server-owned home insight (GET /me/ai/insights/home).
 *
 * Scope is deliberately narrow: only facts the SERVER can verify from its own
 * sources — job completions it verified (weekly reviews, daily reports) and
 * the same confirmed-training-day counting the club progress uses. It is NOT
 * a PHP mirror of the client's document-derived insight rules (D-03 keeps
 * those client-side until server projections mature; duplicating them would
 * create a drift hazard). The client merges by priority and falls back to its
 * local rules offline. Function-only module, testable without the router.
 */

function insightHomeToday(): string {
    return (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
}

function insightHomeFact(array $fact): ?array {
    $id = $fact['id'] ?? null;
    $kind = $fact['kind'] ?? null;
    $title = $fact['title'] ?? null;
    $detail = $fact['detail'] ?? null;
    $evidence = $fact['evidence'] ?? null;
    $priority = $fact['priority'] ?? null;
    $refs = $fact['evidence_refs'] ?? null;
    if (!is_string($id) || $id === '' || strlen($id) > 120) return null;
    if (!is_string($kind) || !in_array($kind, ['training', 'nutrition', 'body', 'workout', 'plan'], true)) return null;
    if (!is_string($title) || $title === '' || mb_strlen($title) > 120) return null;
    if (!is_string($detail) || mb_strlen($detail) > 500) return null;
    if (!is_string($evidence) || $evidence === '' || mb_strlen($evidence) > 300) return null;
    if (!is_int($priority)) return null;
    if (!is_array($refs)) return null;
    foreach ($refs as $ref) if (!is_string($ref) || $ref === '' || strlen($ref) > 120) return null;
    return ['id' => $id, 'kind' => $kind, 'title' => $title, 'detail' => $detail,
            'evidence' => $evidence, 'priority' => $priority, 'evidence_refs' => array_values($refs)];
}

/**
 * The single highest-priority server fact for today, or null when the server
 * has nothing verified to say (client keeps its local insight).
 */
function insightHomePick(PDO $db, int $userId, array $state, string $today): ?array {
    if (function_exists('actionPreferences') && !(actionPreferences($db, $userId)['proactive_learning'] ?? true)) return null;
    $windowStart = (new DateTimeImmutable($today))->modify('-6 days')->format('Y-m-d');
    $facts = [];

    // F1 (priority 108): newest VERIFIED weekly review inside the window.
    $reviewRefs = [];
    foreach (($state['days'] ?? []) as $date => $day) {
        if (!is_string($date) || $date > $today || $date < $windowStart || !is_array($day)) continue;
        $review = $day['weeklyReview'] ?? null;
        if (is_array($review) && is_array($review['result'] ?? null) && is_string($review['jobID'] ?? null)) {
            $reviewRefs[$date] = (string)$review['jobID'];
        }
    }
    if ($reviewRefs) {
        $verified = verifiedAICompletions($db, $userId,
            array_map(fn($id) => ['id' => $id, 'kind' => 'weekly_review'], array_values($reviewRefs)));
        $latest = null;
        foreach ($reviewRefs as $date => $jobID) {
            if (($verified[strtolower($jobID)] ?? false) !== true) continue;
            if ($latest === null || $date > $latest) $latest = $date;
        }
        if ($latest !== null) {
            $jobID = $reviewRefs[$latest];
            $facts[] = insightHomeFact([
                'id' => 'server/weekly-review/' . $latest,
                'kind' => 'workout',
                'title' => '训练复盘已生成',
                'detail' => '这一期的复盘已按已确认记录生成。可以查看内容，再核对下一周的安排。',
                'evidence' => '依据：' . $latest . ' 的复盘结果已通过服务端核验（任务 ' . $jobID . '）。',
                'priority' => 108,
                'evidence_refs' => ['job/' . strtolower($jobID), 'day/' . $latest],
            ]) ?? [];
        }
    }

    // F2 (priority 104): confirmed training days in the last 7 days, counted
    // with the club progress semantics (trained set + saved/confirmed session).
    $confirmedDates = [];
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
        $confirmed = $trained && !empty($day['workoutSavedAt']);
        if (!empty($day['workoutSessions'])) {
            $confirmed = false;
            foreach (($day['workoutSessions'] ?? []) as $session) {
                if (empty($session['savedAt'])) continue;
                foreach (($day['exercises'] ?? []) as $exercise) {
                    if (strtolower((string)($exercise['workoutSessionID'] ?? '')) !== strtolower((string)$session['id'])) continue;
                    foreach (($exercise['sets'] ?? []) as $set) {
                        if (!empty($set['completed']) && (isset($set['durationSeconds']) ? (int)$set['durationSeconds'] > 0 : (int)($set['reps'] ?? 0) > 0)) {
                            $confirmed = true; break 3;
                        }
                    }
                }
            }
        }
        if ($confirmed) $confirmedDates[] = $date;
    }
    if (count($confirmedDates) >= 1) {
        $facts[] = insightHomeFact([
            'id' => 'server/training-rhythm/' . $windowStart,
            'kind' => 'training',
            'title' => '最近 7 天已确认 ' . count($confirmedDates) . ' 次训练',
            'detail' => '已确认的训练日是记录可信的基础。保持节奏，趋势与分析会更可靠。',
            'evidence' => '依据：最近 7 天确认训练日计数，口径与俱乐部进度同源。',
            'priority' => 104,
            'evidence_refs' => array_map(fn($date) => 'day/' . $date, $confirmedDates),
        ]) ?? [];
    }

    if ($club = insightClubFact($db, $userId, $today)) $facts[] = $club;
    $facts = array_values(array_filter($facts, fn($fact) => is_array($fact) && $fact !== []));

    // Phase 4 §5.4: relevance+timeliness+confidence+actionability−repetition.
    // Weights are intentionally simple and documented for tuning (D-12 口径).
    foreach ($facts as $i => $fact) {
        $score = 50.0;                                  // relevance base: server-verified fact
        $age = (strtotime($today) - strtotime(substr((string)$fact['id'], strrpos((string)$fact['id'], '/') + 1)));
        $score += ($age === 0) ? 20.0 : (($age <= 3 * 86400) ? 10.0 : 0.0);   // timeliness
        $score += min(100, (int)$fact['priority']) * 0.4;                     // confidence proxy
        $score += (!empty($fact['evidence_refs']) && count($fact['evidence_refs']) > 1) ? 15.0 : 0.0; // actionability proxy
        $score -= 25.0 * max(0, $i - 0) * 0;             // repetition handled by dedupe below
        $facts[$i]['score'] = round($score, 1);
    }
    // 同类去重：每 kind 只保留最高分一条。
    $best = [];
    foreach ($facts as $fact) {
        $kind = $fact['kind'];
        if (!isset($best[$kind]) || $fact['score'] > $best[$kind]['score']) $best[$kind] = $fact;
    }
    $facts = array_values($best);
    usort($facts, fn($a, $b) => $b['score'] <=> $a['score']);
    if ($facts === []) return null;

    // Phase 3/5: deterministic ranker owns daily cap and cross-id cooldowns.
    // If the worker is unavailable, keep the documented local score fallback.
    $history = [];
    try {
        $feedback = $db->prepare("SELECT target_id,action,detail_json,created_at FROM ai_feedback_events
            WHERE user_id=? AND kind='insight' AND target_id IS NOT NULL
              AND created_at>=DATE_SUB(UTC_TIMESTAMP(), INTERVAL 7 DAY)");
        $feedback->execute([$userId]);
        foreach ($feedback->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $id = (string)$row['target_id'];
            $detail = json_decode((string)($row['detail_json'] ?? ''), true);
            $entry = $history[$id] ?? ['last_shown_at' => $row['created_at'],
                'kind' => is_array($detail) ? (string)($detail['kind'] ?? '') : '',
                'subject_id' => is_array($detail) ? (string)($detail['subject_id'] ?? $id) : $id];
            if (in_array((string)$row['action'], ['dismiss', 'reject', 'reduce'], true)) {
                $entry['dismissed_count'] = (int)($entry['dismissed_count'] ?? 0) + 1;
            }
            $history[$id] = $entry;
        }
    } catch (Throwable $error) { /* feedback table is optional for old schemas */ }
    $candidates = array_map(fn($fact) => [
        'insight_id' => (string)$fact['id'],
        'kind' => (string)$fact['kind'],
        'subject_id' => (string)$fact['id'],
        'confidence' => min(1, max(0, ((int)$fact['priority']) / 120)),
        'evidence_refs' => $fact['evidence_refs'],
        'data_quality' => 'sufficient_for_advisory',
        'created_at' => $today . 'T00:00:00+00:00',
    ], $facts);
    $ranked = engineRequest($GLOBALS['config'] ?? [], '/v1/personal/insights/rank',
        ['candidates' => $candidates, 'history' => $history], 1.0);
    if (is_array($ranked['result'] ?? null)) {
        $selected = $ranked['result']['selected'] ?? [];
        if (!is_array($selected) || $selected === []) return null;
        $chosen = (string)($selected[0]['insight_id'] ?? '');
        foreach ($facts as $fact) if ((string)$fact['id'] === $chosen) return $fact;
        return null;
    }
    return $facts[0] ?? null;
}

/** Phase 5 §6.1: club progress explanation fact (read-only; claiming stays on the deterministic claim endpoint). */
function insightClubFact(PDO $db, int $userId, string $today): ?array {
    $season = $db->prepare('SELECT id,title FROM club_seasons WHERE starts_on<=? AND ends_on>=? ORDER BY starts_on DESC LIMIT 1');
    $season->execute([$today, $today]);
    $row = $season->fetch(PDO::FETCH_ASSOC);
    if (!$row) return null;
    require_once __DIR__ . '/club-progress.php';
    $seasonFull = $db->prepare('SELECT * FROM club_seasons WHERE id=?');
    $seasonFull->execute([(int)$row['id']]);
    $seasonRow = $seasonFull->fetch(PDO::FETCH_ASSOC);
    if (!is_array($seasonRow)) return null;
    $counts = clubProgress($db, $userId, $seasonRow);
    $done = (int)($counts['training_days'] ?? 0);
    $tasks = $db->prepare('SELECT COUNT(*) FROM club_tasks WHERE season_id=?');
    $tasks->execute([(int)$row['id']]);
    $total = (int)$tasks->fetchColumn();
    if ($total <= 0) return null;
    return insightHomeFact([
        'id' => 'server/club-progress/' . $row['id'],
        'kind' => 'plan',
        'title' => '俱乐部赛季进行中',
        'detail' => '本季已确认 ' . $done . ' 个训练日。任务与奖励进度以俱乐部页为准；确认记录即可推进任务。',
        'evidence' => '依据：服务端俱乐部进度计数（与俱乐部页同源）。',
        'priority' => 90,
        'evidence_refs' => ['season/' . $row['id']],
    ]);
}
