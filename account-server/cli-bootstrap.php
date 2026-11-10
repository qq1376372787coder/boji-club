<?php
declare(strict_types=1);
/** Shared domain adapter for workers; HTTP adapters provide their own helpers. */
if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__.'/public/action-support.php';
if (!function_exists('fail')) {
    function fail(string $message, int $code = 400): never { businessReject($code, ['error'=>$message]); }
}
if (!function_exists('lockActiveUser')) {
    function lockActiveUser(PDO $db, int $uid): void {
        $q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");
        $q->execute([$uid]);
        if (!$q->fetchColumn()) fail('账号不可用。',403);
    }
}
