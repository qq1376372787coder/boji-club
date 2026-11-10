<?php
declare(strict_types=1);
// A new member may inspect and apply an initial plan before choosing a paid
// membership. Keep this exception limited to plan jobs created during onboarding.
function aiMayPostWithoutMembership(PDO $db, int $userID, string $kind, ?array $existing): bool {
    if (!in_array($kind, ['generate_plan', 'parse_plan'], true)) return false;
    // V2 onboarding: eligibility comes from the server-owned session minimum
    // fields, not from a profiles row padded with fake defaults.
    if (function_exists('onboardingActiveSession') && function_exists('onboardingSessionPublic')) {
        if (function_exists('onboardingConfig') && !onboardingConfig($db)['enabled']) {
            // Fall through to the old explicit onboarding branch, if any.
        } else {
        $session = onboardingActiveSession($db, $userID);
        if ($session && (string)$session['status'] !== 'completed') {
            $public = onboardingSessionPublic($db, $session);
            $eligible = (bool)($public['plan_ready'] ?? false) || (string)$session['task_kind'] === 'plan_import';
            if ($eligible) {
                if ($existing) {
                    return $existing['kind'] === $kind &&
                        (string)($existing['purpose'] ?? '') !== 'onboarding_assist';
                }
                $count = $db->prepare("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id=? AND kind IN ('generate_plan','parse_plan')");
                $count->execute([$userID]);
                return (int)$count->fetchColumn() < 5;
            }
        }
        }
    }
    $profile = $db->prepare('SELECT o.completed_at FROM onboarding o JOIN profiles p ON p.user_id=o.user_id WHERE o.user_id=?');
    $profile->execute([$userID]);
    $onboarding = $profile->fetch(PDO::FETCH_ASSOC);
    if (!$onboarding) return false;
    if ($existing) {
        return $existing['kind'] === $kind &&
            ($onboarding['completed_at'] === null || $existing['created_at'] <= $onboarding['completed_at']);
    }
    if ($onboarding['completed_at'] !== null) return false;
    $count = $db->prepare("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id=? AND kind IN ('generate_plan','parse_plan')");
    $count->execute([$userID]);
    return (int)$count->fetchColumn() < 5;
}
// Shared by HTTP and CLI consumers (the SSE worker/test runner must not depend
// on weekly.php being included first).
function aiUsageDayStart(?int $now=null): string {
    $now ??= time();
    return gmdate('Y-m-d H:i:s', intdiv($now + 8 * 3600, 86400) * 86400 - 8 * 3600);
}

const AI_COACH_DAILY_LIMIT = 100; // Phase 5 §6.2: 对话维度配额（防滥用上限，正常使用远低于此）

function aiCoachQuotaLeft(PDO $db, int $userId): int {
    $count = $db->prepare("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id=? AND kind='coach' AND created_at>=?");
    $count->execute([$userId, aiUsageDayStart()]);
    return max(0, AI_COACH_DAILY_LIMIT - (int)$count->fetchColumn());
}

function aiMayPostJob(PDO $db, array $user, array $config, string $kind, ?array $existing, ?string $purpose = null): bool {
    $enforced=$config['membership_enforcement']??true;
    if($enforced===false||in_array(strtolower((string)$enforced),['0','false','off','no',''],true))return true;
    $member = $db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND status='active' AND expires_at>UTC_TIMESTAMP()");
    $member->execute([(int)$user['id']]);
    return (bool)$member->fetchColumn()
        || aiMayPostWithoutMembership($db, (int)$user['id'], $kind, $existing)
        || ($kind === 'coach' && $purpose === 'onboarding_assist' && onboardingAssistEntitled($db, (int)$user['id']))
        || ($kind === 'coach' && $purpose !== 'onboarding_assist' && aiNaturalOnboardingSession($db, (int)$user['id']) !== null);
}

/**
 * The restricted onboarding assistant is the only coach-shaped allowance for a
 * non-member. It is not a general coach waiver: the caller must have an active,
 * server-owned onboarding session, and the run is still purpose-bound and
 * budgeted separately from the five initial-plan jobs.
 */
function onboardingAssistEntitled(PDO $db, int $userID): bool {
    if (!function_exists('onboardingConfig')) return false;
    $config = onboardingConfig($db);
    if (!$config['enabled']) return false;
    $query = $db->prepare("SELECT 1 FROM user_onboarding_heads h JOIN user_onboarding_sessions s ON s.id=h.active_session_id
        WHERE h.user_id=? AND s.user_id=? AND s.status IN ('task_selected','collecting','review','first_task_ready','deferred') LIMIT 1");
    $query->execute([$userID, $userID]);
    return (bool)$query->fetchColumn();
}

/** The ordinary conversation uses the existing bounded onboarding allowance. */
function aiNaturalOnboardingSession(PDO $db, int $userID): ?string {
    if (!onboardingAssistEntitled($db, $userID)) return null;
    $query = $db->prepare("SELECT s.id FROM user_onboarding_heads h JOIN user_onboarding_sessions s ON s.id=h.active_session_id LEFT JOIN onboarding o ON o.user_id=h.user_id WHERE h.user_id=? AND s.user_id=? AND o.completed_at IS NULL AND s.status IN ('task_selected','collecting','review','first_task_ready','deferred') LIMIT 1");
    $query->execute([$userID, $userID]);
    $id = $query->fetchColumn();
    return is_string($id) ? $id : null;
}

/** Called under the user lock and only for a new idempotent coach job. */
function aiReserveNaturalOnboarding(PDO $db, int $userID, array $config, ?string $purpose): void {
    if ($purpose === 'onboarding_assist') return;
    $enforced = $config['membership_enforcement'] ?? true;
    if ($enforced === false || in_array(strtolower((string)$enforced), ['0','false','off','no',''], true)) return;
    $member = $db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND status='active' AND expires_at>UTC_TIMESTAMP()");
    $member->execute([$userID]);
    if ($member->fetchColumn()) return;
    $session = aiNaturalOnboardingSession($db, $userID);
    if ($session !== null) onboardingAssistReserve($db, $userID, $session);
}
