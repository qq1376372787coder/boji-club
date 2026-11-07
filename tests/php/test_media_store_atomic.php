<?php
declare(strict_types=1);
/**
 * FIX-002 protocol regression: immutable version + journal + commit marker.
 * Run against an isolated *_test database:
 *   BOJI_TEST_DSN_BASE=mysql:host=127.0.0.1;port=13306 php tests/php/test_media_store_atomic.php
 */
require __DIR__.'/../php_test_bootstrap.php';
require __DIR__.'/../../account-server/public/media-store.php';

$db = bojiTestDatabase(getenv('BOJI_TEST_DB') ?: 'bojiclub_media_test');
$uid = 990001;
$id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jpg';
$childMode = ($argv[1] ?? '') === 'recover-child';
if ($childMode) {
    $uid = (int)($argv[2] ?? 0); $dir = (string)($argv[3] ?? ''); $id = (string)($argv[4] ?? '');
    echo "READY\n"; flush();
    $mediaLock = mediaStoreLockAcquire($db, $uid, $id);
    mediaStoreRecover($db, $uid, $dir, $id, true);
    $path = mediaStoreResolve($dir, $id);
    echo 'HASH=' . ($path === null ? 'missing' : hash_file('sha256', $path)) . "\n";
    mediaStoreLockRelease($db, $mediaLock);
    exit(0);
}
$dir = sys_get_temp_dir() . '/boji-media-' . bin2hex(random_bytes(4));
mkdir($dir, 0750, true);
$checks = 0;
function checkMedia(bool $condition, string $label): void {
    global $checks;
    if (!$condition) throw new RuntimeException($label);
    $checks++; echo "PASS $label\n";
}
function putVersion(PDO $db, int $uid, string $dir, string $id, string $raw, bool $commit): ?array {
    $db->beginTransaction();
    try {
        $db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([$uid]);
        $event = (int)$db->lastInsertId();
        $journal = mediaStorePrepare($dir, $id, $raw, $event);
        $db->prepare('INSERT INTO user_media(user_id,media_id,byte_size,content_type,created_at,updated_at) VALUES(?,?,?,"image/jpeg",UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE byte_size=VALUES(byte_size),updated_at=UTC_TIMESTAMP()')->execute([$uid,$id,strlen($raw)]);
        if ($commit) { $db->commit(); mediaStoreComplete($dir,$journal,$db,$uid); return $journal; }
        $db->rollBack(); mediaStoreAbort($dir,$journal); return null;
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        if (isset($journal) && is_array($journal)) mediaStoreAbort($dir,$journal);
        throw $error;
    }
}

$db->exec('DELETE FROM media_cleanup_queue WHERE user_id='.$uid);
$db->exec('DELETE FROM user_media WHERE user_id='.$uid);
$db->exec('DELETE FROM media_upload_events WHERE user_id='.$uid);
$db->exec('DELETE FROM users WHERE id='.$uid);
$db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES($uid,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");

$imageA = base64_decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EB//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EB//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EB//2Q==');
$imageB = $imageA . str_repeat('B', 32);

putVersion($db, $uid, $dir, $id, $imageA, true);
checkMedia(mediaStoreResolve($dir, $id) !== null && file_get_contents(mediaStoreResolve($dir, $id)) === $imageA, 'first immutable version is published');
checkMedia((int)$db->query("SELECT byte_size FROM user_media WHERE user_id=$uid AND media_id='$id'")->fetchColumn() === strlen($imageA), 'first upload metadata matches bytes');

// SQL/commit failure: the old version must remain and the new one is removed.
$db->beginTransaction();
try {
    $db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([$uid]);
    $event = (int)$db->lastInsertId();
    $journal = mediaStorePrepare($dir, $id, $imageB, $event);
    $db->prepare('UPDATE user_media SET byte_size=? WHERE user_id=? AND media_id=?')->execute([strlen($imageB),$uid,$id]);
    throw new RuntimeException('injected SQL/commit failure');
} catch (Throwable $error) {
    $db->rollBack();
    mediaStoreAbort($dir, $journal);
}
checkMedia(file_get_contents(mediaStoreResolve($dir, $id)) === $imageA, 'failed replacement keeps old bytes');
checkMedia((int)$db->query("SELECT byte_size FROM user_media WHERE user_id=$uid AND media_id='$id'")->fetchColumn() === strlen($imageA), 'failed replacement keeps old metadata');
checkMedia(glob($dir.'/'.$id.'.[a-f0-9]*.jpg') !== false && count(glob($dir.'/'.$id.'.[a-f0-9]*.jpg')) === 1, 'failed replacement leaves no orphan version');
checkMedia(!is_file(mediaStoreJournalPath($dir,$id)), 'failed replacement removes journal');

// Crash after COMMIT but before pointer switch: recovery completes it.
$db->beginTransaction();
$db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([$uid]);
$event = (int)$db->lastInsertId();
$journal = mediaStorePrepare($dir, $id, $imageB, $event);
$db->prepare('UPDATE user_media SET byte_size=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND media_id=?')->execute([strlen($imageB),$uid,$id]);
$db->commit();
mediaStoreRecover($db, $uid, $dir, $id);
checkMedia(file_get_contents(mediaStoreResolve($dir, $id)) === $imageB, 'committed journal recovers new bytes');

// A reader recovering during the upload transaction must wait until the PUT
// has either committed and published, or rolled back. It must never abort a
// version merely because its uncommitted event row is invisible to the reader.
$imageC = $imageA . str_repeat('C', 48);
$mediaLock = mediaStoreLockAcquire($db, $uid, $id);
$db->beginTransaction();
$db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([$uid]);
$event = (int)$db->lastInsertId();
$journal = mediaStorePrepare($dir, $id, $imageC, $event);
$db->prepare('UPDATE user_media SET byte_size=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND media_id=?')->execute([strlen($imageC),$uid,$id]);
$pipes = [];
$process = proc_open([PHP_BINARY, __FILE__, 'recover-child', (string)$uid, $dir, $id], [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']], $pipes);
if (!is_resource($process)) throw new RuntimeException('could not start concurrent media reader');
fclose($pipes[0]);
$ready = fgets($pipes[1]);
checkMedia($ready === "READY\n", 'concurrent reader starts recovery while PUT is uncommitted');
usleep(300000);
$childStatus = proc_get_status($process);
checkMedia($childStatus['running'], 'concurrent reader waits for the media replacement lock');
checkMedia(file_get_contents(mediaStoreResolve($dir, $id)) === $imageB, 'previous image remains readable while PUT is uncommitted');
$db->commit();
mediaStoreComplete($dir, $journal, $db, $uid);
mediaStoreLockRelease($db, $mediaLock);
$childOutput = stream_get_contents($pipes[1]);
$childError = stream_get_contents($pipes[2]);
fclose($pipes[1]); fclose($pipes[2]);
$childExit = proc_close($process);
checkMedia($childExit === 0 && str_contains($childOutput, 'HASH=' . hash('sha256', $imageC)), 'concurrent reader sees the committed new image');
checkMedia(file_get_contents(mediaStoreResolve($dir, $id)) === $imageC, 'concurrent recovery never removes the committed image');

// Crash before COMMIT: recovery removes the uncommitted version.
$id2 = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff.jpg';
$db->beginTransaction();
$db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([$uid]);
$event = (int)$db->lastInsertId();
$journal = mediaStorePrepare($dir, $id2, $imageA, $event);
$db->rollBack();
mediaStoreRecover($db, $uid, $dir, $id2);
checkMedia(mediaStoreResolve($dir, $id2) === null, 'uncommitted journal rolls back to no file');
checkMedia(!is_file(mediaStoreJournalPath($dir,$id2)), 'uncommitted journal is removed');

mediaStoreRemove($dir, $id); mediaStoreRemove($dir, $id2);
$db->exec('DELETE FROM media_upload_events WHERE user_id='.$uid);
$db->exec('DELETE FROM user_media WHERE user_id='.$uid);
$db->exec('DELETE FROM users WHERE id='.$uid);
@rmdir($dir);
echo "MEDIA_STORE_ATOMIC_OK checks=$checks\n";
