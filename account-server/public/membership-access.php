<?php
declare(strict_types=1);

/** One entitlement rule for HTTP routes, AI submission and background consumers. */
function membershipHasActiveEntitlement(PDO $db, int $userID): bool {
    $query = $db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND status='active' AND expires_at>UTC_TIMESTAMP()");
    $query->execute([$userID]);
    return (bool)$query->fetchColumn();
}

/** Account setup, purchase recovery and personal-data management stay outside the app gate. */
function membershipRouteRequiresAccess(string $method, string $path): bool {
    if ($path !== '/me' && !str_starts_with($path, '/me/') && !str_starts_with($path, '/club/')) return false;
    $accountRoutes = [
        'GET' => ['/me', '/me/deletion', '/me/export', '/me/profile-facts', '/me/onboarding/v2'],
        'DELETE' => ['/me'],
        'PUT' => ['/me/onboarding', '/me/push-device'],
        'POST' => ['/me/membership/verify', '/me/ai/consent', '/me/profile-facts/preview',
            '/me/profile-facts/confirm', '/me/profile-facts/dismiss', '/me/profile-facts/clear',
            '/me/onboarding/complete', '/me/onboarding/v2/checkpoints/basic-profile', '/me/onboarding/v2/sessions'],
    ];
    if (in_array($path, $accountRoutes[$method] ?? [], true)) return false;
    if ($method === 'GET' && preg_match('#^/me/profile-facts/proposals/[a-f0-9-]{36}$#iD', $path)) return false;
    if (preg_match('#^/me/onboarding/v2/sessions/[a-f0-9-]{36}/(draft|profile-preview|profile-confirm|defer|complete)$#iD', $path, $match)) {
        if ($method === ($match[1] === 'draft' ? 'PATCH' : 'POST')) return false;
    }
    // Support and account-owned attachment downloads are data-management access,
    // never a route into tasks, reports, training, records or AI submission.
    if ($path === '/me/feedback' || str_starts_with($path, '/me/feedback/')) return false;
    if ($method === 'GET' && preg_match('#^/me/media/[^/]+$#D', $path)) return false;
    return true;
}
