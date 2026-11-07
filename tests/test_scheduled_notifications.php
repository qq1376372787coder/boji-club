<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/scheduled-notifications.php';
require __DIR__.'/../account-server/admin/workspace.php';
require __DIR__.'/../account-server/admin/scheduled-notifications.php';
$base=getenv('BOJI_TEST_DSN_BASE');if(!$base)throw new RuntimeException('dedicated test instance required');
$root=new PDO($base,getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'');$root->exec('DROP DATABASE IF EXISTS boji_scheduled_notifications_test');$root->exec('CREATE DATABASE boji_scheduled_notifications_test');
$db=bojiTestDatabase('boji_scheduled_notifications_test');bojiTestSchema($db,__DIR__.'/../account-server');
$checks=0;function scheduledCheck(bool $ok,string $text):void{global $checks;$checks++;if(!$ok)throw new RuntimeException($text);}
$now=time();$local=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone('Asia/Shanghai'));$utc=gmdate('Y-m-d H:i:s',$now);
$db->prepare("INSERT INTO admin_accounts(username,password_hash,role,status,created_at) VALUES('schedule-admin',?,'super_admin','active',UTC_TIMESTAMP())")->execute([password_hash('SyntheticAdmin!2026',PASSWORD_DEFAULT)]);$admin=(int)$db->lastInsertId();
$preferences=['enabled'=>true,'daily'=>true,'weekly'=>true,'quiet'=>false,'quiet_start'=>22,'quiet_end'=>8,'zone'=>'Asia/Shanghai'];
for($u=1;$u<=4;$u++){
 $db->prepare("INSERT INTO users(id,status,created_at,updated_at) VALUES(?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$u]);
 $token=str_pad((string)$u,64,'a');$device=sprintf('00000000-0000-4000-a000-%012d',$u);
 $db->prepare('INSERT INTO sessions(token_hash,user_id,expires_at,created_at,last_used_at) VALUES(?,?,?,?,?)')->execute([$token,$u,gmdate('Y-m-d H:i:s',$now+86400),$utc,$utc]);
 $db->prepare('INSERT INTO club_push_devices(device_id,user_id,session_hash,token,environment,enabled,preferences_json,notify_after,next_check,updated_at) VALUES(?,?,?,?,?,1,?,?,?,?)')->execute([$device,$u,$token,str_pad(dechex($u),64,'0',STR_PAD_LEFT),'development',json_encode($preferences),$utc,$utc,$utc]);
}
$db->prepare("INSERT INTO notification_templates(category,name,title,body,enabled,sound,badge,created_at,updated_at) VALUES('training','schedule-template','该训练了','准备开始今天的训练。',1,1,1,?,?)")->execute([$utc,$utc]);$template=(int)$db->lastInsertId();
$folder=sys_get_temp_dir().'/boji-schedule-'.bin2hex(random_bytes(6));mkdir($folder,0700);
if(is_file('/System/Library/OpenSSL/openssl.cnf'))putenv('OPENSSL_CONF=/System/Library/OpenSSL/openssl.cnf');
$key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);if(!$key)throw new RuntimeException('test signing key unavailable');openssl_pkey_export($key,$pem);file_put_contents($folder.'/apns.p8',$pem);chmod($folder.'/apns.p8',0600);
$config=['apns_enabled'=>true,'apns_key_id'=>'KEY1234567','apns_team_id'=>'TEAMID1234','apns_key_path'=>$folder.'/apns.p8','apns_topic'=>'com.bojiclub.app.dev','apns_cache_directory'=>$folder.'/cache'];
function createSchedule(array $ids=[1,2],string $mode='selected'):int{
 global $db,$admin,$template,$local,$now,$config;
 $p=scheduleAdminSave($db,['name'=>'合成定时计划','template_id'=>$template,'weekdays'=>'1,2,3,4,5,6,7','send_time'=>$local->format('H:i'),'timezone'=>'Asia/Shanghai','audience_mode'=>$mode,'user_refs'=>implode(',',$ids)],$admin,false);
 $count=scheduleRecipientCount($db,['mode'=>$mode,'user_ids'=>$ids],'training',$now);
 scheduleAdminSetState($db,['id'=>$p,'expected_revision'=>1,'current_password'=>'SyntheticAdmin!2026','confirmed_count'=>$count],$config,$admin,true);
 $db->prepare('UPDATE notification_plan_settings SET enabled_at=? WHERE plan_id=?')->execute([gmdate('Y-m-d H:i:s',$now-3600),$p]);return $p;
}
try{
 scheduledCheck(scheduleReady($db),'migration created real tables');
 // Native time inputs use zero-padded hours/minutes.
 $early=scheduleAdminSave($db,['name'=>'上午提醒','template_id'=>$template,'weekdays'=>['1','3'],'send_time'=>'09:05','timezone'=>'Asia/Shanghai'],$admin,false);
 scheduledCheck((int)$db->query('SELECT hour FROM notification_plans WHERE id='.$early)->fetchColumn()===9,'zero-padded native time saves');
 $p=createSchedule();$first=scheduleSeed($db,$now);$second=scheduleSeed($db,$now);
 scheduledCheck($first['runs']===1&&$first['recipients']===2,'due plan creates exact recipients');scheduledCheck($second['runs']===0,'same occurrence is idempotent');
 $calls=[];$transport=function($url,$headers,$body)use(&$calls){$calls[]=json_decode($body,true);return ['status'=>200,'reason'=>''];};
 $result=scheduleDispatch($db,$config,$now,$transport);scheduledCheck($result['sent']===2&&count($calls)===2,'real queue dispatch invokes transport once per user');
 scheduleDispatch($db,$config,$now+5,$transport);scheduledCheck(count($calls)===2,'completed queue never repeats');
 scheduledCheck((int)$db->query("SELECT COUNT(*) FROM notification_deliveries WHERE provider='schedule' AND status='sent'")->fetchColumn()===2,'existing receipts really persist');
 scheduledCheck($calls[0]['aps']['badge']===1&&$calls[0]['aps']['sound']==='default','sound and badge flags consumed');
 // Pause after seeding must cancel unsent work.
 $paused=createSchedule([1]);scheduleSeed($db,$now);scheduleAdminSetState($db,['id'=>$paused,'expected_revision'=>2],$config,$admin,false);
 $before=count($calls);$result=scheduleDispatch($db,$config,$now,$transport);scheduledCheck(count($calls)===$before&&$result['skipped']===1,'pause cancels queued work');
 // Unknown network outcome must not become an automatic duplicate.
 createSchedule([1]);scheduleSeed($db,$now);$unknownCalls=0;$unknown=function()use(&$unknownCalls){$unknownCalls++;return ['status'=>0,'reason'=>'NetworkError'];};
 $result=scheduleDispatch($db,$config,$now,$unknown);scheduledCheck($result['uncertain']===1,'ambiguous outcome remains visibly unknown');
 scheduleDispatch($db,$config,$now+180,$unknown);scheduledCheck($unknownCalls===1,'ambiguous send is not blindly repeated');
 // A definitive 429 is retried after backoff, using the same queue item.
 createSchedule([1]);scheduleSeed($db,$now);$retryCalls=0;$retry=function()use(&$retryCalls){$retryCalls++;return ['status'=>$retryCalls===1?429:200,'reason'=>'TooManyRequests'];};
 $result=scheduleDispatch($db,$config,$now,$retry);scheduledCheck($result['pending']===1,'definitive retryable rejection retained');
 scheduleDispatch($db,$config,$now+30,$retry);scheduledCheck($retryCalls===1,'backoff observed');scheduleDispatch($db,$config,$now+61,$retry);scheduledCheck($retryCalls===2,'retry resumes after backoff');
 // Preferences and live sessions are checked again at send time.
 createSchedule([1]);scheduleSeed($db,$now);$prefs=$preferences;$prefs['daily']=false;$db->prepare('UPDATE club_push_devices SET preferences_json=? WHERE user_id=1')->execute([json_encode($prefs)]);$before=count($calls);
 $result=scheduleDispatch($db,$config,$now,$transport);scheduledCheck(count($calls)===$before&&$result['skipped']===1,'opt-out after queue is respected');
 $db->prepare('UPDATE club_push_devices SET preferences_json=? WHERE user_id=1')->execute([json_encode($preferences)]);
 // Quiet time defers without spending an attempt.
 createSchedule([1]);scheduleSeed($db,$now);$quiet=$preferences;$quiet['quiet']=true;$quiet['quiet_start']=(int)$local->format('G');$quiet['quiet_end']=($quiet['quiet_start']+1)%24;
 $db->prepare('UPDATE club_push_devices SET preferences_json=? WHERE user_id=1')->execute([json_encode($quiet)]);$result=scheduleDispatch($db,$config,$now,$transport);scheduledCheck($result['pending']===1,'quiet hours defer');
 scheduledCheck((int)$db->query("SELECT attempts FROM notification_schedule_deliveries WHERE reason='QuietHours' ORDER BY id DESC LIMIT 1")->fetchColumn()===0,'quiet deferral does not consume a send attempt');
 $db->prepare('UPDATE club_push_devices SET preferences_json=? WHERE user_id=1')->execute([json_encode($preferences)]);
 // Stale windows cannot activate changed audience/content.
 $rejected=false;try{scheduleAdminSetState($db,['id'=>$p,'expected_revision'=>1,'current_password'=>'SyntheticAdmin!2026','confirmed_count'=>2],$config,$admin,true);}catch(RuntimeException){$rejected=true;}scheduledCheck($rejected,'stale publishing rejected');
 // Invalid legacy event plans do not pretend to schedule.
 $invalid=false;try{schedulePlanInput(['name'=>'旧计划','template_id'=>1,'hour'=>19,'minute'=>0,'weekdays'=>'1','trigger_type'=>'event']);}catch(RuntimeException){$invalid=true;}scheduledCheck($invalid,'unsupported legacy trigger explicitly rejected');
 // Spring-forward wall-clock gaps cannot silently send at a different hour.
 $spring=['state'=>'enabled','trigger_type'=>'weekday','threshold'=>0,'weekdays'=>'7','timezone'=>'America/New_York','hour'=>2,'minute'=>30,'enabled_at'=>'2026-03-01 00:00:00'];
 scheduledCheck(scheduleOccurrence($spring,strtotime('2026-03-08 07:35:00 UTC'))===null,'DST missing wall time does not normalize into another hour');
 echo 'PASS scheduled notifications '.$checks." assertions; no real APNs requests\n";
}finally{
 foreach(glob($folder.'/cache/*')?:[] as $file)unlink($file);if(is_dir($folder.'/cache'))rmdir($folder.'/cache');unlink($folder.'/apns.p8');rmdir($folder);
}
