<?php
declare(strict_types=1);
/** Resolve action context from authoritative IDs, never invented model identifiers. */
function actionClarify(string $capability,string $question,array $choices=[]): array {
 return ['capability'=>$capability,'status'=>'needs_clarification','card'=>aiRouterCard(['card_type'=>'clarification','title'=>'先确认一下','payload'=>['question'=>$question,'choices'=>$choices]],'clarify/'.$capability.'/'.$question)];
}
function aiRouterTrainingContext(PDO $db,array $user,string $cap,array $input): array {
 $uid=(int)$user['id'];$date=$input['date']??actionToday($db,$uid);$active=trainingActiveFetch($db,$uid);
 if($active){$date=$active['date_key'];$sid=$active['session_id'];}else $sid=$input['session_id']??null;
 $loaded=aiRouterState($db,$uid,[$date]);$day=$loaded['state']['days'][$date]??[];
 if($cap==='training.start_session'){
  if(!$active&&empty($day['exercises']))return actionClarify($cap,'这一天没有训练安排。请先选择或创建训练计划。');
  $sessionID=$sid??strtolower($day['activeWorkoutSessionID']??actionUUID('session/'.($GLOBALS['boji_action_id']??businessUUID())));
  $context=['date'=>$date,'session_id'=>$sessionID];$sessions=$day['workoutSessions']??[];
  if(!$active&&$sessions&&!array_filter($sessions,fn($v)=>empty($v['cancelledAt']))){
   $last=end($sessions);$copies=[];foreach($day['exercises'] as $e)if(strtolower($e['workoutSessionID']??'')===strtolower($last['id'])){
    $e['id']=businessUUID();$e['workoutSessionID']=strtoupper($sessionID);foreach($e['sets'] as &$set){$set['id']=businessUUID();$set['completed']=false;}unset($set);$copies[]=$e;
   }
   if(!$copies||count($copies)+count($day['exercises'])>30)return actionClarify($cap,'已放弃的训练记录已保留，请在训练页新建一次训练并选择动作。');$context['exercises']=$copies;
  }
  return $context;
 }
 $sid=$sid??strtolower($day['activeWorkoutSessionID']??'');
 if(!trainingSessionIDValid($sid)||empty($day['workoutStartedAt'])||!empty($day['workoutSavedAt']))return actionClarify($cap,'没有找到进行中的训练。请先开始或恢复对应训练。');
 if($cap==='training.finish_session'){
  $exercises=array_values(array_filter($day['exercises']??[],fn($e)=>empty($e['workoutSessionID'])||strtolower($e['workoutSessionID'])===$sid));
  $remaining=0;foreach($exercises as $e)foreach($e['sets'] as $set)if(empty($set['completed']))$remaining++;
  $p=['date'=>$date,'session_id'=>$sid];
  if($remaining){$p['remaining_sets']=$remaining;return aiRouterPreview($db,$user,$cap,$p,['proposal_kind'=>'training_finish','ui_card_type'=>'schedule_preview']);}
  return $p;
 }
 $candidates=array_values(array_filter($day['exercises']??[],fn($e)=>(empty($e['workoutSessionID'])||strtolower($e['workoutSessionID'])===$sid)&&(!isset($input['exercise_id'])||strtolower($e['id'])===strtolower($input['exercise_id']))&&(!isset($input['exercise_name'])||mb_strtolower($e['name'])===mb_strtolower($input['exercise_name']))));
 if(count($candidates)!==1)return actionClarify($cap,'请明确动作名称，以及本组实际重量和次数（计时动作请说明秒数）。',array_column($candidates,'name'));
 $e=$candidates[0];$set=null;foreach($e['sets'] as $v)if((isset($input['set_id'])&&strtolower($v['id'])===strtolower($input['set_id']))||(!isset($input['set_id'])&&empty($v['completed']))){$set=$v;break;}
 if($set&&!empty($set['completed']))return actionClarify($cap,'这组已经记录。若需纠正实际数值，请在训练页打开该组核对后修改。');
 if(!$set)return actionClarify($cap,'没有可匹配的未完成训练组，请在训练页增加或选择一组。');
 if(!isset($input['reps'])&&!isset($input['duration_seconds']))return actionClarify($cap,'这一组实际做了多少次或多少秒？');
 if(!isset($input['weight'])&&($set['weight']??0)>0&&!isset($input['duration_seconds']))return actionClarify($cap,'请确认这一组的实际重量，不能把计划重量当成已完成重量。');
 return ['date'=>$date,'session_id'=>$sid,'exercise_id'=>strtolower($e['id']),'set_id'=>strtolower($set['id']),
 'weight'=>$input['weight']??0,'reps'=>$input['reps']??0,'duration_seconds'=>$input['duration_seconds']??null,'completed'=>true];
}
function actionTrustedExercises(PDO $db,int $uid,array $exercises): array {
 static $catalog=null;
 if($catalog===null){$catalog=[];$path=__DIR__.'/../resources/action-exercise-catalog.json';foreach(json_decode((string)file_get_contents($path),true)??[] as $e){$catalog[$e['id']]=$e;}}
 $custom=aiRouterState($db,$uid,[])['state'];$deleted=array_map('strtolower',$custom['deletedCustomExerciseIDs']??[]);$owned=[];foreach($custom['customExercises']??[] as $v)if(!in_array(strtolower($v['id']),$deleted,true))$owned[strtolower($v['id'])]=$v;
 $rows=[];
 foreach($exercises as $e){
  if(isset($e['custom_id'])){
   $v=$owned[strtolower($e['custom_id'])]??null;if(!$v)fail('个人动作不存在或已删除。',422);
   $e['name']=$v['name'];$e['muscle']=$v['muscle'];$e['custom_id']=$v['id'];$e['custom_unit']=$v['unit'];unset($e['library_id'],$e['library_query']);
   $normalized=aiPlannedExerciseValid($e);if(!$normalized)fail('个人动作组数或计量不正确。',422);$rows[]=$normalized;continue;
  }
  $match=null;
  if(isset($e['library_id']))$match=$catalog[$e['library_id']]??null;
  else { $matches=array_values(array_filter($catalog,fn($v)=>mb_strtolower($v['name_zh'])===mb_strtolower($e['name']??'')||mb_strtolower($v['name'])===mb_strtolower($e['name']??'')));if(count($matches)===1)$match=$matches[0]; }
  if(!$match)fail('动作不能匹配可信动作库，请在动作库中选择具体变式。',422);
  $e['name']=$match['name_zh'];$e['muscle']=$match['category_zh'];$e['library_id']=$match['id'];$e['library_query']=$match['name'];
  $normalized=aiPlannedExerciseValid($e);if(!$normalized)fail('动作组数或计量不正确。',422);$rows[]=$normalized;
 }
 return $rows;
}
function actionPlanDraftPayload(PDO $db,int $uid,array $input): array {
 $id=strtolower($input['draft_id']??'');$q=$db->prepare("SELECT result_json,request_json FROM ai_action_jobs WHERE user_id=? AND execution_id=? AND status='draft_ready'");$q->execute([$uid,$id]);$row=$q->fetch(PDO::FETCH_ASSOC);
 if(!$row)fail('候选计划未准备好或不属于当前账号。',409);
 $result=json_decode($row['result_json'],true);$request=json_decode($row['request_json'],true);$sessions=$result['sessions']??[];
 foreach($sessions as &$s)$s['exercises']=actionTrustedExercises($db,$uid,$s['exercises']);unset($s);
 $retained=[];$state=aiRouterState($db,$uid,array_column($sessions,'date'))['state'];
 foreach($sessions as $session)if(businessDayProtected($state['days'][$session['date']]??[]))$retained[]=$session['date'];
 $requested=$sessions;$sessions=array_values(array_filter($sessions,fn($s)=>!in_array($s['date'],$retained,true)));
 if(!$sessions)fail('所有日期均已有进行中或已完成训练，请调整候选计划的日期。',409);
 return ['retained_dates'=>$retained,'requested_sessions'=>$requested,'draft_id'=>$id,'sessions'=>$sessions,'title'=>$result['title']??'新训练计划','duration'=>$request['payload']['plan_days']??7,'effective_start'=>$request['date'],'profile'=>$request['payload']['profile'],'nutrition'=>$request['payload']['nutrition_target']??null,'recurring_weekday'=>$request['payload']['recurring_weekday']??null];
}

/** A recurring request becomes an editable versioned draft, never an immediate template mutation. */
function actionRecurringSwapDraft(PDO $db,array $user,array $input,string $id): array {
 $uid=(int)$user['id'];$start=$input['date'];$end=(new DateTimeImmutable($start))->modify('+27 days')->format('Y-m-d');
 if($start<actionToday($db,$uid))fail('长期变更须从今天或未来开始。',422);
 $state=aiRouterState($db,$uid,[$start,$end])['state'];if(empty($state['profile'])||empty($state['nutritionTarget']))return actionClarify('plan.preview_exercise_swap','请先完成训练资料和目标设置。');
 $exercises=actionTrustedExercises($db,$uid,$input['exercises']);$weekday=(new DateTimeImmutable($start))->format('N');$sessions=[];
 for($date=new DateTimeImmutable($start);$date->format('Y-m-d')<=$end;$date=$date->modify('+1 day')){
  $key=$date->format('Y-m-d');$targets=$date->format('N')===$weekday?$exercises:actionExerciseTargets($state['days'][$key]['exercises']??[]);
  if($targets)$sessions[]=['date'=>$key,'label'=>$date->format('N')===$weekday?'每周调整':'保留原安排','exercises'=>$targets];
 }
 $result=['kind'=>'plan','title'=>'每周训练安排调整','plan_days'=>28,'notes'=>['本次具体生效范围 '.$start.' 至 '.$end.'；已开始或已完成训练将保留。','确认后同时保存每周模板；后续周期可从模板继续安排。'],'sessions'=>$sessions,'plan_pattern'=>'每周'.$weekday.'的训练调整'];
 $config=$GLOBALS['config']??[];if(empty($config['otp_secret']))fail('行动服务未配置。',503);
 $request=['id'=>aiJobID($user,$id,$config),'kind'=>'generate_plan','date'=>$start,'payload'=>['profile'=>$state['profile'],'plan_days'=>28,'nutrition_target'=>$state['nutritionTarget'],'recurring_weekday'=>(int)$weekday]];
 $db->prepare("INSERT IGNORE INTO ai_action_jobs(execution_id,user_id,server_job_id,request_json,result_json,status,next_attempt,created_at,updated_at) VALUES(?,?,?,?,?,'draft_ready',UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$id,$uid,$request['id'],json_encode($request,JSON_UNESCAPED_UNICODE),json_encode($result,JSON_UNESCAPED_UNICODE)]);
 return ['capability'=>'plan.preview_exercise_swap','status'=>'completed','execution_id'=>$id,'job_id'=>$id,'data'=>['job_id'=>$id,'draft_ready'=>true],'note'=>'长期变更候选已生成，查看具体日期和动作后确认；当前计划尚未改变。'];
}
