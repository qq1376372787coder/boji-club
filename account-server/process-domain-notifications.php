<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require_once __DIR__.'/public/club-push.php';
$config=require __DIR__.'/config.php';if(!clubPushConfigured($config))exit(0);
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$lock=fopen(sys_get_temp_dir().'/boji-domain-notify-'.hash('sha256',$config['dsn']).'.lock','c');if(!$lock||!flock($lock,LOCK_EX|LOCK_NB))exit(0);
$q=$db->query("SELECT j.*,d.token,d.environment,d.preferences_json,d.session_hash,d.notify_after FROM domain_notification_jobs j JOIN club_push_devices d ON BINARY d.device_id=BINARY j.device_id AND d.user_id=j.user_id JOIN users u ON u.id=j.user_id AND u.status='active' JOIN sessions s ON BINARY s.token_hash=BINARY d.session_hash AND s.user_id=j.user_id AND s.expires_at>UTC_TIMESTAMP() WHERE j.status='pending' AND d.enabled=1 AND j.next_attempt<=UTC_TIMESTAMP() ORDER BY j.created_at LIMIT 30");
foreach($q->fetchAll(PDO::FETCH_ASSOC) as $job){
 $uid=(int)$job['user_id'];$status='skipped';$attempt=(int)$job['attempts']+1;$next=time()+60;
 if(!clubPushAccountBlocked($db,$uid)&&$job['created_at']>=$job['notify_after']){
  $allowed=clubPushAllowed(json_decode($job['preferences_json'],true),$job['kind']);
  if($allowed!==null){
   if($allowed>time()){$status='pending';$next=$allowed;}
   else{
    $reservation=clubPushReserve($db,$uid,$job['device_id'],$job['event_id'],$job['kind'],$job['date_key']);
    if($reservation['decision']==='send'){
     $route=match($job['kind']){'domain_meal'=>'meal','domain_body'=>'body',default=>'training'};
     try{$r=clubPushSendContent($config,$job,['aps'=>['alert'=>['title'=>$job['title'],'body'=>$job['body']],'sound'=>'default','thread-id'=>'club-action'],'boji_kind'=>$route,'boji_date'=>$job['date_key'],'boji_account'=>$uid],hash('sha256','domain/'.$job['device_id'].'/'.$job['event_id']));}catch(Throwable $e){$r=['status'=>0];}
     $status=$r['status']===200?'sent':(($attempt<5&&($r['status']===0||$r['status']===429||$r['status']>=500))?'pending':'failed');
     if($status!=='pending')clubPushReservationFinish($db,$uid,$reservation,$status==='sent'?'sent':'failed');
     $next=time()+min(3600,30*(2**$attempt));
    }
   }
  }
 }
 $db->prepare('UPDATE domain_notification_jobs SET status=?,attempts=?,next_attempt=?,updated_at=UTC_TIMESTAMP() WHERE event_id=? AND device_id=?')->execute([$status,$attempt,gmdate('Y-m-d H:i:s',$next),$job['event_id'],$job['device_id']]);
}
flock($lock,LOCK_UN);
