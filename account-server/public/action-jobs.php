<?php
declare(strict_types=1);
/** Transactional, replayable plan job submission. Network I/O never holds an account lock. */
function actionQueuePlan(PDO $db,array $user,array $input,string $id): array {
 $config=$GLOBALS['config']??[];$uid=(int)$user['id'];
 if(function_exists('aiMayPostJob')&&!aiMayPostJob($db,$user,$config,'generate_plan',null))fail('请先开通会员或完成首次计划引导。',403);
 if(empty($config['otp_secret']))fail('AI 服务尚未配置。',503);
 $loaded=aiRouterState($db,$uid,[actionToday($db,$uid)]);$state=$loaded['state'];$profile=$state['profile']??null;
 if(!$profile)return actionClarify('plan.generate_draft','请先在“我的”完善训练目标、器械、经验和可用天数。');
 foreach(['avatarID','avatarImage','identityVersion','nickname'] as $key)unset($profile[$key]);$profile['nickname']='薄肌成员';
 if(isset($input['goal'])&&trim($input['goal'])!=='')$profile['goal']=trim($input['goal']);
 $profile['gender']=$profile['gender']??'';$profile['sessionMinutes']=$profile['sessionMinutes']??45;
 foreach(['equipment','equipmentOther','limitations'] as $key)$profile[$key]=$profile[$key]??'';
 $zone=actionPreferences($db,$uid)['time_zone'];$date=$input['start_date']??actionToday($db,$uid);
 if(!aiProposalDateValid($date)||$date<actionToday($db,$uid))fail('计划开始日期不能在过去。',422);
 $server=aiJobID($user,$id,$config);
 $request=['id'=>$server,'kind'=>'generate_plan','date'=>$date,'_quota_owner'=>aiQuotaOwner($uid,$config),'payload'=>['profile'=>$profile,'timeZone'=>$zone,'plan_days'=>$input['plan_days']??7,'plan_explanation_version'=>1,'_routing_version'=>2,'nutrition_target'=>$state['nutritionTarget']??null]];
 $today=actionToday($db,$uid);$start=(new DateTimeImmutable($today))->modify('-27 days')->format('Y-m-d');
 $recent=aiRouterState($db,$uid,[$start,$today])['state'];$performance=[];
 foreach($recent['days']??[] as $d=>$day){$saved=array_map('strtolower',array_column(array_filter($day['workoutSessions']??[],fn($v)=>!empty($v['savedAt'])),'id'));
  foreach($day['exercises']??[] as $e){if($saved?!in_array(strtolower($e['workoutSessionID']??''),$saved,true):empty($day['workoutSavedAt']))continue;
   foreach($e['sets'] as $set)if(!empty($set['completed']))$performance[]=['date'=>$d,'exercise'=>$e['name'],'weight'=>$set['weight'],'reps'=>$set['reps'],'seconds'=>$set['durationSeconds']??null];
  }
 }
 $request['payload']['action_context']=['memory'=>aiMemoryForContext($db,$uid),'recent_sets'=>array_slice($performance,-60)];
 $db->beginTransaction();
 try{
  lockActiveUser($db,$uid);
  actionAssertParentActive($db,$uid);
  $db->prepare("INSERT IGNORE INTO ai_action_jobs(execution_id,user_id,server_job_id,request_json,status,next_attempt,created_at,updated_at) VALUES(?,?,?,?,'pending',UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$id,$uid,$server,json_encode($request,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR)]);
  $db->prepare('INSERT IGNORE INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES(?,?,?,\'generate_plan\',UTC_TIMESTAMP())')->execute([$uid,$id,$server]);
  $db->commit();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
 return ['capability'=>'plan.generate_draft','status'=>'accepted','execution_id'=>$id,'job_id'=>$id,'data'=>['job_id'=>$id],'note'=>'候选计划已可靠排队，生成后仍需预览确认。'];
}
function actionPrivateRequest(array $config,string $method,string $path,?array $body=null,float $timeout=20.0): array {
 if(isset($GLOBALS['boji_action_transport']))return ($GLOBALS['boji_action_transport'])($method,$path,$body);
 $base=$config['ai_proxy_base_url']??'http://127.0.0.1:8787';$token=$config['ai_proxy_token']??'';
 if(!preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base)||strlen($token)<24)throw new RuntimeException('private_service_unavailable');
 $ctx=stream_context_create(['http'=>['method'=>$method,'header'=>"Content-Type: application/json\r\nAuthorization: Bearer $token\r\n",'content'=>$body===null?'':json_encode($body,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),'timeout'=>max(.5,min(20,$timeout)),'ignore_errors'=>true,'follow_location'=>0]]);
 $raw=@file_get_contents($base.$path,false,$ctx);$code=502;foreach($http_response_header??[] as $h)if(preg_match('#^HTTP/\S+ (\d{3})#',$h,$m))$code=(int)$m[1];
 $value=is_string($raw)?json_decode($raw,true):null;
 if($code<200||$code>=300||!is_array($value))throw new RuntimeException($code===429?'quota_wait':'private_service_unavailable',$code);
 return $value;
}
function actionProcessPlanJobs(PDO $db,array $config,int $limit=10): int {
 if(function_exists('appFeatureEnabled')&&!appFeatureEnabled($db,'action_system_enabled'))return 0;
 $q=$db->query("SELECT * FROM ai_action_jobs WHERE status IN ('pending','dispatching','running','failed_retryable') AND next_attempt<=UTC_TIMESTAMP() ORDER BY created_at LIMIT ".max(1,min(50,$limit)));$count=0;
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){
  $lease=businessUUID();$claim=$db->prepare("UPDATE ai_action_jobs SET lease_token=?,status='dispatching',attempts=attempts+1,next_attempt=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 2 MINUTE),updated_at=UTC_TIMESTAMP() WHERE execution_id=? AND next_attempt<=UTC_TIMESTAMP()");$claim->execute([$lease,$row['execution_id']]);if(!$claim->rowCount())continue;
  try{
   if(strtotime($row['created_at'].' UTC')<time()-7200)throw new RuntimeException('job_timeout');
   $request=json_decode($row['request_json'],true);$response=actionPrivateRequest($config,'POST','/v1/jobs',$request);
   if(($response['status']??'')!=='succeeded')$response=actionPrivateRequest($config,'GET','/v1/jobs/'.$row['server_job_id']);
   $status=$response['status']??'running';$result=null;
   if($status==='succeeded'){
    $result=$response['result']??null;
    if(!is_array($result)||($result['kind']??'')!=='plan'||empty($result['sessions']))throw new RuntimeException('invalid_plan_result');
    foreach($result['sessions'] as &$s)$s['exercises']=actionTrustedExercises($db,(int)$row['user_id'],$s['exercises']);unset($s);$status='draft_ready';
   }elseif(in_array($status,['failed','rejected','cancelled','expired'],true))$status='failed_final';else $status='running';
   $db->prepare("UPDATE ai_action_jobs SET status=?,result_json=?,lease_token=NULL,next_attempt=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 20 SECOND),error_code=NULL,updated_at=UTC_TIMESTAMP() WHERE execution_id=? AND lease_token=?")->execute([$status,$result?json_encode($result,JSON_UNESCAPED_UNICODE):null,$row['execution_id'],$lease]);
   if($status==='draft_ready')$db->prepare('UPDATE ai_user_jobs SET completed_at=COALESCE(completed_at,UTC_TIMESTAMP()) WHERE user_id=? AND client_job_id=?')->execute([$row['user_id'],$row['execution_id']]);
   $count++;
  }catch(Throwable $e){$retry=(int)$row['attempts']<9&&$e->getMessage()!=='job_timeout';$db->prepare("UPDATE ai_action_jobs SET status=?,error_code=?,lease_token=NULL,next_attempt=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 60 SECOND),updated_at=UTC_TIMESTAMP() WHERE execution_id=? AND lease_token=?")->execute([$retry?'failed_retryable':'failed_final','service_or_validation',$row['execution_id'],$lease]);}
 }
 return $count;
}
function actionRecordPlanVersion(array &$state,array $before,array $p,string $proposal,array $dates): void {
 $id='action-plan-'.$p['draft_id'];$recordDate=min($dates);$start=$p['effective_start']??$recordDate;$parents=[];$changes=[];
 foreach($before['days']??[] as $d)foreach($d['planVersions']??[] as $v){if($v['id']===$id)return;if(array_intersect($dates,$v['scopeDates']))$parents[]=$v['id'];}
 foreach($dates as $date)foreach($before['days'][$date]['exercises']??[] as $e)if(!empty($e['planID']))$parents[]=$e['planID'];
 foreach($dates as $date){$changes[]=['date'=>$date,'before'=>actionExerciseTargets($before['days'][$date]['exercises']??[]),'after'=>actionExerciseTargets($state['days'][$date]['exercises']??[]),'retained'=>false];}
 $profile=$state['profile'];$record=['version'=>1,'id'=>$id,'recordedAt'=>businessDocumentNow(),'source'=>'ai','title'=>$p['title'],'start'=>$start,'duration'=>$p['duration'],'sessions'=>$p['requested_sessions']??$p['sessions'],'requestedProfile'=>$p['profile']??$profile,'adoptedProfile'=>$profile,'nutrition'=>$p['nutrition']??$state['nutritionTarget'],'previousIDs'=>array_values(array_unique($parents)),'scopeDates'=>array_values(array_unique(array_merge($dates,$p['retained_dates']??[]))),'retainedDates'=>$p['retained_dates']??[],'changes'=>$changes];
 if(isset($p['recurring_weekday'])){
  $days=array_fill(0,28,['title'=>'','movements'=>[]]);$origin=new DateTimeImmutable($start);
  foreach($p['requested_sessions']??$p['sessions'] as $session){
   $offset=(int)$origin->diff(new DateTimeImmutable($session['date']))->format('%r%a');if($offset<0||$offset>27)continue;$moves=[];
   foreach($session['exercises'] as $i=>$e){$first=$e['sets'][0];$timed=isset($first['durationSeconds']);$moves[]=['id'=>actionUUID($id.'/'.$session['date'].'/'.$i),'name'=>$e['name'],'muscle'=>$e['muscle'],'query'=>$e['library_query']??null,'libraryID'=>$e['library_id']??null,'customID'=>$e['custom_id']??null,'unit'=>$timed?'秒':'次','count'=>count($e['sets']),'weight'=>$first['weight']??0,'reps'=>$first['reps'],'seconds'=>$first['durationSeconds']??30,'individualSets'=>$e['sets']];}
   $days[$offset]=['title'=>$session['label'],'movements'=>$moves];
  }
  $templateID=actionUUID('template/'.$p['draft_id']);$draft=['version'=>1,'id'=>$templateID,'title'=>$p['title'],'start'=>$start,'duration'=>28,'days'=>$days,'planPatternLabel'=>'每周'.$p['recurring_weekday'].'，后续周期可复用','updatedAt'=>businessDocumentNow()];
  $state['planTemplates'][]=['id'=>$templateID,'createdAt'=>businessDocumentNow(),'updatedAt'=>businessDocumentNow(),'draft'=>$draft];
  cloudValidate($state['planTemplates'][array_key_last($state['planTemplates'])],'planTemplate','planTemplate');
 }
 $state['days'][$recordDate]['planVersions'][]=$record;
 $state['appliedAIJobs']=array_values(array_unique(array_merge($state['appliedAIJobs']??[],[$p['draft_id']])));
 foreach($dates as $date){$state['days'][$date]['planCycle']=['start'=>$start,'plannedDates'=>$dates,'endDate'=>(new DateTimeImmutable($start))->modify('+'.($p['duration']-1).' days')->format('Y-m-d'),'sourceJobID'=>$p['draft_id'],'explanationVersion'=>1];}
 cloudValidate($record,'planVersion','planVersion');
}
function actionExerciseTargets(array $exercises): array {
 return array_map(fn($e)=>['name'=>$e['name'],'muscle'=>$e['muscle'],'library_id'=>$e['libraryID']??null,'library_query'=>$e['libraryQuery']??null,'custom_id'=>$e['customExerciseID']??null,'custom_unit'=>$e['customUnit']??null,'rest_seconds'=>$e['restSeconds']??null,'sets'=>array_map(fn($s)=>array_intersect_key($s,array_flip(['weight','reps','durationSeconds'])),$e['sets'])],$exercises);
}

function actionProcessMessages(PDO $db,array $config): int {
 if(function_exists('appFeatureEnabled')&&!appFeatureEnabled($db,'action_system_enabled'))return 0;
 $q=$db->query("SELECT m.user_id,m.message_id,m.trace_id,j.server_job_id FROM ai_action_messages m JOIN ai_user_jobs j ON j.user_id=m.user_id AND j.client_job_id=m.message_id JOIN users u ON u.id=m.user_id AND u.status='active' WHERE m.status='accepted' AND m.created_at>DATE_SUB(UTC_TIMESTAMP(),INTERVAL 7 DAY)
 AND NOT EXISTS (SELECT 1 FROM ai_runs r WHERE r.user_id=m.user_id AND r.message_id=m.message_id)
 ORDER BY m.created_at LIMIT 20");$count=0;
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){try{if(!empty($row['trace_id']))$GLOBALS['boji_trace_id']=(string)$row['trace_id'];$response=actionPrivateRequest($config,'GET','/v1/jobs/'.$row['server_job_id']);actionResolveCompletedMessage($db,['id'=>(int)$row['user_id']],$row['message_id'],$response);$count++;}catch(Throwable $e){/* original IDs remain accepted and retryable */}}
 return $count;
}
