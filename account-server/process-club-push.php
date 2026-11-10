<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require __DIR__.'/public/automation.php';require __DIR__.'/public/club-push.php';
$config=require __DIR__.'/config.php';if(!clubPushConfigured($config))exit(0);
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
$lock=fopen(sys_get_temp_dir().'/boji-push-'.substr(hash('sha256',(string)$db->query('SELECT DATABASE()')->fetchColumn()),0,16).'.lock','c');if(!$lock||!flock($lock,LOCK_EX|LOCK_NB))exit(0);
$devices=$db->query("SELECT d.* FROM club_push_devices d JOIN users u ON u.id=d.user_id AND u.status='active' JOIN sessions s ON s.token_hash=d.session_hash AND s.user_id=d.user_id AND s.expires_at>UTC_TIMESTAMP() WHERE d.enabled=1 AND d.next_check<=UTC_TIMESTAMP() ORDER BY d.next_check LIMIT 100")->fetchAll();
$deadline=microtime(true)+50;
foreach($devices as $device) {
    if(microtime(true)>$deadline)break;
    $uid=(int)$device['user_id'];
    $db->prepare('UPDATE club_push_devices SET next_check=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 MINUTE) WHERE device_id=?')->execute([$device['device_id']]);
    // 后台手动停发：整账号停发优先于设备开关；停发不删除用户设置与历史回执。
    if(clubPushAccountBlocked($db,$uid))continue;
    $member=$db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND status='active' AND expires_at>UTC_TIMESTAMP()");$member->execute([$device['user_id']]);if(!$member->fetchColumn())continue;
    $query=$db->prepare("SELECT j.client_job_id,j.server_job_id,j.kind,COALESCE(r.attempts,0) AS attempts FROM ai_user_jobs j LEFT JOIN club_push_receipts r ON r.device_id=? AND r.client_job_id=j.client_job_id WHERE j.user_id=? AND j.kind IN ('report','coach','weekly_review') AND j.created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 2 DAY) AND j.created_at>=? AND (r.client_job_id IS NULL OR (r.status='pending' AND r.next_attempt<=UTC_TIMESTAMP())) ORDER BY j.created_at DESC LIMIT 200");
    $query->execute([$device['device_id'],$device['user_id'],$device['notify_after']]);$jobs=$query->fetchAll();if(!$jobs)continue;
    try{
        $metadata=['items'=>[]];$fetchedAll=true;
        foreach(array_chunk(array_column($jobs,'server_job_id'),50) as $ids){if(microtime(true)>$deadline){$fetchedAll=false;break;}$page=clubAutomationPrivate($config,'/v1/jobs/metadata',['ids'=>$ids]);$metadata['items']=array_merge($metadata['items'],$page['items']??[]);}
        $byID=[];foreach($jobs as $job)$byID[$job['server_job_id']]=$job;
        // 被抑制/失效的候选一律记 skipped+原因（可观测），不静默丢弃。
        $skip=function(array $job,string $reason)use($db,$device):void{$db->prepare("INSERT INTO club_push_receipts(device_id,client_job_id,status,next_attempt,reason,updated_at) VALUES(?,?,'skipped',UTC_TIMESTAMP(),?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status='skipped',reason=VALUES(reason),updated_at=UTC_TIMESTAMP()")->execute([$device['device_id'],$job['client_job_id'],$reason]);};
        $seen=[];
        foreach($metadata['items']??[] as $item) {
            if(!isset($byID[$item['id']]))continue;
            $seen[$item['id']]=true;
            if(in_array($item['status'],['deleted','expired','failed','rejected','discarded','cancelled'],true)){$skip($byID[$item['id']],'SourceCancelled');continue;}
            if($item['status']!=='succeeded')continue;
            $job=$byID[$item['id']];$kind=$job['kind'];
            if($kind==='coach'){$purpose=$item['purpose']??'';if(!in_array($purpose,['weekly','workout'],true)){$skip($job,'NotNotifiable');continue;}$kind=$purpose==='weekly'?'club_weekly':'club_workout';}
            $allowed=clubPushAllowed(json_decode($device['preferences_json'],true),$kind);if($allowed===null){$skip($job,'NotNotifiable');continue;}
            if($allowed>time()){
                $db->prepare("INSERT INTO club_push_receipts(device_id,client_job_id,status,next_attempt,updated_at) VALUES(?,?,'pending',?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE next_attempt=VALUES(next_attempt)")->execute([$device['device_id'],$job['client_job_id'],gmdate('Y-m-d H:i:s',$allowed)]);continue;
            }
            // 免打扰延后到点后再确认对象仍然有效：对应报告/提案已删或任务取消时上面的元数据检查会拦下，不发送。
            // Recheck session/device binding immediately before the external send.
            $current=$db->prepare("SELECT 1 FROM club_push_devices d JOIN sessions s ON s.token_hash=d.session_hash AND s.user_id=d.user_id WHERE d.device_id=? AND d.user_id=? AND d.enabled=1 AND d.token=? AND s.expires_at>UTC_TIMESTAMP()");
            $current->execute([$device['device_id'],$device['user_id'],$device['token']]);if(!$current->fetchColumn())break;
            // 发送前在账号级预约预算与语义组（同一事务、幂等）：网络重试复用原回执与预约，不重复扣预算。
            $reservation=clubPushReserve($db,$uid,$device['device_id'],$job['client_job_id'],$kind,(string)$item['date']);
            if($reservation['decision']!=='send'){$skip($job,$reservation['decision']==='budget'?'BudgetExceeded':'SemanticDuplicate');continue;}
            try{$result=clubPushSend($config,$device,['kind'=>$kind,'date'=>$item['date'],'client_job_id'=>$job['client_job_id']]);}
            catch(Throwable){$result=['status'=>0,'reason'=>'TransportUnavailable'];}
            $attempt=(int)$job['attempts']+1;$success=$result['status']===200;
            $retry=!$success && $attempt<5 && ($result['status']===0||$result['status']===429||$result['status']>=500||$result['status']===403);
            $db->prepare('INSERT INTO club_push_receipts(device_id,client_job_id,status,attempts,next_attempt,reason,updated_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status=VALUES(status),attempts=VALUES(attempts),next_attempt=VALUES(next_attempt),reason=VALUES(reason),updated_at=UTC_TIMESTAMP()')
                ->execute([$device['device_id'],$job['client_job_id'],$success?'sent':($retry?'pending':'failed'),$attempt,gmdate('Y-m-d H:i:s',time()+min(3600,60*(2**$attempt))),$success?null:$result['reason']]);
            // 退避重试保持 reserved（同一预约继续用）；成功或终态失败才回写预约终态。
            if($success)clubPushReservationFinish($db,$uid,$reservation,'sent');
            elseif(!$retry)clubPushReservationFinish($db,$uid,$reservation,'failed');
            if($result['status']===410||in_array($result['reason'],['BadDeviceToken','DeviceTokenNotForTopic','Unregistered'],true)){$db->prepare('UPDATE club_push_devices SET enabled=0 WHERE device_id=?')->execute([$device['device_id']]);break;}
            if(microtime(true)>$deadline)break;
        }
        // 免打扰延后后任务已从分析服务消失（已删/已取消）：不再挂起，按对象失效跳过。
        if($fetchedAll)foreach($jobs as $job)if(!isset($seen[$job['server_job_id']]))$skip($job,'SourceGone');
    }catch(Throwable){fwrite(STDERR,"Club push check deferred\n");}
}
$db->exec("DELETE FROM club_push_receipts WHERE updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 7 DAY) LIMIT 1000");
$db->exec("DELETE FROM club_push_budget WHERE updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY) LIMIT 2000");
flock($lock,LOCK_UN);
