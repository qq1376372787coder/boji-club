<?php
declare(strict_types=1);
require_once __DIR__.'/media-store.php';

// Queue insertion shares the state transaction. A failed unlink never loses its retry.
function enqueueMediaCleanup(PDO $db,int $userID,string $mediaID): void {
    if(!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg$/D',$mediaID)) throw new RuntimeException('Invalid cleanup media');
    $db->prepare('INSERT IGNORE INTO media_cleanup_queue(user_id,media_id,next_attempt,created_at) VALUES(?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())')->execute([$userID,$mediaID]);
}

function processMediaCleanup(PDO $db,?int $userID=null,int $limit=20): int {
    $limit=max(1,min(100,$limit));
    $q=$db->prepare('SELECT user_id,media_id FROM media_cleanup_queue WHERE next_attempt<=UTC_TIMESTAMP()'.($userID===null?'':' AND user_id=?').' ORDER BY next_attempt LIMIT '.$limit);
    $q->execute($userID===null?[]:[$userID]);
    foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $mediaLock=null;
        $db->beginTransaction();
        try {
            $args=[(int)$row['user_id'],$row['media_id']];
            $lock=$db->prepare('SELECT media_id FROM media_cleanup_queue WHERE user_id=? AND media_id=? FOR UPDATE');$lock->execute($args);
            if(!$lock->fetchColumn()){$db->commit();continue;}
            $directory=dirname(__DIR__).'/media/'.$args[0];
            $valid=preg_match('/^[a-f0-9-]{36}\.jpg$/D',$args[1])===1 && !is_link($directory);
            if($valid) {
                $mediaLock=mediaStoreLockAcquire($db,$args[0],$args[1]);
                mediaStoreRecover($db,$args[0],$directory,$args[1],true);
            }
            $ok=$valid && mediaStoreRemove($directory,$args[1]);
            if($ok)$db->prepare('DELETE FROM media_cleanup_queue WHERE user_id=? AND media_id=?')->execute($args);
            else $db->prepare("UPDATE media_cleanup_queue SET attempts=attempts+1,last_error_code='media_cleanup',next_attempt=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 60 SECOND) WHERE user_id=? AND media_id=?")->execute($args);
            if(is_string($mediaLock)) { mediaStoreLockRelease($db,$mediaLock); $mediaLock=null; }
            $db->commit();
        } catch(Throwable $error) {
            if(is_string($mediaLock)) mediaStoreLockRelease($db,$mediaLock);
            if($db->inTransaction())$db->rollBack();
            error_log('Media cleanup deferred');
        }
    }
    if($userID===null)return (int)$db->query('SELECT COUNT(*) FROM media_cleanup_queue')->fetchColumn();
    $q=$db->prepare('SELECT COUNT(*) FROM media_cleanup_queue WHERE user_id=?');$q->execute([$userID]);return (int)$q->fetchColumn();
}
