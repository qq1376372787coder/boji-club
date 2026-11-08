<?php
declare(strict_types=1);
/** Explicit disposable database only; no production configuration is loaded. */
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/ai-response.php';
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/commands.php';
require __DIR__.'/../account-server/public/capability-registry.php';
function fail(string $message,int $status=400):never{throw new RuntimeException($message,$status);}
function lockActiveUser(PDO $db,int $uid):void{$q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);if($q->fetchColumn()!=='active')throw new RuntimeException('fixture inactive');}
function appFeatureEnabled(PDO $db,string $key):bool{return true;}
function respond(int $status,array $payload):never{throw new RuntimeException($payload['error']??'response',$status);}
const DB130='boji_experience130_test';
if(!getenv('BOJI_TEST_DSN_BASE'))throw new RuntimeException('explicit isolated DSN required');
$root=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$root->exec('CREATE DATABASE '.DB130.' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db=bojiTestDatabase(DB130);if($db->query('SELECT DATABASE()')->fetchColumn()!==DB130)throw new RuntimeException('isolation');
bojiTestSchema($db,dirname(__DIR__).'/account-server');
foreach(['migrate-v2-repair.php','migrate-ai-context.php'] as $script){[$code,$out,$err]=bojiTestRunMigration(DB130,['--apply'],$script);if($code!==0)throw new RuntimeException($out.$err);}
$db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES(13001,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(13002,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$checks=0;function ck(bool $yes,string $why):void{global $checks;if(!$yes)throw new RuntimeException($why);$checks++;}
$uid=13001;$date='2020-01-15';
$meals=[['name'=>'鸡蛋','category'=>'早餐','calories'=>465,'protein'=>37.8,'carbs'=>3.3,'fat'=>31.8,'portion'=>'6个；按50克估算','estimated'=>true,'requiresReview'=>true,'nutritionSources'=>['USDA/01129']],['name'=>'米饭','category'=>'午餐','calories'=>200,'protein'=>4,'carbs'=>44,'fat'=>1]];
$cap=capabilityRegistryEntry('nutrition.create_draft');ck(capabilitySchemaValid(['date'=>$date,'meals'=>$meals],$cap['input_schema']),'actual capability schema accepts portion/provenance');
$p=aiProposalCreate($db,$uid,'meal_draft',['date'=>$date,'meals'=>$meals],[],null,null);
$cmd=['commandId'=>commandUUID(),'type'=>'Meal.Create','actor'=>'user','payload'=>['proposalId'=>$p['proposal_id']]];
$r=handleBusinessCommandCore($db,['id'=>$uid],$cmd);ck($r['status']==='succeeded','save multi-meal proposal');
ck(count($r['diff']['written_meals']??[])===2,'canonical receipt has both meals');
$state=json_decode($db->query('SELECT state_json FROM app_states WHERE user_id='.$uid)->fetchColumn(),true);
ck(count($state['days'][$date]['meals'])===2,'both meals persisted');
ck(count(array_unique(array_column($state['days'][$date]['meals'],'id')))===2,'stable unique meal identities');
ck(count(array_unique(array_column($state['days'][$date]['meals'],'sourceAIJobID')))===2,'per-meal source identities');
ck($state['days'][$date]['meals'][0]['portion']===$meals[0]['portion'],'portion survives proposal save');
ck($state['days'][$date]['meals'][0]['nutritionSources']===['USDA/01129'],'source survives save');
$replay=handleBusinessCommandCore($db,['id'=>$uid],$cmd);ck($replay['idempotent']===true,'same command replays original receipt');
ck(array_column($replay['diff']['written_meals'],'id')===array_column($r['diff']['written_meals'],'id') && $replay['diff']['written_meals']==$r['diff']['written_meals'],'retry preserves record IDs');
$legacy=$state;$legacy['days'][$date]['meals'][1]['sourceAIJobID']=$legacy['days'][$date]['meals'][0]['sourceAIJobID'];
$merged=cloudReconcileRecords($legacy,$legacy);$merged["days"]=(array)$merged["days"];ck(count($merged['days'][$date]['meals'])===2,'legacy same source distinct IDs never deleted');
$next='2020-01-16';$moved=$legacy;$moved['days'][$next]=['exercises'=>[],'meals'=>[$legacy['days'][$date]['meals'][0]]];
$merged=cloudReconcileRecords($moved,$legacy);$merged["days"]=(array)$merged["days"];ck(array_sum(array_map(fn($day)=>count($day['meals']),$merged['days']))===2,'same meal ID on two dates deduplicates');
// Simulate old client's optimistic completed document while the active claim remains.
$sid=commandUUID();$ex=['id'=>commandUUID(),'name'=>'卧推','muscle'=>'胸','sets'=>[['id'=>commandUUID(),'weight'=>22.5,'reps'=>10,'completed'=>true]]];
$payload=['date'=>$date,'session_id'=>$sid,'started_at'=>600000000,'ended_at'=>600001000,'saved_at'=>600001000,'exercises'=>[$ex]];
$state=['days'=>[$date=>['exercises'=>[],'meals'=>[]]]];trainingApplyFinish($state,$payload);
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(13002,1,?,UTC_TIMESTAMP())')->execute([json_encode($state)]);
trainingActiveClaim($db,13002,$sid,$date);
$bad=$payload;$bad['exercises'][0]['sets'][0]['weight']=99;
try{handleBusinessCommandCore($db,['id'=>13002],['commandId'=>commandUUID(),'type'=>'Training.SessionFinish','actor'=>'user','payload'=>$bad]);throw new LogicException('expected conflict');}catch(RuntimeException $e){ck($e->getCode()===409,'changed actual facts refused');}
ck(trainingActiveFetch($db,13002)!==null,'conflict retains active claim');
$finish=['commandId'=>commandUUID(),'type'=>'Training.SessionFinish','actor'=>'user','payload'=>$payload];
$r=handleBusinessCommandCore($db,['id'=>13002],$finish);ck($r['status']==='succeeded','matching pending finish recovers');
ck(trainingActiveFetch($db,13002)===null,'recovered finish releases claim');
ck((int)$db->query("SELECT COUNT(*) FROM domain_outbox WHERE user_id=13002 AND event_type='WorkoutSessionFinished.v1'")->fetchColumn()===1,'one finish event');
$r=handleBusinessCommandCore($db,['id'=>13002],$finish);ck($r['idempotent']===true,'finish retry idempotent');
try{handleBusinessCommandCore($db,['id'=>13002],['commandId'=>commandUUID(),'type'=>'Training.SessionFinish','actor'=>'user','payload'=>$payload]);throw new LogicException('expected saved conflict');}catch(RuntimeException $e){ck($e->getCode()===409,'new finish without claim refused');}
// New repeat metadata validates, and an old client cannot silently clear it.
$day=['title'=>'','movements'=>[]];$draft=['id'=>commandUUID(),'version'=>1,'title'=>'测试','start'=>$date,'duration'=>28,'days'=>array_fill(0,28,$day)];
$t=['id'=>$draft['id'],'createdAt'=>600000000,'draft'=>$draft,'recurrence130'=>['enabled'=>true,'start'=>$date,'days'=>array_fill(0,7,$day)]];
ck(cloudPlanDraftsValid(['planTemplates'=>[$t]]),'weekly metadata accepted');
$bad=$t;$bad['recurrence130']['days']=array_fill(0,6,$day);ck(!cloudPlanDraftsValid(['planTemplates'=>[$bad]]),'invalid week rejected');
$old=$t;unset($old['recurrence130']);$kept=cloudPreserveV2Meta(['days'=>[],'planTemplates'=>[$old]],['days'=>[],'planTemplates'=>[$t]]);
ck(isset($kept['planTemplates'][0]['recurrence130']),'older client omission retains recurrence');
ck(aiProposalFetch($db,13002,$p['proposal_id'])===null,'cross-account proposal hidden');
echo "PASS $checks isolated SQL/domain assertions\n";
