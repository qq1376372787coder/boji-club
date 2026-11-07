<?php
declare(strict_types=1);
require_once __DIR__.'/club-push.php';
function scheduleQuery(PDO $db,string $sql,array $args=[]):PDOStatement{$q=$db->prepare($sql);$q->execute($args);return $q;}
function scheduleReady(PDO $db):bool{
 return (int)scheduleQuery($db,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('notification_plan_settings','notification_schedule_runs','notification_schedule_deliveries')")->fetchColumn()===3;
}
function scheduleAudience(mixed $raw):array{
 if(!is_array($raw))throw new RuntimeException('请选择接收范围。');
 $mode=(string)($raw['mode']??'selected');if(!in_array($mode,['selected','all','members'],true))throw new RuntimeException('接收范围不正确。');
 $ids=$raw['user_ids']??[];if(!is_array($ids)||count($ids)>1000)throw new RuntimeException('指定成员最多 1000 位。');
 $clean=[];foreach($ids as $id){$n=filter_var($id,FILTER_VALIDATE_INT);if(!$n||$n<1)throw new RuntimeException('成员账号 ID 不正确。');$clean[$n]=$n;}
 return ['mode'=>$mode,'user_ids'=>$mode==='selected'?array_values($clean):[]];
}
function scheduleKind(string $category):string{return match($category){'training'=>'training_reminder','daily_report'=>'report','weekly_review'=>'weekly_review',default=>'scheduled_notice'};}
/** SQL fragment and bindings; only active accounts with a live, opted-in device qualify. */
function scheduleAudienceWhere(array $audience,string $category,int $now):array{
 $a=scheduleAudience($audience);$utc=gmdate('Y-m-d H:i:s',$now);$preference=$category==='weekly_review'?'weekly':'daily';
 $where="u.status='active' AND NOT EXISTS(SELECT 1 FROM club_push_account_blocks b WHERE b.user_id=u.id) AND EXISTS(SELECT 1 FROM club_push_devices d JOIN sessions ss ON ss.user_id=d.user_id AND BINARY ss.token_hash=BINARY d.session_hash WHERE d.user_id=u.id AND d.enabled=1 AND ss.expires_at>? AND JSON_UNQUOTE(JSON_EXTRACT(IF(JSON_VALID(d.preferences_json),d.preferences_json,'{}'),'$.".$preference."'))='true')";$args=[$utc];
 if($a['mode']==='members'){$where.=" AND EXISTS(SELECT 1 FROM membership_entitlements e WHERE e.user_id=u.id AND e.status='active' AND e.expires_at>?)";$args[]=$utc;}
 if($a['mode']==='selected'){
  if(!$a['user_ids'])$where.=' AND 1=0';
  else{$where.=' AND u.id IN ('.implode(',',array_fill(0,count($a['user_ids']),'?')).')';$args=array_merge($args,$a['user_ids']);}
 }
 return [$where,$args];
}
function scheduleRecipientCount(PDO $db,array $audience,string $category,?int $now=null):int{
 [$where,$args]=scheduleAudienceWhere($audience,$category,$now??time());return (int)scheduleQuery($db,'SELECT COUNT(*) FROM users u WHERE '.$where,$args)->fetchColumn();
}
function schedulePlanInput(array $input):array{
 $name=trim((string)($input['name']??''));if($name===''||mb_strlen($name)>80)throw new RuntimeException('请填写 80 字以内的计划名称。');
 $template=filter_var($input['template_id']??null,FILTER_VALIDATE_INT);$hour=filter_var($input['hour']??null,FILTER_VALIDATE_INT);$minute=filter_var($input['minute']??null,FILTER_VALIDATE_INT);
 if(!$template||$hour===false||$hour<0||$hour>23||$minute===false||$minute<0||$minute>59)throw new RuntimeException('请选择模板和正确的发送时间。');
 $weekdays=$input['weekdays']??'';if(is_array($weekdays))$weekdays=implode(',',$weekdays);
 if(!is_string($weekdays)||!preg_match('/^[1-7](,[1-7])*$/D',$weekdays))throw new RuntimeException('请至少选择一个发送星期。');
 $weekdays=implode(',',array_unique(explode(',',$weekdays)));
 $zone=(string)($input['timezone']??'Asia/Shanghai');if(!in_array($zone,DateTimeZone::listIdentifiers(DateTimeZone::ALL_WITH_BC),true)&&$zone!=='UTC')throw new RuntimeException('请选择有效的地区时区。');
 if(($input['trigger_type']??'weekday')!=='weekday'||(int)($input['threshold']??0)!==0)throw new RuntimeException('自动发送目前使用按星期定时；请先把旧条件计划改为按星期发送。');
 return ['name'=>$name,'template_id'=>$template,'hour'=>$hour,'minute'=>$minute,'weekdays'=>$weekdays,'timezone'=>$zone,'audience'=>scheduleAudience($input['audience']??['mode'=>'selected','user_ids'=>[]])];
}
/** A plan sends at most once per local calendar date, including DST/revision changes. */
function scheduleOccurrence(array $plan,int $now):?array{
 if(($plan['state']??'draft')!=='enabled'||($plan['trigger_type']??'weekday')!=='weekday'||(int)($plan['threshold']??0)!==0)return null;
 try{$zone=new DateTimeZone($plan['timezone']);$local=(new DateTimeImmutable('@'.$now))->setTimezone($zone);}catch(Throwable){return null;}
 if(!in_array($local->format('N'),explode(',',$plan['weekdays']),true))return null;
 $scheduled=new DateTimeImmutable($local->format('Y-m-d').sprintf(' %02d:%02d:00',(int)$plan['hour'],(int)$plan['minute']),$zone);
 // Do not normalize an impossible spring-forward wall-clock time into another hour.
 if($scheduled->format('H:i')!==sprintf('%02d:%02d',(int)$plan['hour'],(int)$plan['minute']))return null;
 $at=$scheduled->getTimestamp();$enabled=strtotime((string)($plan['enabled_at']??'').' UTC');
 if(!$enabled||$at<$enabled||$now<$at||$now-$at>900)return null;
 return ['date'=>$local->format('Y-m-d'),'utc'=>gmdate('Y-m-d H:i:s',$at),'expires'=>gmdate('Y-m-d H:i:s',$at+43200)];
}
function scheduleSeed(PDO $db,int $now,int $maxRecipients=10000):array{
 $seeded=0;$recipients=0;$planErrors=[];$utc=gmdate('Y-m-d H:i:s',$now);
 $plans=scheduleQuery($db,"SELECT p.*,s.state,s.revision,s.audience_json,s.enabled_at FROM notification_plans p JOIN notification_plan_settings s ON s.plan_id=p.id WHERE s.state='enabled' AND p.active=1")->fetchAll();
 foreach($plans as $candidate){
  if(!scheduleOccurrence($candidate,$now))continue;
  $db->beginTransaction();try{
   $p=scheduleQuery($db,"SELECT p.*,s.state,s.revision,s.audience_json,s.enabled_at FROM notification_plans p JOIN notification_plan_settings s ON s.plan_id=p.id WHERE p.id=? FOR UPDATE",[$candidate['id']])->fetch();
   $due=$p?scheduleOccurrence($p,$now):null;if(!$due){$db->rollBack();continue;}
   $template=scheduleQuery($db,'SELECT * FROM notification_templates WHERE id=? AND active=1 AND enabled=1',[$p['template_id']])->fetch();
   if(!$template){$db->rollBack();continue;}
   if(scheduleQuery($db,'SELECT id FROM notification_schedule_runs WHERE plan_id=? AND occurrence_date=?',[$p['id'],$due['date']])->fetchColumn()){$db->rollBack();continue;}
   $audience=scheduleAudience(json_decode($p['audience_json'],true));[$where,$args]=scheduleAudienceWhere($audience,$template['category'],$now);
   $count=(int)scheduleQuery($db,'SELECT COUNT(*) FROM users u WHERE '.$where,$args)->fetchColumn();
   if($count>$maxRecipients)throw new RuntimeException('通知接收人数超过本次处理上限，请缩小范围。');
   $payload=['template_id'=>(int)$template['id'],'category'=>$template['category'],'title'=>$template['title'],'body'=>$template['body'],'sound'=>(bool)$template['sound'],'badge'=>(bool)$template['badge']];
   scheduleQuery($db,'INSERT INTO notification_schedule_runs(plan_id,plan_revision,occurrence_date,scheduled_for,expires_at,payload_json,recipient_count,created_at) VALUES(?,?,?,?,?,?,?,?)',[$p['id'],$p['revision'],$due['date'],$due['utc'],$due['expires'],json_encode($payload,JSON_THROW_ON_ERROR),$count,$utc]);$run=(int)$db->lastInsertId();
   scheduleQuery($db,"INSERT INTO notification_schedule_deliveries(run_id,user_id,status,next_attempt,created_at,updated_at) SELECT ?,u.id,'pending',?,?,? FROM users u WHERE ".$where,[$run,$utc,$utc,$utc,...$args]);
   $db->commit();$seeded++;$recipients+=$count;
  }catch(Throwable $error){if($db->inTransaction())$db->rollBack();if($error instanceof PDOException)throw $error;$planErrors[]=['plan_id'=>(int)$candidate['id'],'error'=>'PlanInvalid'];}
 }
 return ['runs'=>$seeded,'recipients'=>$recipients,'plan_errors'=>$planErrors];
}
function scheduleFinish(PDO $db,array $job,string $status,string $reason,int $now,?int $next=null):void{
 $db->beginTransaction();try{
  $changed=scheduleQuery($db,'UPDATE notification_schedule_deliveries SET status=?,reason=?,next_attempt=?,lease_token=NULL,lease_until=NULL,updated_at=? WHERE id=? AND status=\'sending\' AND lease_token=?',[$status,$reason,gmdate('Y-m-d H:i:s',$next??$now),gmdate('Y-m-d H:i:s',$now),$job['id'],$job['lease_token']])->rowCount();
  if($changed&&$job['receipt_id'])scheduleQuery($db,"UPDATE notification_deliveries SET status=?,error=?,sent_at=? WHERE id=?",[$status==='sent'?'sent':($status==='pending'?'queued':($status==='skipped'?'muted':'failed')),$reason,$status==='sent'?gmdate('Y-m-d H:i:s',$now):null,$job['receipt_id']]);
  $db->commit();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
function scheduleClaim(PDO $db,int $now):?array{
 $utc=gmdate('Y-m-d H:i:s',$now);$db->beginTransaction();try{
  // An expired in-flight request may already have reached Apple. Never blindly send it again.
  scheduleQuery($db,"UPDATE notification_schedule_deliveries SET status='uncertain',reason='SendOutcomeUnknown',lease_token=NULL,lease_until=NULL,updated_at=? WHERE status='sending' AND lease_until<?",[$utc,$utc]);
  scheduleQuery($db,"UPDATE notification_deliveries n JOIN notification_schedule_deliveries d ON d.receipt_id=n.id SET n.status='failed',n.error='SendOutcomeUnknown' WHERE d.status='uncertain' AND n.status='queued' AND n.provider='schedule'");
  $job=scheduleQuery($db,"SELECT d.*,r.plan_id,r.plan_revision,r.occurrence_date,r.expires_at,r.payload_json FROM notification_schedule_deliveries d JOIN notification_schedule_runs r ON r.id=d.run_id WHERE d.status='pending' AND d.next_attempt<=? ORDER BY d.id LIMIT 1 FOR UPDATE",[$utc])->fetch();
  if(!$job){$db->commit();return null;}
  $job['lease_token']=bin2hex(random_bytes(32));
  scheduleQuery($db,"UPDATE notification_schedule_deliveries SET status='sending',lease_token=?,lease_until=?,updated_at=? WHERE id=?",[$job['lease_token'],gmdate('Y-m-d H:i:s',$now+120),$utc,$job['id']]);
  $payload=json_decode($job['payload_json'],true);
  if(!$job['receipt_id']){
   scheduleQuery($db,"INSERT INTO notification_deliveries(template_id,user_id,category,title,body,status,provider,created_at) VALUES(?,?,?,?,?,'queued','schedule',?)",[$payload['template_id'],$job['user_id'],$payload['category'],$payload['title'],$payload['body'],$utc]);$job['receipt_id']=(int)$db->lastInsertId();
   scheduleQuery($db,'UPDATE notification_schedule_deliveries SET receipt_id=? WHERE id=?',[$job['receipt_id'],$job['id']]);
  }
  $db->commit();return $job;
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
function scheduleDispatch(PDO $db,array $config,int $now,?callable $transport=null,int $limit=30):array{
 if(!clubPushConfigured($config))throw new RuntimeException('苹果推送未配置，通知队列已保留。');
 $clockStart=microtime(true);$baseNow=$now;
 $counts=['sent'=>0,'pending'=>0,'skipped'=>0,'failed'=>0,'uncertain'=>0];
 for($i=0;$i<$limit;$i++){
  if(microtime(true)-$clockStart>45)break;$now=$baseNow+(int)(microtime(true)-$clockStart);
  $job=scheduleClaim($db,$now);if(!$job)break;$payload=json_decode($job['payload_json'],true);$uid=(int)$job['user_id'];
  $current=scheduleQuery($db,'SELECT p.active,s.state,s.revision,s.audience_json,t.active template_active,t.enabled template_enabled FROM notification_plans p JOIN notification_plan_settings s ON s.plan_id=p.id JOIN notification_templates t ON t.id=p.template_id WHERE p.id=?',[$job['plan_id']])->fetch();
  if(!$current||$current['state']!=='enabled'||!(int)$current['active']||(int)$current['revision']!==(int)$job['plan_revision']||!(int)$current['template_active']||!(int)$current['template_enabled']){scheduleFinish($db,$job,'skipped','PlanChangedOrPaused',$now);$counts['skipped']++;continue;}
  [$scope,$scopeArgs]=scheduleAudienceWhere(scheduleAudience(json_decode($current['audience_json'],true)),$payload['category'],$now);
  if(!scheduleQuery($db,'SELECT u.id FROM users u WHERE '.$scope.' AND u.id=?',[...$scopeArgs,$uid])->fetchColumn()){scheduleFinish($db,$job,'skipped','DeviceOrPermissionUnavailable',$now);$counts['skipped']++;continue;}
  if($job['expires_at']<=gmdate('Y-m-d H:i:s',$now)){scheduleFinish($db,$job,'skipped','NotificationExpired',$now);$counts['skipped']++;continue;}
  $category=$payload['category'];$preference=$category==='weekly_review'?'weekly':'daily';
  $device=scheduleQuery($db,"SELECT d.* FROM club_push_devices d JOIN users u ON u.id=d.user_id AND u.status='active' JOIN sessions s ON s.user_id=d.user_id AND BINARY s.token_hash=BINARY d.session_hash WHERE d.user_id=? AND d.enabled=1 AND s.expires_at>? AND JSON_UNQUOTE(JSON_EXTRACT(IF(JSON_VALID(d.preferences_json),d.preferences_json,'{}'),'$.".$preference."'))='true' ORDER BY d.updated_at DESC,d.device_id LIMIT 1",[$uid,gmdate('Y-m-d H:i:s',$now)])->fetch();
  if(!$device||clubPushAccountBlocked($db,$uid)){scheduleFinish($db,$job,'skipped','DeviceOrPermissionUnavailable',$now);$counts['skipped']++;continue;}
  $kind=scheduleKind($category);try{$allowed=clubPushAllowed(json_decode($device['preferences_json'],true),$kind,$now);}catch(Throwable){$allowed=null;}
  if($allowed===null){scheduleFinish($db,$job,'skipped','NotificationsDisabled',$now);$counts['skipped']++;continue;}
  if($allowed>$now){scheduleFinish($db,$job,'pending','QuietHours',$now,$allowed);$counts['pending']++;continue;}
  $client=substr(hash('sha256','scheduled/'.$job['run_id']),0,32);$client=substr($client,0,8).'-'.substr($client,8,4).'-'.substr($client,12,4).'-'.substr($client,16,4).'-'.substr($client,20,12);
  $reservation=clubPushReserve($db,$uid,$device['device_id'],$client,$kind,$job['occurrence_date']);
  if($reservation['decision']!=='send'){scheduleFinish($db,$job,'skipped',$reservation['decision']==='budget'?'DailyLimitReached':'AlreadySent',$now);$counts['skipped']++;continue;}
  $stillAllowed=scheduleQuery($db,"SELECT 1 FROM club_push_devices d JOIN users u ON u.id=d.user_id AND u.status='active' JOIN sessions ss ON ss.user_id=d.user_id AND BINARY ss.token_hash=BINARY d.session_hash WHERE d.device_id=? AND d.user_id=? AND d.token=? AND d.enabled=1 AND ss.expires_at>?",[$device['device_id'],$uid,$device['token'],gmdate('Y-m-d H:i:s',$now)])->fetchColumn();
  if(!$stillAllowed||clubPushAccountBlocked($db,$uid)){clubPushReservationFinish($db,$uid,$reservation,'failed');scheduleFinish($db,$job,'skipped','DeviceOrPermissionUnavailable',$now);$counts['skipped']++;continue;}
  $route=match($category){'training'=>'training','daily_report'=>'report','weekly_review'=>'weekly_center',default=>'club'};
  $userDate=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone((json_decode($device['preferences_json'],true))['zone']))->format('Y-m-d');
  $aps=['alert'=>['title'=>$payload['title'],'body'=>$payload['body']],'thread-id'=>'club-reminders'];if($payload['sound'])$aps['sound']='default';if($payload['badge'])$aps['badge']=1;
  scheduleQuery($db,'UPDATE notification_schedule_deliveries SET attempts=attempts+1,device_id=? WHERE id=? AND lease_token=?',[$device['device_id'],$job['id'],$job['lease_token']]);
  try{$result=clubPushSendContent($config,$device,['aps'=>$aps,'boji_kind'=>$route,'boji_date'=>$userDate,'boji_account'=>$uid],hash('sha256','schedule/'.$job['id']),$transport);}catch(Throwable){$result=['status'=>0,'reason'=>'TransportUnavailable'];}
  $status=(int)($result['status']??0);$attempts=(int)$job['attempts']+1;
  if($status===200){$state='sent';$reason='AcceptedByApple';clubPushReservationFinish($db,$uid,$reservation,'sent');}
  elseif($status===0){$state='uncertain';$reason='SendOutcomeUnknown';}
  elseif(($status===429||$status>=500)&&$attempts<5){$state='pending';$reason='Retrying';}
  else{$state='failed';$reason=(string)($result['reason']??'PushRejected');clubPushReservationFinish($db,$uid,$reservation,'failed');}
  scheduleFinish($db,$job,$state,substr($reason,0,100),$now,$state==='pending'?$now+min(3600,30*(2**$attempts)):null);$counts[$state]++;
 }
 return $counts;
}
