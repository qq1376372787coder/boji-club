<?php
declare(strict_types=1);
if(!getenv('BOJI_TEST_DSN_BASE')){fwrite(STDERR,"Use an isolated BOJI_TEST_DSN_BASE.\n");exit(2);}
require __DIR__.'/php_test_bootstrap.php';require __DIR__.'/../account-server/public/ai-response.php';require __DIR__.'/../account-server/public/cloud-validation.php';require __DIR__.'/../account-server/public/ai-router.php';
function fail(string $m,int $c=400):never{businessReject($c,['error'=>$m]);}
function lockActiveUser(PDO $d,int $u):void{$q=$d->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$u]);if(!$q->fetchColumn())fail('inactive',403);}
function appFeatureEnabled(PDO $d,string $k):bool{return true;}
$db=bojiTestDatabase('bojiclub_it');$GLOBALS['config']=['membership_enforcement'=>false,'otp_secret'=>'isolated-action-fix-fixture-only'];$checks=0;
function ok(bool $v,string $s):void{global $checks;if(!$v)throw new RuntimeException('FAIL: '.$s);$checks++;}
function caught(callable $f,int $code):void{try{$f();ok(false,'expected conflict');}catch(BusinessActionError $e){ok($e->getCode()===$code,'expected domain status '.$code);}}
function user():int{global $db;static $n=0;$n++;$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute(['1365439'.str_pad((string)$n,4,'0',STR_PAD_LEFT)]);$id=(int)$db->lastInsertId();$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,updated_at) VALUES(?,1,'Asia/Shanghai','kg',UTC_TIMESTAMP())")->execute([$id]);$db->prepare("INSERT INTO membership_entitlements(user_id,status,source,starts_at,expires_at,created_at,updated_at) VALUES(?,'active','admin',UTC_TIMESTAMP(),'2099-12-31 23:59:59',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$id]);return $id;}
function fixture(int $u,array $days=[]):void{global $db;$p=['nickname'=>'fixture','age'=>28,'height'=>175,'weight'=>70,'goal'=>'增肌','experience'=>'新手','venue'=>'健身房','daysPerWeek'=>1,'focus'=>'全身'];$n=['caloriesMin'=>1800,'caloriesMax'=>2200,'proteinMin'=>100,'proteinMax'=>130,'fatMin'=>40,'fatMax'=>60,'meals'=>3,'note'=>'fixture'];$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$u,json_encode(['profile'=>$p,'nutritionTarget'=>$n,'days'=>$days])]);}
function state(int $u):array{global $db;$q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$u]);return json_decode($q->fetchColumn(),true);}
function call(int $u,string $name,array $input=[],?string $id=null):array{global $db;return businessScoped(fn()=>aiRouterRouteOne($db,['id'=>$u],['capability'=>$name,'input'=>$input,'_action_id'=>$id??businessUUID()]));}
function command(int $u,string $type,array $payload):array{global $db;return businessScoped(fn()=>handleBusinessCommandCore($db,['id'=>$u],['commandId'=>businessUUID(),'type'=>$type,'payload'=>$payload,'actor'=>'user']));}
function exercise():array{$catalog=json_decode(file_get_contents(__DIR__.'/../account-server/resources/action-exercise-catalog.json'),true);$e=$catalog[0];return ['id'=>strtoupper(businessUUID()),'name'=>$e['name_zh'],'muscle'=>$e['category_zh'],'libraryID'=>$e['id'],'sets'=>[['id'=>strtoupper(businessUUID()),'weight'=>0,'reps'=>10,'completed'=>false]]];}
$db->exec("DELETE FROM users WHERE phone LIKE '1365439%'");$today=(new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');$future=(new DateTimeImmutable($today))->modify('+2 days')->format('Y-m-d');$future2=(new DateTimeImmutable($today))->modify('+4 days')->format('Y-m-d');
$u=user();fixture($u,[$today=>['exercises'=>[exercise()],'meals'=>[]],$future=>['exercises'=>[exercise()],'meals'=>[]]]);
// Independent intents and network retries are different identities.
$a=call($u,'body.record_weight',['date'=>$today,'kilograms'=>70.5]);$b=call($u,'body.record_weight',['date'=>$today,'kilograms'=>71]);$c=call($u,'body.record_weight',['date'=>$today,'kilograms'=>70.5]);
ok(count(state($u)['days'][$today]['bodyMeasurements'])===3,'three true samples remain');ok((float)state($u)['days'][$today]['bodyWeight']['kilograms']===70.5,'A B A is a new operation');
$undo=businessScoped(fn()=>aiRouterUndo($db,['id'=>$u],['command_id'=>$a['data']['commandId']]));ok(count(state($u)['days'][$today]['bodyMeasurements'])===2,'undo removes only the requested measurement');ok((float)state($u)['days'][$today]['bodyWeight']['kilograms']===70.5,'later sample survives undo');$again=businessScoped(fn()=>aiRouterUndo($db,['id'=>$u],['command_id'=>$a['data']['commandId']]));ok($again['result']['commandId']===$undo['result']['commandId'],'lost undo response replays');
// Model confirmation tools never execute high-impact writes.
ok(!in_array('schedule.commit_change',array_column(capabilityWhitelistForModel(),'capability'),true),'commit excluded from model');ok(call($u,'schedule.commit_change',['proposal_id'=>businessUUID()])['status']==='rejected','router refuses model commit');
// Native preview/confirm persists actual library identity and immutable version.
$planned=exercise();$target=['name'=>$planned['name'],'muscle'=>$planned['muscle'],'library_id'=>$planned['libraryID'],'sets'=>[['weight'=>0,'reps'=>12]]];
$swap=call($u,'plan.preview_exercise_swap',['date'=>$future,'exercises'=>[$target]]);ok($swap['status']==='awaiting_confirmation','swap creates preview');ok(isset($swap['card']['payload']['_preview_before'][$future]),'preview includes exact before image');
$confirmed=actionConfirmProposal($db,['id'=>$u],$swap['proposal_id']);ok($confirmed['status']==='succeeded','swap confirm executes');ok(state($u)['days'][$future]['exercises'][0]['sets'][0]['reps']===12,'swap applies new targets');
// Shared message ID fences replay across view recreation and different devices.
$message=businessUUID();$body=['message_id'=>$message,'calls'=>[['capability'=>'body.record_weight','input'=>['date'=>$today,'kilograms'=>69]]]];
$r=aiRouterResolve($db,['id'=>$u],$body);$r2=aiRouterResolve($db,['id'=>$u],$body);ok($r['results'][0]['execution_id']===$r2['results'][0]['execution_id'],'stable call identity');ok(count(state($u)['days'][$today]['bodyMeasurements'])===3,'message replay does not add sample');
$partial=aiRouterResolve($db,['id'=>$u],['message_id'=>businessUUID(),'calls'=>[['capability'=>'training.get_today','input'=>[]],['capability'=>'nutrition.save_entry','input'=>['date'=>$today,'meals'=>[['name'=>'饭','category'=>'wrong']]]]]]);ok($partial['results'][0]['status']==='completed'&&$partial['results'][1]['status']==='rejected','partial results survive a rejected child');
// Explicit and unambiguous training context is resolved by the server.
$start=call($u,'training.start_session',['date'=>$today]);ok($start['status']==='completed','start mapping works');$sid=$start['data']['diff']['session_id'];
$log=call($u,'training.log_set',['date'=>$today,'exercise_name'=>$planned['name'],'weight'=>0,'reps'=>12]);ok($log['status']==='completed','log set mapping works');ok(state($u)['days'][$today]['exercises'][0]['sets'][0]['completed']===true,'actual set marked completed');
caught(fn()=>command($u,'Training.SessionFinish',['date'=>$future2,'session_id'=>$sid]),409);ok(trainingActiveFetch($db,$u)!==null,'wrong-date finish preserves active slot');
$finish=call($u,'training.finish_session',['date'=>$today]);ok($finish['status']==='completed','finish mapping works');ok(trainingActiveFetch($db,$u)===null,'finish releases slot');
// Real durable job -> dispatch -> draft -> preview -> explicit version activation.
$jobID=businessUUID();$job=call($u,'plan.generate_draft',['goal'=>'增肌','start_date'=>$future2],$jobID);ok($job['status']==='accepted','plan job durably accepted');
$GLOBALS['boji_action_transport']=fn($method,$path,$body)=>['status'=>'succeeded','result'=>['kind'=>'plan','title'=>'背部计划','notes'=>[],'sessions'=>[['date'=>$future2,'label'=>'背部','exercises'=>[$target]]]]];
ok(actionProcessPlanJobs($db,$GLOBALS['config'],10)>0,'worker dispatches and stores draft');unset($GLOBALS['boji_action_transport']);
$activation=call($u,'plan.activate_version',['draft_id'=>$jobID]);ok($activation['status']==='awaiting_confirmation','draft ID resolves to trusted sessions');ok(!isset(state($u)['days'][$future2]),'generation and preview do not activate');
$activated=actionConfirmProposal($db,['id'=>$u],$activation['proposal_id']);ok($activated['status']==='succeeded','activation confirmation works');ok(isset(state($u)['days'][$future2]['planVersions'][0]),'immutable version stored');ok(in_array($jobID,state($u)['appliedAIJobs'],true),'activated draft recorded for recovery');
// Nutrition draft is readable by the actual client shape and can be undone.
$meal=call($u,'nutrition.create_draft',['date'=>$today,'meals'=>[['name'=>'鸡胸肉','category'=>'午餐','calories'=>200]]]);ok(isset($meal['card']['payload']['meals'],$meal['card']['payload']['date']),'meal preview contract matches Swift');$saved=actionConfirmProposal($db,['id'=>$u],$meal['proposal_id']);ok(count(state($u)['days'][$today]['meals'])===1,'confirmed meal saved');businessScoped(fn()=>aiRouterUndo($db,['id'=>$u],['command_id'=>$saved['commandId']]));ok(count(state($u)['days'][$today]['meals'])===0,'confirmed draft undo removes only its entry');
// Partitioned history is untouched by undo and 28-day reads.
$v=user();$far=(new DateTimeImmutable($today))->modify('-60 days')->format('Y-m-d');$middle=(new DateTimeImmutable($today))->modify('-14 days')->format('Y-m-d');
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$v,json_encode(['_partitioned'=>2])]);cloudPartPut($db,$v,'meta',['recordIntegrityVersion'=>1]);cloudPartPut($db,$v,'d/'.$far,['exercises'=>[],'meals'=>[]]);$e=exercise();$e['sets'][0]['completed']=true;cloudPartPut($db,$v,'d/'.$middle,['exercises'=>[$e],'meals'=>[],'workoutSavedAt'=>businessDocumentNow()]);cloudPartPut($db,$v,'d/'.$today,['exercises'=>[],'meals'=>[]]);$sample=call($v,'body.record_weight',['date'=>$today,'kilograms'=>70]);businessScoped(fn()=>aiRouterUndo($db,['id'=>$v],['command_id'=>$sample['data']['commandId']]));ok(state($v)['_partitioned']===2,'undo preserves partition marker');ok(cloudPartGet($db,$v,'d/'.$far)!==null,'far history remains');ok(call($v,'training.get_history',['days'=>28])['data']['training_days']===1,'middle partitions included');
// Advisory misses are not interpreted as evidence of readiness.
$advice=call($v,'coach.assess_readiness',['question'=>'很累且明显不适']);ok(!in_array('normal',array_column($advice['data']['options'],'choice'),true),'symptoms lead to clarification');
// Inapplicable consumers never create a reconciliation loop.
$event=businessUUID();$db->prepare("INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,?,?,'profile','fixture',1,'ProfileUpdated','{}','published',0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$event,businessUUID(),$v]);outboxDispatch($db,['event_id'=>$event,'event_type'=>'ProfileUpdated','user_id'=>$v]);$gaps=domainProjectionGaps($db,['notifications-v1']);ok(!in_array($event,array_merge(...array_values($gaps?:[[]])),true),'unsubscribed consumer is not missing');
$pending=businessUUID();$db->prepare("INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,?,?,'training','fixture',2,'WorkoutSessionFinished.v1','{}','published',0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$pending,businessUUID(),$v]);ok(aiRouterProjectionStatus($db,$v)['in_sync']===false,'missing receipts cannot show green');
// A later domain failure is isolated after an earlier child has really committed.
$batch=aiRouterResolve($db,['id'=>$u],['message_id'=>businessUUID(),'calls'=>[
 ['capability'=>'body.record_weight','input'=>['date'=>$today,'kilograms'=>68]],
 ['capability'=>'schedule.preview_change','input'=>['moves'=>[['from'=>$future2,'to'=>$future]]]],
 ['capability'=>'training.get_today','input'=>[]]]]);
ok($batch['results'][0]['status']==='completed'&&$batch['results'][1]['status']==='rejected'&&$batch['results'][2]['status']==='completed','domain failure returns committed and subsequent children');
// Recurring swap creates an editable candidate, template and confirmed preference only after activation.
$w=user();fixture($w,[$future=>['exercises'=>[exercise()],'meals'=>[]]]);
$recurring=call($w,'plan.preview_exercise_swap',['date'=>$future,'scope'=>'recurring','exercises'=>[$target]]);
ok($recurring['status']==='completed'&&isset($recurring['data']['job_id']),'recurring candidate exists');ok(!isset(state($w)['planTemplates']),'template not changed before confirmation');
$preview=call($w,'plan.activate_version',['draft_id'=>$recurring['job_id']]);ok($preview['status']==='awaiting_confirmation','recurring candidate binds preview');
actionConfirmProposal($db,['id'=>$w],$preview['proposal_id']);ok(count(state($w)['planTemplates'])===1,'confirmed recurring template saved');
$q=$db->prepare("SELECT COUNT(*) FROM user_memory_items WHERE user_id=? AND kind='preference'");$q->execute([$w]);ok((int)$q->fetchColumn()===1,'confirmed pattern preference remembered');
// Meal review editing replaces the old proposal, preserves portion and leaves final commit explicit.
$draft=call($w,'nutrition.create_draft',['date'=>$today,'meals'=>[['name'=>'米饭','category'=>'午餐','portion'=>'150 g','estimated'=>true,'confidence'=>0.7]]]);
$body=['edit_id'=>businessUUID(),'payload'=>['date'=>$today,'meals'=>[['name'=>'米饭','category'=>'午餐','portion'=>'100 g','calories'=>116,'estimated'=>true,'confidence'=>0.7]]]];
$edited=actionEditMealDraft($db,['id'=>$w],$draft['proposal_id'],$body);ok($edited['proposal_id']!==$draft['proposal_id'],'edit receives a new preview');ok(aiProposalFetch($db,$w,$draft['proposal_id'])['status']==='cancelled','old preview cancelled atomically');
ok(actionEditMealDraft($db,['id'=>$w],$draft['proposal_id'],$body)['proposal_id']===$edited['proposal_id'],'edit response loss replays');
ok(empty(state($w)['days'][$today]['meals']),'saving draft edits does not save meal');
actionConfirmProposal($db,['id'=>$w],$edited['proposal_id']);$entry=state($w)['days'][$today]['meals'][0];ok($entry['portion']==='100 g'&&$entry['recognitionConfidence']===0.7,'portion and provenance survive commit');
// Discard abandons unfinished targets while preserving real completed sets, and permits a fresh attempt.
$x=user();$e=exercise();$e['sets'][]=['id'=>strtoupper(businessUUID()),'weight'=>0,'reps'=>12,'completed'=>false];fixture($x,[$today=>['exercises'=>[$e],'meals'=>[]]]);
call($x,'training.start_session',['date'=>$today]);call($x,'training.log_set',['date'=>$today,'exercise_name'=>$e['name'],'weight'=>0,'reps'=>10]);
$fin=call($x,'training.finish_session',['date'=>$today]);ok($fin['status']==='awaiting_confirmation','unfinished sets require choice');actionDiscardTraining($db,['id'=>$x],$fin['proposal_id']);$day=state($x)['days'][$today];ok($day['exercises'][0]['sets'][0]['completed']&&!empty($day['workoutSessions'][0]['cancelledAt']),'discard preserves recorded sets');ok(trainingActiveFetch($db,$x)===null,'discard releases active slot');
$restart=call($x,'training.start_session',['date'=>$today]);ok($restart['status']==='completed','fresh attempt after discard starts');ok(count(state($x)['days'][$today]['exercises'])===2,'new attempt clones targets without overwriting old facts');
$history=call($v,'training.get_history',['days'=>28,'exercise_name'=>$e['name']]);ok(isset($history['data']['days'][0]['movements'][0]['sets'][0]['weight']),'history contains actual movement values');
caught(fn()=>command($w,'Schedule.Replace',['date'=>$future,'exercises'=>[]]),409);
$GLOBALS['config']['membership_enforcement']=true;caught(fn()=>call($w,'plan.generate_draft',['start_date'=>$future]),403);$GLOBALS['config']['membership_enforcement']=false;
echo "Action repair: $checks integration assertions passed\n";
