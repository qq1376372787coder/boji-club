<?php
declare(strict_types=1);
require_once __DIR__.'/php_test_bootstrap.php';
require_once dirname(__DIR__).'/account-server/cli-bootstrap.php';
require_once dirname(__DIR__).'/account-server/public/business-state.php';
require_once dirname(__DIR__).'/account-server/public/ai-context.php';
require_once dirname(__DIR__).'/account-server/public/fast-intent.php';
$db=bojiTestDatabase('boji_build122_check');$n=0;
function ck122(bool $ok,string $why):void{global $n;if(!$ok)throw new RuntimeException($why);$n++;}
function reject122(int $code,callable $fn):void{try{$fn();}catch(RuntimeException $e){ck122($e->getCode()===$code,'wrong reject '.$e->getCode());return;}throw new RuntimeException('expected rejection');}
$config=['ai_proxy_token'=>str_repeat('synthetic',5)];$GLOBALS['config']=$config;
$db->prepare("INSERT INTO users(apple_subject,status,created_at,updated_at) VALUES(?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute(['synthetic-build122']);$uid=(int)$db->lastInsertId();
$date='2026-10-25';$day=['meals'=>[],'exercises'=>[],'bodyMeasurements'=>[['id'=>businessUUID(),'kilograms'=>70.5,'waistCircumferenceCM'=>80,'recordedAt'=>1000]]];cloudPartPut($db,$uid,'d/'.$date,$day);
$body=['conversation_id'=>businessUUID(),'references'=>[['kind'=>'body_range','from'=>$date,'to'=>$date]]];
$result=aiContextResolve($db,$uid,$body,$config);ck122(count($result['references'])===1,'resolve');
ck122($result['references'][0]['snapshot'][0]['measurements'][0]['kilograms']===70.5,'measurement');
$raw=$db->query('SELECT snapshot_cipher FROM ai_context_bundles')->fetchColumn();ck122(!str_contains($raw,'kilograms'),'encrypted at rest');
ck122(aiContextLoad($db,$uid,$result['bundle_id'],$body['conversation_id'],$config)['bundle_id']===$result['bundle_id'],'reload');
reject122(410,fn()=>aiContextLoad($db,$uid+100,$result['bundle_id'],$body['conversation_id'],$config));
reject122(410,fn()=>aiContextLoad($db,$uid,$result['bundle_id'],businessUUID(),$config));
$day['bodyMeasurements'][0]['kilograms']=71;cloudPartPut($db,$uid,'d/'.$date,$day);
reject122(409,fn()=>aiContextLoad($db,$uid,$result['bundle_id'],$body['conversation_id'],$config));
$body['references'][0]['source_version']=$result['references'][0]['source_version'];reject122(409,fn()=>aiContextResolve($db,$uid,$body,$config));
$body['references']=array_fill(0,6,['kind'=>'body_range','from'=>$date]);reject122(422,fn()=>aiContextResolve($db,$uid,$body,$config));
$day['bodyMeasurements'][0]['kilograms']=null;$day['bodyMeasurements'][0]['waistCircumferenceCM']=null;
ck122(aiContextProjection(['kind'=>'body_range'],[$date=>$day])[0]['measurements']===[],'withdrawal');
reject122(403,fn()=>aiProviderConsentAssert($db,$uid,['_routing_version'=>3]));
$db->prepare('INSERT INTO ai_provider_consents VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,'2026-10-26.deepseek-minimax-v1']);aiProviderConsentAssert($db,$uid,['_routing_version'=>3]);ck122(true,'consent');
$request=['kind'=>'coach','date'=>$date,'payload'=>['question'=>'开始今天训练','capabilities'=>[['capability'=>'training.start_session']]]];ck122(aiFastIntent($request)['coach']['capability_calls'][0]['capability']==='training.start_session','fast start');
foreach(['不要开始训练','如果开始训练会怎样','我有点累','我已经开始了吗'] as $text){$request['payload']['question']=$text;ck122(aiFastIntent($request)===null,'ambiguous never direct');}
ck122(!aiDirectIntentAllowed('training.start_session','不要开始训练'),'negated direct');
ck122(!aiDirectIntentAllowed('body.record_weight','我有点累'),'fatigue never mutates');
ck122(aiDirectIntentAllowed('training.start_session','请开始今天训练'),'affirmative direct');
echo 'BUILD122_CONTEXT_OK checks='.$n."\n";
