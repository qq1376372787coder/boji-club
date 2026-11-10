<?php
declare(strict_types=1);
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/cloud-validation.php';
require __DIR__ . '/../account-server/public/commands.php';
require __DIR__ . '/../account-server/public/insights.php';
require __DIR__ . '/../account-server/public/ai-memory.php';
function fail(string $message, int $status = 400): never { throw new RuntimeException($message, $status); }
function respond(int $status, array $payload): never { throw new RuntimeException($payload['error'] ?? 'response', $status); }
function lockActiveUser(PDO $db, int $uid): void { $q=$db->prepare('SELECT id FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]); }
$checks = 0;
function check(bool $ok, string $message): void { global $checks; $checks++; if (!$ok) throw new RuntimeException('FAIL: '.$message); }
$db = bojiTestDatabase('bojiclub_repair_test');
bojiTestSchema($db, __DIR__.'/../account-server');
$db->exec('DELETE FROM users');
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13500000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$uid=(int)$db->lastInsertId();
$today=insightHomeToday();$from=(new DateTimeImmutable($today))->modify('+1 day')->format('Y-m-d');$to=(new DateTimeImmutable($today))->modify('+3 days')->format('Y-m-d');
$exercise=['id'=>strtoupper(commandUUID()),'name'=>'深蹲','muscle'=>'腿','sets'=>[['id'=>strtoupper(commandUUID()),'weight'=>20,'reps'=>10,'completed'=>false]]];
$original=['profile'=>['goal'=>'力量','daysPerWeek'=>3],'days'=>[$from=>['exercises'=>[$exercise],'meals'=>[]]]];
$parts=cloudPartSplit($original);
foreach($parts as $key=>$value) cloudPartPut($db,$uid,$key,$value);
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,json_encode(cloudPartMetadata($parts['meta']))]);
$create=function(string $kind,array $payload,?string $key=null,?array $baseline=null) use ($db,$uid):array {
    $db->beginTransaction();lockActiveUser($db,$uid);
    try { $r=aiProposalCreate($db,$uid,$kind,$payload,[],null,$key,24,$baseline);$db->commit();return $r; }
    catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
};
$command=function(string $type,string $pid,?string $id=null) use($db,$uid):array {
    return handleBusinessCommandCore($db,['id'=>$uid],['commandId'=>$id??commandUUID(),'type'=>$type,'payload'=>['proposalId'=>$pid]]);
};
$moves=['moves'=>[['from'=>$from,'to'=>$to]]];
$p=$create('plan_change_proposal',$moves,hash('sha256','preview'));
check(count(cloudPartGet($db,$uid,'d/'.$from)['exercises'])===1,'creating preview never moves');
check(cloudPartGet($db,$uid,'d/'.$to)===null,'creating preview does not create destination');
check((int)$db->query('SELECT COUNT(*) FROM data_operations')->fetchColumn()===0,'no execution on preview');
// Changing only a weight must invalidate the preview, even without a version bump.
$changed=$original['days'][$from];$changed['exercises'][0]['sets'][0]['weight']=22;
cloudPartPut($db,$uid,'d/'.$from,$changed);
$rejected=false;try{$command('PlanReschedule.Confirm',$p['proposal_id']);}catch(RuntimeException $e){$rejected=$e->getCode()===409;}
check($rejected,'changed source rejects stale proposal');
check(cloudPartGet($db,$uid,'d/'.$to)===null,'conflict never mutates destination');
// Even an ABA edit (same final contents, higher revision) must invalidate the old preview.
$aba=$create('plan_change_proposal',$moves,hash('sha256','aba'));
$db->prepare('UPDATE app_states SET revision=revision+1 WHERE user_id=?')->execute([$uid]);
$rejected=false;try{$command('PlanReschedule.Confirm',$aba['proposal_id']);}catch(RuntimeException $e){$rejected=$e->getCode()===409;}
check($rejected,'revision changes invalidate preview even when contents return to the same value');
// Fresh preview and confirm on a partitioned account.
$p=$create('plan_change_proposal',$moves,hash('sha256','fresh'));
$id=commandUUID();$result=$command('PlanReschedule.Confirm',$p['proposal_id'],$id);
check($result['status']==='succeeded','partitioned confirmation succeeds');
$source=cloudPartGet($db,$uid,'d/'.$from);$target=cloudPartGet($db,$uid,'d/'.$to);
check($source['exercises']===[] && count($target['exercises'])===1,'partitioned source/destination atomically moved');
check($target['exercises'][0]['sets'][0]['weight']===22,'current approved weight preserved');
check($target['exercises'][0]['id']!==$exercise['id'],'moved exercises use new IDs');
check($target['activeWorkoutSessionID']===$target['exercises'][0]['workoutSessionID'],'session IDs are coherent');
check($source['plannedMoveDestination']===$to && $target['movedFromDate']===$from,'move provenance retained');
cloudValidate($target,'day');cloudValidate($source,'day');
check(isset($target['planShifts'][0]),'shift record present');
check(count(aiProposalList($db,$uid,'succeeded'))===1,'status filter uses valid parameterized SQL');
$ledger=$db->query('SELECT idempotency_key FROM ai_action_executions')->fetchColumn();
check($ledger===hash('sha256','fresh'),'execution ledger retains real idempotency key');
$again=$command('PlanReschedule.Confirm',$p['proposal_id'],$id);
check($again['idempotent']===true,'same command safely replays');
$again=$command('PlanReschedule.Confirm',$p['proposal_id']);
check($again['idempotent']===true,'succeeded proposal recovers after lost response');
check((int)$db->query('SELECT COUNT(*) FROM data_operations')->fetchColumn()===1,'retry creates no duplicate operation');
check($db->query('SELECT event_type FROM domain_outbox')->fetchColumn()==='PlanRescheduled','correct event kind');
// Different intents may contain identical food. A repeated intent never duplicates.
$meal=['date'=>$today,'meals'=>[['name'=>'鸡蛋','category'=>'早餐','calories'=>80]]];
$m1=$create('meal_draft',$meal,hash('sha256','meal-1'));$m2=$create('meal_draft',$meal,hash('sha256','meal-2'));
check($m1['proposal_id']!==$m2['proposal_id'],'identical content can represent new intent');
$command('Meal.Create',$m1['proposal_id']);$command('Meal.Create',$m1['proposal_id']);$command('Meal.Create',$m2['proposal_id']);
check(count(cloudPartGet($db,$uid,'d/'.$today)['meals'])===2,'two intents create two meals, retries do not duplicate');
$w=$create('weight_entry',['date'=>$today,'kilograms'=>72.5]);$command('BodyWeight.Create',$w['proposal_id']);
$day=cloudPartGet($db,$uid,'d/'.$today);
check(abs($day['bodyWeight']['updatedAt']-businessDocumentNow())<5,'weight timestamp follows Swift reference epoch');
cloudValidate($day,'day');
file_put_contents(getenv('BOJI_REPAIR_WEIGHT_FIXTURE')?:sys_get_temp_dir().'/boji-repaired-weight.json',json_encode($day['bodyWeight']));
// Legacy commands must keep their own event and aggregate metadata.
handleBusinessCommandCore($db,['id'=>$uid],['commandId'=>commandUUID(),'type'=>'Profile.Update','payload'=>['profile'=>['goal'=>'增肌']]]);
check($db->query("SELECT aggregate_type FROM data_operations WHERE command_type='Profile.Update'")->fetchColumn()==='profile','legacy aggregate preserved');
check((int)$db->query("SELECT COUNT(*) FROM domain_outbox WHERE event_type='ProfileUpdated'")->fetchColumn()===1,'legacy event preserved');
// Seven moves must fit audit column bounds and preserve every destination.
$batch=[];
foreach(range(0,6) as $i){
    $a=(new DateTimeImmutable($today))->modify('+' . (40+$i*2) . ' days')->format('Y-m-d');
    $b=(new DateTimeImmutable($a))->modify('+1 day')->format('Y-m-d');
    cloudPartPut($db,$uid,'d/'.$a,['exercises'=>[$exercise],'meals'=>[]]);
    $batch[]=['from'=>$a,'to'=>$b];
}
$many=$create('plan_change_proposal',['moves'=>$batch]);$command('PlanReschedule.Confirm',$many['proposal_id']);
foreach($batch as $move)check(count(cloudPartGet($db,$uid,'d/'.$move['to'])['exercises'])===1,'batch destination preserved');
// Suspended entries stay visible and may resume. Stale derived evidence is excluded.
$state=['profile'=>['goal'=>'力量','daysPerWeek'=>3],'days'=>[]];
foreach(range(1,5) as $offset){$date=(new DateTimeImmutable($today))->modify("-$offset days")->format('Y-m-d');$state['days'][$date]=['exercises'=>[['sets'=>[['completed'=>true,'reps'=>10]]]],'workoutSavedAt'=>businessDocumentNow(),'meals'=>[]];}
aiMemoryExtract($db,$uid,$state,$today,10);
$habit=$db->query("SELECT memory_id FROM user_memory_items WHERE kind='habit' LIMIT 1")->fetchColumn();
check(is_string($habit),'habit extracted from sufficient observations');
aiMemorySetStatus($db,$uid,$habit,'suspended');
// Page sweeps use this fresh legacy document fixture, independent of partition tests.
$db->prepare('UPDATE app_states SET state_json=? WHERE user_id=?')->execute([json_encode($state),$uid]);
$page=aiMemoryPage($db,$uid);
check(count(array_filter($page['habits'],fn($i)=>$i['status']==='suspended'))===1,'paused memory remains visible');
aiMemorySetStatus($db,$uid,$habit,'active');
check(aiMemoryFetch($db,$uid,$habit)['status']==='active','paused memory can resume');
aiMemoryExtract($db,$uid,['profile'=>['goal'=>'力量'],'days'=>[]],$today,11);
check((int)$db->query("SELECT confidence FROM user_memory_items WHERE memory_id='$habit'")->fetchColumn()===0,'lost evidence invalidates derived memory');
$goal=$db->query("SELECT memory_id FROM user_memory_items WHERE kind='goal'")->fetchColumn();
$c=aiMemoryCorrect($db,$uid,$goal,'我的目标是力量优先');
aiMemoryExtract($db,$uid,['profile'=>[],'days'=>[]],$today,12);
check(aiMemoryFetch($db,$uid,$c['memory_id'])['status']==='active','user correction survives expiry sweep');
check(aiProposalPayloadValid('weight_entry',['date'=>'2026-02-31','kilograms'=>72])===null,'invalid calendar date rejected');
echo "V2 repair: $checks assertions passed\n";
