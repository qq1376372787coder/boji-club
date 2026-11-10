<?php
declare(strict_types=1);
/** Run ONLY on a disposable schema; never accepts a production database name.
 * BOJI_TEST_DSN_BASE='mysql:unix_socket=/var/lib/mysql/mysql.sock' php tests/test_audit129_sql.php prepare|check|preflight|withdraw|write|hold
 * The hold mode uses two filesystem barriers to force a real concurrent lock race.
 */
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/ai-response.php';
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/app-config.php';
require __DIR__.'/../account-server/public/commands.php';
function fail(string $message,int $status=400): never {throw new RuntimeException($message,$status);}
// Same account row lock used by the HTTP router, with genuine InnoDB locks.
function lockActiveUser(PDO $db,int $uid): void {
    $q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);
    if($q->fetchColumn()!=='active')throw new RuntimeException('inactive fixture',401);
    if (($barrier=$GLOBALS['audit129_barrier']??null) && !($GLOBALS['audit129_locked']??false)) {
        $GLOBALS['audit129_locked']=true;file_put_contents($barrier.'.locked','1');
        $deadline=microtime(true)+10;
        while(!file_exists($barrier.'.release')){if(microtime(true)>$deadline)throw new RuntimeException('barrier timeout');usleep(10000);}
    }
}
const AUDIT129_DB='boji_audit129_test';
const AUDIT129_MSG='12900000-0000-4000-8000-000000000001';
$mode=$argv[1]??'check';$server=dirname(__DIR__).'/account-server';
if($mode==='prepare'){
    if(!getenv('BOJI_TEST_DSN_BASE'))throw new RuntimeException('explicit isolated DSN required');
    $root=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    // Refuse overwriting an existing schema, even if it has this test name.
    $root->exec('CREATE DATABASE '.AUDIT129_DB.' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    $db=bojiTestDatabase(AUDIT129_DB);bojiTestSchema($db,$server);
    foreach(['migrate-v2-repair.php','migrate-ai-context.php'] as $script){[$code,$out,$err]=bojiTestRunMigration(AUDIT129_DB,['--apply'],$script);if($code!==0)throw new RuntimeException($out.$err);}
    foreach([101,102] as $uid)$db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES($uid,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
    $db->prepare("INSERT INTO ai_runs(id,user_id,conversation_id,client_message_id,server_job_id,message_id,trace_id,status,request_hash,request_json,created_at,updated_at) VALUES(?,101,'audit129',?,?,?,?,'running',?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
      ->execute([AUDIT129_MSG,AUDIT129_MSG,AUDIT129_MSG,AUDIT129_MSG,str_repeat('1',32),str_repeat('a',64),json_encode(['payload'=>['_routing_version'=>3]])]);
    aiProviderConsentSet($db,101,true);aiProviderConsentSet($db,102,true);
    echo "ISOLATED_SCHEMA_READY\n";exit;
}
$db=bojiTestDatabase(AUDIT129_DB);
if($db->query('SELECT DATABASE()')->fetchColumn()!==AUDIT129_DB)throw new RuntimeException('isolation guard');
function command129(): array {
    return ['commandId'=>'12900000-0000-4000-8000-000000000002','type'=>'BodyWeight.CreateDirect','actor'=>'ai',
        'payload'=>['date'=>(new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai')))->format('Y-m-d'),
        'kilograms'=>70.5,'recorded_at'=>600000000,'idempotency_key'=>str_repeat('b',64)]];
}
if($mode==='preflight'){aiProviderConsentAssert($db,101,['_routing_version'=>3]);echo "PREFLIGHT_ALLOWED\n";exit;}
if($mode==='withdraw'){aiProviderConsentSet($db,101,false);echo "WITHDRAW_COMMITTED\n";exit;}
if($mode==='grant'){aiProviderConsentSet($db,101,true);echo "GRANT_COMMITTED\n";exit;}
if($mode==='status'){
 echo json_encode(['allowed'=>(int)$db->query('SELECT allowed FROM ai_provider_consents WHERE user_id=101')->fetchColumn(),
   'operations'=>(int)$db->query('SELECT COUNT(*) FROM data_operations WHERE user_id=101')->fetchColumn(),
   'outbox'=>(int)$db->query('SELECT COUNT(*) FROM domain_outbox WHERE user_id=101')->fetchColumn()])."\n";exit;
}
if($mode==='write'){
 try{$r=actionWithParent(101,AUDIT129_MSG,fn()=>handleBusinessCommandCore($db,['id'=>101],command129()));echo json_encode($r)."\n";}
 catch(RuntimeException $e){if($e->getCode()!==403)throw $e;echo "CONSENT_REJECTED_403\n";}exit;
}
if($mode==='withdraw102'){aiProviderConsentSet($db,102,false);echo "WITHDRAW102_COMMITTED\n";exit;}
if($mode==='status102'){
 echo json_encode(['allowed'=>(int)$db->query('SELECT allowed FROM ai_provider_consents WHERE user_id=102')->fetchColumn(),
   'operations'=>(int)$db->query('SELECT COUNT(*) FROM data_operations WHERE user_id=102')->fetchColumn()])."\n";exit;
}
if($mode==='hold'){
 $barrier=$argv[2]??'';if(!preg_match('#^/tmp/boji129-[a-z0-9-]+$#D',$barrier))throw new RuntimeException('unsafe barrier');
 $GLOBALS['audit129_barrier']=$barrier;
 $cmd=command129();$cmd['commandId']='12900000-0000-4000-8000-000000000003';$cmd['payload']['idempotency_key']=str_repeat('c',64);
 // Pause after the real command has acquired its account lock. A competing
 // withdrawal must wait for that command to commit; no mocked transaction.
 $r=actionWithParent(102,AUDIT129_MSG,fn()=>handleBusinessCommandCore($db,['id'=>102],$cmd));
 if($r['status']!=='succeeded')throw new RuntimeException('write failed');
 echo "HELD_COMMAND_COMMITTED\n";exit;
}
if($mode!=='check')throw new RuntimeException('unknown test mode');
$checks=0;function ck129(bool $yes,string $why):void{global $checks;if(!$yes)throw new RuntimeException($why);$checks++;}
$date='2020-01-15';$sid='12900000-0000-4000-8000-000000000010';$old='12900000-0000-4000-8000-000000000011';
$ex=['id'=>'12900000-0000-4000-8000-000000000020','name'=>'卧推','muscle'=>'胸','sets'=>[['id'=>'12900000-0000-4000-8000-000000000021','weight'=>20,'reps'=>10,'completed'=>false]]];
foreach([[],['exercises'=>[$ex]]] as $extra){
 $state=['days'=>[$date=>['exercises'=>[$ex]]]];trainingApplyStart($state,['date'=>$date]+$extra,$sid);$day=$state['days'][$date];
 ck129(count($day['exercises'])===1,'must not duplicate planned exercise');
 ck129(strtolower($day['exercises'][0]['workoutSessionID'])===$sid,'bind existing planned row');
 $bound=$day['exercises'][0];unset($bound['workoutSessionID']);ck129($bound===$ex,'preserve targets and IDs');
 ck129(count($day['workoutSessions'])===1,'one session');
}
$history=$ex;$history['id']='12900000-0000-4000-8000-000000000030';$history['workoutSessionID']=$old;$history['sets'][0]['completed']=true;
$state=['days'=>[$date=>['exercises'=>[$ex,$history]]]];trainingApplyStart($state,['date'=>$date],$sid);
ck129($state['days'][$date]['exercises'][1]===$history,'do not rebind actual history');
$unbound=$ex;$unbound['sets'][0]['actualEntered']=true;$state=['days'=>[$date=>['exercises'=>[$unbound]]]];trainingApplyStart($state,['date'=>$date],$sid);
ck129(!isset($state['days'][$date]['exercises'][0]['workoutSessionID']),'do not invent a session for legacy actuals');
try{$state=['days'=>[$date=>['exercises'=>[$history]]]];trainingApplyStart($state,['date'=>$date,'exercises'=>[$history]],$sid);throw new LogicException('expected conflict');}catch(BusinessActionError $e){ck129($e->getCode()===409,'different owner conflicts');}
// Verify the real command transaction rejects the withdrawal after preflight.
aiProviderConsentAssert($db,101,['_routing_version'=>3]);aiProviderConsentSet($db,101,false);
try{actionWithParent(101,AUDIT129_MSG,fn()=>handleBusinessCommandCore($db,['id'=>101],command129()));throw new LogicException('expected denial');}catch(RuntimeException $e){ck129($e->getCode()===403,'withdrawal fences command');}
ck129((int)$db->query('SELECT COUNT(*) FROM data_operations WHERE user_id=101')->fetchColumn()===0,'no receipt after rejection');
ck129((int)$db->query('SELECT COUNT(*) FROM domain_outbox WHERE user_id=101')->fetchColumn()===0,'no event after rejection');
try{actionWithParent(101,'12900000-0000-4000-8000-000000000099',fn()=>handleBusinessCommandCore($db,['id'=>101],command129()));throw new LogicException('expected legacy denial');}catch(RuntimeException $e){ck129($e->getCode()===403,'legacy callback also respects explicit withdrawal');}
aiProviderConsentSet($db,101,true);
$r=actionWithParent(101,AUDIT129_MSG,fn()=>handleBusinessCommandCore($db,['id'=>101],command129()));ck129($r['status']==='succeeded','real command succeeds with consent');
$r=actionWithParent(101,AUDIT129_MSG,fn()=>handleBusinessCommandCore($db,['id'=>101],command129()));ck129($r['idempotent']===true,'retry unchanged');
ck129((int)$db->query('SELECT COUNT(*) FROM data_operations WHERE user_id=101')->fetchColumn()===1,'one receipt');
ck129((int)$db->query('SELECT COUNT(*) FROM domain_outbox WHERE user_id=101')->fetchColumn()===1,'one event');
aiProviderConsentSet($db,101,false);
ck129((int)$db->query('SELECT COUNT(*) FROM data_operations WHERE user_id=101')->fetchColumn()===1,'withdrawal preserves committed fact');
echo "PASS $checks SQL/domain checks\n";
