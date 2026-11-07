<?php
declare(strict_types=1);
require_once __DIR__.'/action-support.php';
/** Shared domain boundary for commands and the legacy partition upload adapter. */
function actionValidateTrainingFacts(array $before,array $after): void {
 foreach($before['workoutSessions']??[] as $session){
  if(empty($session['savedAt']))continue;$id=strtolower($session['id']);
  $matches=array_values(array_filter($after['workoutSessions']??[],fn($v)=>strtolower($v['id'])===$id));
  if(count($matches)!==1||($matches[0]['savedAt']??null)!=$session['savedAt'])fail('已保存的训练会话不能被覆盖或删除。',409);
 }
}
function actionGuardActiveOverrides(PDO $db,int $uid,array $overrides): void {
 $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);$stored=json_decode((string)$q->fetchColumn(),true)??[];$active=[];
 if(($stored['_partitioned']??null)===2){
  $q=$db->prepare("SELECT date_key,payload_json FROM cloud_parts WHERE user_id=? AND part_key LIKE 'd/%' AND JSON_EXTRACT(payload_json,'$.workoutStartedAt') IS NOT NULL AND (JSON_EXTRACT(payload_json,'$.workoutSavedAt') IS NULL OR JSON_TYPE(JSON_EXTRACT(payload_json,'$.workoutSavedAt'))='NULL')");$q->execute([$uid]);foreach($q->fetchAll(PDO::FETCH_ASSOC) as $r)$active[$r['date_key']]=json_decode($r['payload_json'],true);
 }else $active=$stored['days']??[];
 foreach($overrides as $date=>$after)$active[$date]=$after;
 $issue=trainingGuardFullStateSync($db,$uid,['days'=>$active]);if($issue!==null)fail($issue,409);
}
function actionPreflightUpload(PDO $db,int $uid,string $upload): void {
 $q=$db->prepare("SELECT part_key,JSON_EXTRACT(payload_json,'$.workoutStartedAt') AS started,JSON_EXTRACT(payload_json,'$.workoutSavedAt') AS saved,JSON_EXTRACT(payload_json,'$.activeWorkoutSessionID') AS session_id FROM cloud_upload_parts WHERE upload_id=? AND part_key LIKE 'd/%'");$q->execute([$upload]);$overrides=[];
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $r)$overrides[substr($r['part_key'],2)]=['workoutStartedAt'=>json_decode($r['started']??'null',true),'workoutSavedAt'=>json_decode($r['saved']??'null',true),'activeWorkoutSessionID'=>json_decode($r['session_id']??'null',true)];
 actionGuardActiveOverrides($db,$uid,$overrides);
}
function actionGuardDayUpload(PDO $db,int $uid,string $date,array $before,array &$after,string $upload): void {
 actionValidateTrainingFacts($before,$after);
 if(!($GLOBALS['boji_active_preflight']??false))actionGuardActiveOverrides($db,$uid,[$date=>$after]);
 foreach(['_schedule_version','_body_version','_meal_version'] as $key)$after[$key]=$before[$key]??1;
 if(businessTrainingSnapshot($before)!=businessTrainingSnapshot($after))$after['_schedule_version']++;
 if(($before['bodyMeasurements']??[])!=($after['bodyMeasurements']??[]))$after['_body_version']++;
 if(($before['meals']??[])!=($after['meals']??[]))$after['_meal_version']++;
 if($before==$after)return;
 $operation=actionUUID('sync/'.$uid.'/'.$upload.'/'.$date);$existing=$db->prepare('SELECT 1 FROM data_operations WHERE user_id=? AND operation_id=?');$existing->execute([$uid,$operation]);if($existing->fetchColumn())return;
 trainingRecordAudit($db,$uid,$operation,'user','Sync.DomainPatch',hash('sha256',json_encode($after)),'day',$date,(string)($before['_schedule_version']??0),(string)($after['_schedule_version']??1),['date'=>$date,'adapter'=>'partition_upload'],null);
 $events=[];
 if(empty($before['workoutStartedAt'])&&!empty($after['workoutStartedAt']))$events[]='WorkoutSessionStarted.v1';
 $oldSaved=array_column(array_filter($before['workoutSessions']??[],fn($s)=>!empty($s['savedAt'])),'id');
 $newSaved=array_column(array_filter($after['workoutSessions']??[],fn($s)=>!empty($s['savedAt'])),'id');
 if(array_diff($newSaved,$oldSaved))$events[]='WorkoutSessionFinished.v1';
 if(($before['exercises']??[])!=($after['exercises']??[]))$events[]='WorkoutOccurrenceChanged.v1';
 if(array_diff(array_column($after['meals']??[],'id'),array_column($before['meals']??[],'id')))$events[]='MealCreated';
 elseif(($before['meals']??[])!=($after['meals']??[]))$events[]='MealEntryUpdated.v1';
 if(($before['bodyMeasurements']??[])!=($after['bodyMeasurements']??[]))$events[]='BodyMeasurementChanged.v1';
 foreach(array_unique($events) as $type)$db->prepare("INSERT IGNORE INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,?,?,'day',?,?,?,?,'pending',0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([actionUUID($operation.'/'.$type),$operation,$uid,$date,$after['_schedule_version']??1,$type,json_encode(['date'=>$date,'commandId'=>$operation])]);
}
