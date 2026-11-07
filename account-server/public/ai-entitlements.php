<?php
declare(strict_types=1);
require_once __DIR__ . '/membership-access.php';

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

/** Existing jobs and onboarding purposes never bypass paid membership. */
function aiMayPostJob(PDO $db, array $user, array $config, string $kind, ?array $existing, ?string $purpose = null): bool {
    return membershipHasActiveEntitlement($db, (int)$user['id']);
}
