<?php
declare(strict_types=1);

function recoveredAppleDeletionStatus(PDO $db,array $config,int $id,string $subject): ?array {
    $hash=hash_hmac('sha256',$id.':apple:'.$subject,$config['otp_secret']);
    $q=$db->prepare("SELECT status FROM account_deletions WHERE subject_hash=? AND (status<>'completed' OR updated_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY))");$q->execute([$hash]);$status=$q->fetchColumn();
    if(is_string($status)) return ['accepted'=>true,'deleted'=>$status==='completed','status'=>$status];
    $q=$db->prepare("SELECT 1 FROM users WHERE id=? AND apple_subject=? AND status='active'");$q->execute([$id,$subject]);
    return $q->fetchColumn() ? ['accepted'=>false] : null;
}

function queuedAccountDeletion(PDO $db, string $token): ?array {
    if (strlen($token)<32) return null;
    $q=$db->prepare('SELECT status,user_id FROM account_deletions WHERE token_hash=?');
    $q->execute([hash('sha256',$token)]);
    return $q->fetch() ?: null;
}

function enqueueAccountDeletion(PDO $db, array $user, array $config, bool $adminInitiated131=false, ?callable $onQueued131=null): void {
    $userID=(int)$user['id'];
    $db->beginTransaction();
    try {
        $q=$db->prepare('SELECT status,apple_subject FROM users WHERE id=? FOR UPDATE');$q->execute([$userID]);
        $locked=$q->fetch();if(!$locked || !in_array($locked['status'],$adminInitiated131?['active','disabled']:['active'],true)) throw new RuntimeException('Account unavailable');
        $user['apple_subject']=$locked['apple_subject'];
        $q=$db->prepare("SELECT id FROM account_deletions WHERE user_id=? AND status<>'completed' LIMIT 1");$q->execute([$userID]);
        if($q->fetchColumn()) { $db->commit(); return; }
        if($adminInitiated131) $user['token_hash']=hash('sha256',random_bytes(32));

        $q=$db->prepare("SELECT COUNT(*) FROM club_reward_claims WHERE user_id=? AND status IN ('pending','confirmed','packing','shipped','problem')");$q->execute([$userID]);
        if((int)$q->fetchColumn()>0) { throw new RuntimeException('还有未结束的礼品申领，请先处理后再删除账号。',409); }
        $q=$db->prepare('SELECT server_job_id FROM ai_user_jobs WHERE user_id=?');$q->execute([$userID]);
        $jobs=$q->fetchAll(PDO::FETCH_COLUMN);
        $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$userID]);
        $state=json_decode((string)($q->fetchColumn() ?: ''),true);
        if(($state['_partitioned']??null)===2) {
            $cursor='';
            do {
                $q=$db->prepare("SELECT part_key,JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.weeklyReview.jobID')) AS job_id FROM cloud_parts WHERE user_id=? AND part_key LIKE 'd/%' AND part_key>? ORDER BY part_key LIMIT 100");$q->execute([$userID,$cursor]);$parts=$q->fetchAll(PDO::FETCH_ASSOC);
                foreach($parts as $part) { $cursor=$part['part_key'];$client=$part['job_id'];if(is_string($client)&&preg_match('/^[a-f0-9-]{36}$/i',$client))$jobs[]=weeklyAiJobID($userID,$client,$config); }
            } while(count($parts)===100);
        }
        foreach(($state['days'] ?? []) as $day) {
            $client=$day['weeklyReview']['jobID'] ?? null;
            if(is_string($client) && preg_match('/^[a-f0-9-]{36}$/i',$client)) $jobs[]=weeklyAiJobID($userID,$client,$config);
        }
        $jobs=array_values(array_unique($jobs));
        $db->prepare("INSERT INTO account_deletions(user_id,token_hash,subject_hash,status,job_ids,created_at,updated_at,next_attempt) VALUES(?,?,?,'queued',?,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$userID,$user['token_hash'],!empty($user['apple_subject'])?hash_hmac('sha256',$userID.':apple:'.$user['apple_subject'],$config['otp_secret']):null,json_encode($jobs,JSON_THROW_ON_ERROR)]);
        $db->prepare("UPDATE users SET status='disabled',updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$userID]);
        $db->prepare('DELETE FROM sessions WHERE user_id=?')->execute([$userID]);
        if($onQueued131)$onQueued131();
        $db->commit();
    } catch(Throwable $error) { if($db->inTransaction())$db->rollBack();throw $error; }
}

function deletionRemoveMedia(int $userID): void {
    $directory=dirname(__DIR__).'/media/'.$userID;
    if(!file_exists($directory)) return;
    if(is_link($directory)) throw new RuntimeException('media_link');
    $items=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($directory,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);
    foreach($items as $item) {
        $ok=$item->isLink() || $item->isFile() ? unlink($item->getPathname()) : rmdir($item->getPathname());
        if(!$ok) throw new RuntimeException('media_cleanup');
    }
    if(!rmdir($directory)) throw new RuntimeException('media_cleanup');
}

function deletionRemoveAI(array $config, string $id): bool {
    $token=$config['ai_proxy_token'] ?? '';
    $base=$config['ai_proxy_base_url'] ?? 'http://127.0.0.1:8787';
    if(strlen($token)<24 || !preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base) || !preg_match('/^[a-f0-9-]{36}$/i',$id)) return false;
    $context=stream_context_create(['http'=>['method'=>'DELETE','header'=>"Authorization: Bearer ".$token."\r\n",'timeout'=>15,'ignore_errors'=>true,'follow_location'=>0]]);
    $raw=@file_get_contents($base.'/v1/jobs/'.$id,false,$context);
    if($raw===false) return false;
    foreach($http_response_header ?? [] as $line) if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$match)) return in_array((int)$match[1],[200,404],true);
    return false;
}

function processAccountDeletion(PDO $db, array $config, array $row): bool {
    $userID=(int)$row['user_id']; $id=(int)$row['id'];
    try {
        $jobs=json_decode($row['job_ids'],true,64,JSON_THROW_ON_ERROR);
        while($jobs) {
            if(!deletionRemoveAI($config,$jobs[0])) throw new RuntimeException('ai_cleanup');
            array_shift($jobs);
            $db->prepare('UPDATE account_deletions SET job_ids=?,updated_at=UTC_TIMESTAMP() WHERE id=?')->execute([json_encode(array_values($jobs),JSON_THROW_ON_ERROR),$id]);
        }
        require_once __DIR__.'/ai-response.php';
        $erased=aiQuotaRequest($config,'erase',['owner'=>aiQuotaOwner($userID,$config)]);
        if(($erased['erased']??false)!==true) throw new RuntimeException('ai_cleanup');
        // File failures remain visible to the durable retry queue.
        deletionRemoveMedia($userID);
        require_once __DIR__.'/apple-tokens.php';
        appleRevokeStoredTokens($db,$config,$userID);
        $db->beginTransaction();
        $q=$db->prepare('SELECT phone FROM users WHERE id=? FOR UPDATE');$q->execute([$userID]);$phone=$q->fetchColumn();
        if(is_string($phone) && $phone!=='')$db->prepare('DELETE FROM verification_codes WHERE phone=?')->execute([$phone]);
        $db->prepare('DELETE FROM member_admin_notes WHERE user_id=?')->execute([$userID]);
        $db->prepare('DELETE FROM member_admin_profiles WHERE user_id=?')->execute([$userID]);
        $db->prepare('DELETE FROM notification_deliveries WHERE user_id=?')->execute([$userID]);
        // Keep the operator-accountability trail without the member's data.
        // Deleting these rows let a self-service erasure remove evidence of
        // admin actions; redacting detail and unlinking the member preserves
        // both privacy and auditability.
        $db->prepare("UPDATE admin_audit SET target_user_id=NULL,detail='成员已注销：明细已按隐私要求清除' WHERE target_user_id=?")->execute([$userID]);
        $db->prepare("UPDATE revenuecat_events SET user_id=NULL,app_user_id='',transaction_id=NULL,original_transaction_id=NULL,expires_at=NULL,payload_hash='' WHERE user_id=? OR app_user_id=?")->execute([$userID,'boji-'.$userID]);
        $db->prepare('DELETE FROM users WHERE id=?')->execute([$userID]);
        $db->prepare("UPDATE account_deletions SET status='completed',user_id=NULL,job_ids='[]',last_error_code=NULL,updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$id]);
        $db->commit(); return true;
    } catch(Throwable $error) {
        if($db->inTransaction())$db->rollBack();
        $code=$error instanceof RuntimeException && in_array($error->getMessage(),['ai_cleanup','media_cleanup','media_link','apple_revocation','apple_configuration','apple_token_storage'],true) ? $error->getMessage() : 'cleanup_error';
        // Exponential backoff prevents a handful of permanently failing rows
        // from occupying the worker's LIMIT on every minute. After ten failed
        // rounds the row stops automatically and needs an operator decision.
        $attempts=(int)$row['attempts']+1;
        if($attempts>=10) {
            $db->prepare("UPDATE account_deletions SET status='failed',attempts=?,last_error_code=?,updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$attempts,$code,$id]);
            error_log('BOJI account deletion needs manual review: id='.$id.' code='.$code);
            return false;
        }
        $db->prepare("UPDATE account_deletions SET status='retrying',attempts=?,last_error_code=?,next_attempt=DATE_ADD(UTC_TIMESTAMP(),INTERVAL LEAST(86400,POW(2,?)*60) SECOND),updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$attempts,$code,$attempts,$id]);
        return false;
    }
}
