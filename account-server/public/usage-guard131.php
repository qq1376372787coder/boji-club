<?php
declare(strict_types=1);
/** Atomic short-lived request counters; no message content or raw IP/device IDs. */
function usageGuard131(PDO $db,int $uid,array $config,string $category='ai'): void {
    $secret=(string)($config['otp_secret']??'');if(strlen($secret)<16)throw new RuntimeException('服务保护配置暂不可用。',503);
    $ip=(string)($_SERVER['REMOTE_ADDR']??'unknown');
    $device=(string)($_SERVER['HTTP_X_BOJI_INSTALL']??'');
    $now=time();$window=intdiv($now,60)*60;
    $limits=[['account',strval($uid),$category==='context'?20:12],['ip',$ip,$category==='context'?120:90]];
    if(preg_match('/^[a-f0-9-]{36}$/Di',$device))$limits[]=['device',strtolower($device),$category==='context'?30:20];
    $owns=!$db->inTransaction();if($owns)$db->beginTransaction();
    try {
        foreach($limits as [$scope,$identity,$limit]){
            $key=hash_hmac('sha256',$category.':'.$scope.':'.$identity,$secret);
            $db->prepare('INSERT INTO ai_guard_buckets131(bucket_key,window_start,hits) VALUES(?,?,1) ON DUPLICATE KEY UPDATE hits=hits+1')->execute([$key,$window]);
            $q=$db->prepare('SELECT hits FROM ai_guard_buckets131 WHERE bucket_key=? AND window_start=? FOR UPDATE');$q->execute([$key,$window]);
            if((int)$q->fetchColumn()>$limit)throw new RuntimeException('发送较频繁，请稍等片刻再试，输入已保留。',429);
        }
        $db->prepare('DELETE FROM ai_guard_buckets131 WHERE window_start<? LIMIT 100')->execute([$now-3600]);
        if($owns)$db->commit();
    }catch(Throwable $e){if($owns&&$db->inTransaction())$db->rollBack();throw $e;}
}
