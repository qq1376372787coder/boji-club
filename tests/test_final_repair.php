<?php
declare(strict_types=1);
/** Regression tests for the independently reproduced release blockers. */
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/app-config.php';
require __DIR__.'/../account-server/public/ai-response.php';
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/ai-router.php';
require __DIR__.'/../account-server/public/ai-runs.php';
function fail(string $s,int $c=400):never{businessReject($c,['error'=>$s]);}
function lockActiveUser(PDO $db,int $uid):void{$q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn())fail('inactive',403);}
function check(bool $ok,string $s):void{if(!$ok)throw new RuntimeException('FAIL: '.$s);}
$GLOBALS['config']=['membership_enforcement'=>false,'otp_secret'=>str_repeat('x',64),'ai_proxy_base_url'=>'http://127.0.0.1:18792','ai_proxy_token'=>'independent-audit-loopback-only-token-1234'];
$base=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS bojiclub_final_repair_test');
$base->exec('CREATE DATABASE bojiclub_final_repair_test');
$db=bojiTestDatabase('bojiclub_final_repair_test');
bojiTestSchema($db,__DIR__.'/../account-server');
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13998765101','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$uid=(int)$db->lastInsertId();$user=['id'=>$uid];
$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,proactive_learning,updated_at) VALUES(?,1,'Asia/Shanghai','kg',1,UTC_TIMESTAMP())")->execute([$uid]);
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,json_encode(['days'=>[],'profile'=>[]])]);
$pub=appConfigDefaults();foreach(['ai_enabled','ai_streaming_v2','action_system_enabled'] as $key)$pub[$key]=true;
$db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([json_encode($pub),json_encode($pub)]);
$today=actionToday($db,$uid);$message=businessUUID();$conv=businessUUID();
$db->exec("CREATE TRIGGER final_fail_user_turn BEFORE INSERT ON ai_messages FOR EACH ROW BEGIN IF NEW.role='user' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='injected user persistence failure'; END IF; END");
try{
 aiRunCreate($db,$user,$GLOBALS['config'],$conv,['client_message_id'=>$message,'request'=>['kind'=>'coach','date'=>$today,'payload'=>['conversation_id'=>$conv,'question'=>'记录体重','days'=>[],'history'=>[]]]],$message);
 check(false,'user turn persistence failure must fail acceptance');
}catch(PDOException $e){check((int)$db->query('SELECT COUNT(*) FROM ai_runs')->fetchColumn()===0,'run rolls back with missing user turn');}
finally{$db->exec('DROP TRIGGER final_fail_user_turn');}
$run=aiRunCreate($db,$user,$GLOBALS['config'],$conv,['client_message_id'=>$message,'message'=>['type'=>'text','text'=>'记录体重'],'request'=>['kind'=>'coach','date'=>$today,'payload'=>['conversation_id'=>$conv,'question'=>'记录体重','history'=>[],'days'=>[],'timeZone'=>'Asia/Shanghai']]],$message);
aiRunCancel($db,$uid,$run['run_id']);
try{
 actionWithParent($uid,$message,fn()=>businessScoped(fn()=>handleBusinessCommandCore($db,$user,['commandId'=>businessUUID(),'type'=>'BodyWeight.CreateDirect','payload'=>['date'=>$today,'kilograms'=>70,'idempotency_key'=>str_repeat('a',64)],'actor'=>'ai'])));
 check(false,'parent cancellation must be checked inside domain transaction');
}catch(BusinessActionError $e){check(($e->detail['code']??'')==='PARENT_RUN_CANCELLED','expected cancellation fence');}
check((int)$db->query('SELECT COUNT(*) FROM data_operations')->fetchColumn()===0,'no domain mutation after cancellation');
check(($GLOBALS['boji_action_parent']??null)===null,'parent scope does not leak to next request');
function exercise(string $seed,string $name='平板杠铃卧推',string $library='0025',bool $completed=false):array{
 return ['id'=>strtoupper(actionUUID('ex/'.$seed)),'name'=>$name,'muscle'=>'胸','libraryID'=>$library,'sets'=>[['id'=>strtoupper(actionUUID('set/'.$seed)),'weight'=>50,'reps'=>10,'completed'=>$completed]]];
}
$a=(new DateTimeImmutable($today))->modify('+1 day')->format('Y-m-d');$b=(new DateTimeImmutable($today))->modify('+3 days')->format('Y-m-d');
$state=['days'=>[$a=>['exercises'=>[exercise('original')],'meals'=>[]],$b=>['exercises'=>[],'meals'=>[]]],'profile'=>[]];
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$preview=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_change','input'=>['moves'=>[['from'=>$a,'to'=>$b]]]]);
$moved=actionConfirmProposal($db,$user,$preview['proposal_id']);
$inverse=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$moved['commandId']]]);
check($inverse['status']==='awaiting_confirmation','unchanged entity has a safe reverse preview');
$compPayload=aiProposalFetch($db,$uid,$inverse['proposal_id'])['payload'];
check($compPayload['compensates']===$moved['commandId'],'inverse retains original operation identity');
$version=(int)json_decode($db->query('SELECT state_json FROM app_states WHERE user_id='.$uid)->fetchColumn(),true)['days'][$b]['_schedule_version'];
handleBusinessCommandCore($db,$user,['commandId'=>businessUUID(),'type'=>'Schedule.Replace','payload'=>['date'=>$b,'exercises'=>[exercise('later')]],'expectedVersions'=>['schedule:'.$b=>$version],'actor'=>'user']);
$afterEdit=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$moved['commandId']]]);
check($afterEdit['status']==='rejected','later replacement blocks a new inverse preview');
try{actionConfirmProposal($db,$user,$inverse['proposal_id']);check(false,'older inverse preview cannot overwrite later edit');}catch(BusinessActionError $e){check($e->getCode()===409,'stale inverse is conflict');}
$session=actionUUID('confirmed/session');$bar=exercise('bar','平板杠铃卧推','0025',true);$dumb=exercise('dumb','平板哑铃卧推','0289',true);
$bar['workoutSessionID']=$session;$dumb['workoutSessionID']=$session;
$state=['profile'=>['age'=>28],'days'=>[$today=>['exercises'=>[$bar,$dumb],'meals'=>[],'workoutSessions'=>[['id'=>$session,'savedAt'=>time()]]]]];
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$result=aiRouterRouteOne($db,$user,['capability'=>'fitness.suggest_progression','input'=>['exercise_name'=>'卧推','effort_acceptable'=>true]]);
check($result['status']==='needs_clarification','ambiguous equipment must ask which variant');
$state['days'][$today]['workoutSessions'][0]['cancelledAt']=time();
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$result=aiRouterRouteOne($db,$user,['capability'=>'fitness.suggest_progression','input'=>['library_id'=>'0025','effort_acceptable'=>true]]);
check($result['status']==='needs_clarification','cancelled sessions cannot support progression');
$state['profile']['age']=16;
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$restricted=aiRouterRouteOne($db,$user,['capability'=>'fitness.suggest_progression','input'=>['library_id'=>'0025','effort_acceptable'=>true]]);
check($restricted['status']==='needs_clarification','adult progression is not prescribed to a minor');
// Long-term corrections: keep one occurrence, reverse future targets and weekly memory/template.
$profile=['nickname'=>'fixture','age'=>28,'height'=>175,'weight'=>70,'goal'=>'增肌','experience'=>'新手','venue'=>'健身房','daysPerWeek'=>1,'focus'=>'全身'];
$nutrition=['caloriesMin'=>1800,'caloriesMax'=>2200,'proteinMin'=>100,'proteinMax'=>130,'fatMin'=>40,'fatMax'=>60,'meals'=>3,'note'=>'fixture'];
$state=['profile'=>$profile,'nutritionTarget'=>$nutrition,'days'=>[$a=>['exercises'=>[exercise('original-a')],'meals'=>[]],$b=>['exercises'=>[exercise('original-b')],'meals'=>[]]]];
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$planned=['name'=>'平板哑铃卧推','muscle'=>'胸','library_id'=>'0289','sets'=>[['weight'=>20,'reps'=>10]]];
$payload=['draft_id'=>businessUUID(),'title'=>'长期哑铃安排','duration'=>7,'effective_start'=>$a,'recurring_weekday'=>(int)(new DateTimeImmutable($a))->format('N'),'sessions'=>[['date'=>$a,'label'=>'第一个日期','exercises'=>[$planned]],['date'=>$b,'label'=>'第二个日期','exercises'=>[$planned]]]];
function activateFixture(PDO $db,int $uid,array $payload):array{
 $db->beginTransaction();try{$p=aiProposalCreate($db,$uid,'plan_activation',$payload,[],null,hash('sha256',businessUUID()));$db->commit();}catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
 return actionConfirmProposal($db,['id'=>$uid],$p['proposal_id']);
}
function readFixture(PDO $db,int $uid):array{$q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);return json_decode($q->fetchColumn(),true);}
$activated=activateFixture($db,$uid,$payload);$after=readFixture($db,$uid);$templateID=$after['planTemplates'][0]['id'];
check(count($after['planTemplates'])===1,'recurring activation creates a template');
$comp=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$activated['commandId'],'keep_date'=>$a]]);
check($comp['status']==='awaiting_confirmation','recurring correction can preview a new compensating version');
check(readFixture($db,$uid)['days'][$b]['exercises'][0]['name']==='平板哑铃卧推','preview does not restore before confirmation');
$corrected=actionConfirmProposal($db,$user,$comp['proposal_id']);$after=readFixture($db,$uid);
check($after['days'][$a]['exercises'][0]['name']==='平板哑铃卧推','explicitly retained date keeps its change');
check($after['days'][$b]['exercises'][0]['name']==='平板杠铃卧推','other future target is restored with a new occurrence');
check(empty($after['planTemplates'])&&in_array($templateID,$after['deletedPlanTemplateIDs'],true),'compensation removes only its template and records a tombstone');
check($corrected['diff']['compensates']===$activated['commandId'],'new command links the original operation');
check((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE user_id=$uid AND kind='preference' AND status='active'")->fetchColumn()===0,'obsolete weekly inference is no longer injected');
$redo=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$corrected['commandId']]]);
check($redo['status']==='awaiting_confirmation','a compensating version itself has a safe inverse');
actionConfirmProposal($db,$user,$redo['proposal_id']);$after=readFixture($db,$uid);
check($after['days'][$b]['exercises'][0]['name']==='平板哑铃卧推'&&count($after['planTemplates'])===1,'inverse correction restores the plan and template as new entities');
check($after['planTemplates'][0]['id']!==$templateID,'deleted template identity is not resurrected');
$payload['draft_id']=businessUUID();$again=activateFixture($db,$uid,$payload);$saved=readFixture($db,$uid);
$edited=$saved;$last=array_key_last($edited['planTemplates']);$edited['planTemplates'][$last]['draft']['title']='用户之后修改过的模板';
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($edited),$uid]);
$blocked=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$again['commandId']]]);
check($blocked['status']==='rejected','later template edits block an inverse');
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($saved),$uid]);
$db->prepare("UPDATE user_memory_items SET content='用户之后明确修改的偏好',origin='user' WHERE user_id=? AND status='active'")->execute([$uid]);
$blocked=aiRouterRouteOne($db,$user,['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$again['commandId']]]);
check($blocked['status']==='rejected','later explicit preference edits win over compensation');
check(businessDayFingerprint(['exercises'=>[['weight'=>50]]])===businessDayFingerprint(['exercises'=>[['weight'=>50.0]]]),'numeric serialization does not create a false version conflict');
echo "FINAL_REPAIR_OK\n";

