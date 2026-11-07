<?php
declare(strict_types=1);
require_once __DIR__.'/cloud-parts.php';require_once __DIR__.'/ai-proposals.php';require_once __DIR__.'/insights.php';require_once __DIR__.'/ai-memory.php';require_once __DIR__.'/action-support.php';
function outboxConsumersFor(string $type): array {
 $all=['personal-memory-v1'];
 if(str_starts_with($type,'Workout')||str_starts_with($type,'TrainingPlan')||str_starts_with($type,'Schedule')||str_starts_with($type,'Meal')||str_starts_with($type,'Body')||$type==='ActionUndone.v1')$all=array_merge($all,['club-progress-v1','home-insight-v1']);
 if(in_array($type,['WorkoutSessionFinished.v1','MealCreated','BodyWeightRecorded'],true))$all[]='notifications-v1';
 return $all;
}
function outboxRecordProjection(PDO $db,int $uid,string $consumer,string $id,int $version=0): void {
 $db->prepare('INSERT INTO domain_projection_state(user_id,consumer,last_event_id,last_event_at,processed_events,aggregate_version,updated_at) VALUES(?,?,?,UTC_TIMESTAMP(),1,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE last_event_id=IF(VALUES(aggregate_version)>=aggregate_version,VALUES(last_event_id),last_event_id),last_event_at=IF(VALUES(aggregate_version)>=aggregate_version,VALUES(last_event_at),last_event_at),aggregate_version=GREATEST(aggregate_version,VALUES(aggregate_version)),processed_events=processed_events+1,updated_at=UTC_TIMESTAMP()')->execute([$uid,$consumer,$id,$version]);
}
function outboxApplyNotification(PDO $db,int $uid,string $type,array $event=[]): void {
 $q=$db->prepare("SELECT d.device_id FROM club_push_devices d JOIN sessions s ON s.token_hash=d.session_hash AND s.user_id=d.user_id WHERE d.user_id=? AND d.enabled=1 AND s.expires_at>UTC_TIMESTAMP()");$q->execute([$uid]);
 $payload=json_decode((string)($event['payload']??'{}'),true);$date=$payload['date']??($payload['aggregateId']??insightHomeToday());if(!aiProposalDateValid($date))$date=insightHomeToday();
 [$kind,$title,$body]=match($type){'MealCreated'=>['domain_meal','饮食记录已保存','这一餐已保存，可在记录页查看。'],'BodyWeightRecorded'=>['domain_body','测量已保存','本次测量已保存，历史测量仍保留。'],default=>['domain_training','训练已保存','本场实际训练已保存，打开查看记录。']};
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $d)$db->prepare("INSERT IGNORE INTO domain_notification_jobs(event_id,user_id,device_id,kind,date_key,title,body,status,next_attempt,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'pending',UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$event['event_id'],$uid,$d['device_id'],$kind,$date,$title,$body]);
}
function outboxDispatch(PDO $db,array $event): int {
 $id=(string)($event['event_id']??'');$type=(string)($event['event_type']??'');$uid=(int)($event['user_id']??0);if(!$id||$uid<=0)return 0;$count=0;
 foreach(outboxConsumersFor($type) as $consumer){
  $db->beginTransaction();
  try{
   $q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn()){$db->commit();continue;}
   $q=$db->prepare('INSERT IGNORE INTO domain_consumer_inbox(consumer,event_id,user_id,processed_at) VALUES(?,?,?,UTC_TIMESTAMP())');$q->execute([$consumer,$id,$uid]);
   if($q->rowCount()){
    if($consumer==='personal-memory-v1'){$today=insightHomeToday();$start=(new DateTimeImmutable($today))->modify('-27 days')->format('Y-m-d');aiMemorySweepExtract($db,$uid,cloudStoredState($db,$uid,$start,$today,false));}
    if($consumer==='notifications-v1')outboxApplyNotification($db,$uid,$type,$event);
    // Read-through projections always use the current authoritative state. Their revision fences cache reuse and out-of-order events.
    $revision=$db->prepare('SELECT revision FROM app_states WHERE user_id=?');$revision->execute([$uid]);$current=(int)$revision->fetchColumn();
    outboxRecordProjection($db,$uid,$consumer,$id,max($current,(int)($event['aggregate_version']??0)));$count++;
   }
   $db->commit();
  }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
 }
 return $count;
}
/** Missing receipts are computed only for consumers actually subscribed to each event. */
function domainProjectionGaps(PDO $db,array $consumers,?int $uid=null,int $limit=1000): array {
 $sql="SELECT o.event_id,o.event_type FROM domain_outbox o WHERE o.status='published'".($uid===null?'':' AND o.user_id=?')." ORDER BY o.created_at,o.event_id";
 $q=$db->prepare($sql);$q->execute($uid===null?[]:[$uid]);$missing=[];$receipt=$db->prepare('SELECT 1 FROM domain_consumer_inbox WHERE consumer=? AND event_id=?');
 while($event=$q->fetch(PDO::FETCH_ASSOC)){
  foreach(array_intersect($consumers,outboxConsumersFor($event['event_type'])) as $consumer){$receipt->execute([$consumer,$event['event_id']]);if(!$receipt->fetchColumn())$missing[$consumer][]=$event['event_id'];}
  if(array_sum(array_map('count',$missing)) >= $limit)break;
 }
 return $missing;
}
function domainReconcile(PDO $db,array $consumers,int $limit=200): array {
 $gaps=domainProjectionGaps($db,$consumers,null,$limit);$ids=[];foreach($gaps as $rows)$ids=array_merge($ids,$rows);$ids=array_values(array_unique($ids));$changed=0;
 foreach($ids as $id){$q=$db->prepare("UPDATE domain_outbox SET status='pending',attempts=0,next_attempt=UTC_TIMESTAMP(),lease_token=NULL,updated_at=UTC_TIMESTAMP() WHERE event_id=? AND status='published'");$q->execute([$id]);$changed+=$q->rowCount();}
 return ['missing'=>array_sum(array_map('count',$gaps)),'requeued'=>$changed];
}
