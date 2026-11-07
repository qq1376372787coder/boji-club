<?php
declare(strict_types=1);
require_once __DIR__.'/storage-settings.php';

function mediaQuotaProblem(int $totalBytes, int $files, int $oldBytes, int $newBytes, int $recentWrites, array $config = []): ?array {
    $limit = max(0, (int)($config['media_storage_limit_bytes'] ?? 0));
    $fileLimit = max(0, (int)($config['media_file_limit'] ?? 0));
    $rate = max(1, (int)($config['media_uploads_per_minute'] ?? 120));
    if ($recentWrites >= $rate) return ['status' => 429, 'message' => '照片上传较密集，文字记录仍可同步，请稍后重试照片。'];
    if (($limit>0 && $totalBytes - max(0, $oldBytes) + $newBytes > $limit) || ($fileLimit>0 && $oldBytes === 0 && $files >= $fileLimit)) {
        return ['status' => 413, 'message' => '这个账号的照片空间已满，文字记录仍可同步。请先备份并清理不需要的照片附件。'];
    }
    return null;
}

// Caller holds the active user's row lock, shared by uploads and state changes.
function checkMediaQuota(PDO $db, int $userID, string $mediaID, int $newBytes, array $config): ?array {
    $config=storageRuntimeSettings($db,$config);
    $q = $db->prepare('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS files FROM user_media WHERE user_id=?');
    $q->execute([$userID]); $usage = $q->fetch(PDO::FETCH_ASSOC);
    // Count successful uploads, including replacement of the same image. Counting
    // recently changed image rows would let repeated overwrites bypass the rate.
    $q = $db->prepare('SELECT COUNT(*) FROM media_upload_events WHERE user_id=? AND uploaded_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 MINUTE)');
    $q->execute([$userID]);$recent=(int)$q->fetchColumn();
    $q = $db->prepare('SELECT byte_size FROM user_media WHERE user_id=? AND media_id=?'); $q->execute([$userID,$mediaID]);
    return mediaQuotaProblem((int)$usage['bytes'], (int)$usage['files'], (int)($q->fetchColumn() ?: 0), $newBytes, $recent, $config);
}
