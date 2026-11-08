<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/ai-response.php';
require __DIR__.'/../account-server/public/business-state.php';
require __DIR__.'/../account-server/public/ai-context.php';
require __DIR__.'/../account-server/public/account-deletion.php';
function fail(string $message,int $status=400):never{throw new RuntimeException($message,$status);}
function lockActiveUser(PDO $db,int $uid):void{$q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);if($q->fetchColumn()!=='active')throw new RuntimeException('inactive',401);}
const DB131='boji_experience131_test';
if(!getenv('BOJI_TEST_DSN_BASE'))throw new RuntimeException('explicit isolated DSN required');
$root=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$root->exec('CREATE DATABASE '.DB131.' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db=bojiTestDatabase(DB131);if($db->query('SELECT DATABASE()')->fetchColumn()!==DB131)throw new RuntimeException('isolation');
bojiTestSchema($db,dirname(__DIR__).'/account-server');
foreach(['migrate-v2-repair.php','migrate-ai-context.php'] as $script){[$code,$out,$err]=bojiTestRunMigration(DB131,['--apply'],$script);if($code!==0)throw new RuntimeException($out.$err);}
$db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES(13101,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(13102,'disabled',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(13103,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$checks=0;function ck(bool $v,string $why):void{global $checks;if(!$v)throw new RuntimeException($why);$checks++;}
function rejects131(int $code,callable $fn):void{try{$fn();}catch(RuntimeException $e){ck($e->getCode()===$code,'wrong rejection '.$e->getCode().' '.$e->getMessage());return;}throw new RuntimeException('expected rejection');}
$config=['ai_proxy_token'=>str_repeat('synthetic',5),'otp_secret'=>str_repeat('synthetic',5)];
$date='2026-10-27';$meal=businessUUID();$conv=businessUUID();
$day=['exercises'=>[],'meals'=>[['id'=>$meal,'name'=>'馒头','category'=>'早餐','calories'=>200,'protein'=>6,'carbs'=>40,'fat'=>1,'estimated'=>true,'nutritionKnown'=>true]]];
$body=['conversation_id'=>$conv,'references'=>[['kind'=>'meal_entry','resource_id'=>$meal,'from'=>$date,'to'=>$date,'label131'=>'刚记录的早餐']],'local_records131'=>[$date=>$day]];
$r=aiContextResolve($db,13101,$body,$config);$ref=$r['references'][0];
ck($ref['read_only131']===true,'read-only');ck($ref['source_tier131']==='local_snapshot','honest source');ck($ref['snapshot'][0]['meals'][0]['calories']===200,'unsynced local meal present');
ck($db->query('SELECT count(*) FROM cloud_parts')->fetchColumn()==0,'never writes canonical records');
$loaded=aiContextLoad($db,13101,$r['bundle_id'],$conv,$config);ck(count($loaded['references'])===1,'load without cloud record');
rejects131(410,fn()=>aiContextLoad($db,13103,$r['bundle_id'],$conv,$config));rejects131(410,fn()=>aiContextLoad($db,13101,$r['bundle_id'],businessUUID(),$config));
ck(!str_contains($db->query('SELECT snapshot_cipher FROM ai_context_bundles LIMIT 1')->fetchColumn(),'馒头'),'encrypted');
$bad=$body;$bad['local_records131'][$date]['meals'][0]['calories']=-1;rejects131(400,fn()=>aiContextResolve($db,13101,$bad,$config));
$gone=$body;$gone['references'][0]['resource_id']=businessUUID();rejects131(410,fn()=>aiContextResolve($db,13101,$gone,$config));
// Snapshot survives cloud being updated independently; user local fingerprint governs UI freshness.
cloudPartPut($db,13101,'d/'.$date,['exercises'=>[],'meals'=>[]]);ck(count(aiContextLoad($db,13101,$r['bundle_id'],$conv,$config)['references'])===1,'no sync dependency');
$db->prepare('UPDATE ai_context_bundles SET expires_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 SECOND) WHERE id=?')->execute([$r['bundle_id']]);rejects131(410,fn()=>aiContextLoad($db,13101,$r['bundle_id'],$conv,$config));
require_once __DIR__.'/../account-server/public/usage-guard131.php';
$db->exec('DELETE FROM ai_guard_buckets131');$_SERVER['REMOTE_ADDR']='198.51.100.131';$_SERVER['HTTP_X_BOJI_INSTALL']=businessUUID();
for($i=0;$i<12;$i++)usageGuard131($db,13101,$config);rejects131(429,fn()=>usageGuard131($db,13101,$config));usageGuard131($db,13103,$config);ck(true,'different account');
// Administrator can erase a disabled account; recovery ticket is random, not an admin token.
enqueueAccountDeletion($db,['id'=>13102],$config,true);$queued=$db->query('SELECT * FROM account_deletions WHERE user_id=13102')->fetch();ck($queued['status']==='queued','disabled admin erase queued');ck(strlen($queued['token_hash'])===64,'opaque erasure ticket');
enqueueAccountDeletion($db,['id'=>13102],$config,true);ck($db->query('SELECT count(*) FROM account_deletions WHERE user_id=13102')->fetchColumn()==1,'idempotent admin erase');
ck($db->query('SELECT status FROM users WHERE id=13103')->fetchColumn()==='active','other account untouched');
try { enqueueAccountDeletion($db,['id'=>13103],$config,true,fn()=>throw new RuntimeException('audit unavailable'));throw new LogicException('expected audit rollback'); } catch(RuntimeException $e) { ck($e->getMessage()==='audit unavailable','audit failure surfaced'); }
ck($db->query('SELECT status FROM users WHERE id=13103')->fetchColumn()==='active','audit failure rolls back disable');
ck($db->query('SELECT count(*) FROM account_deletions WHERE user_id=13103')->fetchColumn()==0,'audit failure rolls back erasure task');
echo json_encode(['build'=>131,'sql_assertions'=>$checks,'database'=>DB131,'production_data'=>false],JSON_THROW_ON_ERROR)."\n";
