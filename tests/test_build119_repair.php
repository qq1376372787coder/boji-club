<?php
declare(strict_types=1);
// Integration regressions: only run with an explicitly isolated MySQL instance.
if (!getenv('BOJI_TEST_DSN_BASE')) { fwrite(STDERR,"An isolated BOJI_TEST_DSN_BASE is required.\n"); exit(2); }
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/cli-bootstrap.php';
require __DIR__.'/../account-server/public/app-config.php';
require __DIR__.'/../account-server/public/ai-router.php';
require __DIR__.'/../account-server/public/onboarding-v2.php';
require __DIR__.'/../account-server/public/task-center.php';
$checks=0;
function verify(bool $v,string $message):void { global $checks; if(!$v)throw new RuntimeException('FAIL '.$message);$checks++; }
function rejected(int $code,callable $fn):void { try{$fn();}catch(Throwable $e){verify((int)$e->getCode()===$code,'expected '.$code.' got '.$e->getCode().':'.$e->getMessage());return;}throw new RuntimeException('Expected rejection '.$code); }
function fixture(PDO $db):array { $db->prepare("INSERT INTO users(apple_subject,status,created_at,updated_at) VALUES(?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute(['repair119-'.bin2hex(random_bytes(8))]);return ['id'=>(int)$db->lastInsertId(),'status'=>'active']; }
$base=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$name='boji_build119_repair_test';$base->exec('DROP DATABASE IF EXISTS '.$name);$base->exec('CREATE DATABASE '.$name.' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db=bojiTestDatabase($name);bojiTestSchema($db,__DIR__.'/../account-server');
[$exit,$out,$err]=bojiTestRunMigration($name,['--apply']);verify($exit===0,'base migrations '.$out.$err);
$GLOBALS['config']=['otp_secret'=>'synthetic-local-repair119-only','membership_enforcement'=>true];
$u=fixture($db);$uid=$u['id'];
$state=['profile'=>['goal'=>'养成运动习惯'],'days'=>new stdClass(),'appliedAIJobs'=>[]];
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,json_encode($state)]);
$s=onboardingCreateSession($db,$u,['task_kind'=>'plan_create'],'create');$sid=$s['session']['id'];
verify($s['profile_revision']===0,'fresh account remains unknown');
$same=onboardingCreateSession($db,$u,['task_kind'=>'plan_create'],'create');verify($same['session']['id']===$sid,'create is idempotent');
rejected(409,fn()=>onboardingCreateSession($db,$u,['task_kind'=>'meal_log'],'create'));
$changes=[['field'=>'goal','value'=>'增肌塑形'],['field'=>'experience','value'=>'新手'],['field'=>'venue','value'=>'在家'],['field'=>'equipment','value'=>['哑铃']],['field'=>'days_per_week','value'=>3],['field'=>'training_days','value'=>[1,3,5]],['field'=>'session_minutes','value'=>30],['field'=>'age_group','value'=>'adult']];
$d=onboardingPatchDraft($db,$u,$sid,['expected_session_revision'=>1,'changes'=>$changes],'patch');
$p=onboardingPreview($db,$u,$sid,['expected_profile_revision'=>0,'expected_session_revision'=>$d['session']['revision']],'preview');
$restored=onboardingState($db,$uid);verify($restored['pending_profile_proposal']['proposal_id']===$p['proposal_id'],'preview identity survives reload');
$cbody=['proposal_id'=>$p['proposal_id'],'expected_profile_revision'=>0,'expected_session_revision'=>$p['session_revision']];
$c=onboardingConfirm($db,$u,$sid,$cbody,'confirm');verify($c['status']==='committed','confirm committed');
verify($c['state']['plan_ready']===true,'minimum confirmed training conditions ready');verify($c['state']['required_missing_fields']===[],'confirmed fields not reasked');
verify(!isset($c['state']['confirmed_facts']['age_years']),'no fabricated age');
$again=onboardingConfirm($db,$u,$sid,$cbody,'confirm');verify($again['receipt']===$c['receipt'],'same confirmation receipt');
$row=$db->query('SELECT revision,state_json FROM app_states WHERE user_id='.$uid)->fetch();$cloud=json_decode($row['state_json'],true);
verify((int)$row['revision']===2&&$cloud['profile']['goal']==='增肌塑形','fact and sync projection commit together');
$canonical=profileFactsPlanningPayload($db,$uid,['age'=>28,'height'=>175,'weight'=>68]);verify(!isset($canonical['age'],$canonical['height'],$canonical['weight']),'planning excludes invented body facts');
$preview=profileChangePreview($db,$u,['expected_profile_revision'=>1,'changes'=>[['field'=>'profile_weight_kg','value'=>70,'unit'=>'kg']]],'weight-preview');
$committed=profileChangeConfirm($db,$u,['proposal_id'=>$preview['proposal_id'],'expected_profile_revision'=>1],'weight-confirm');verify($committed['status']==='committed','normal profile preview and confirm');
$clear=profileFactsClear($db,$u,['field'=>'profile_weight_kg','expected_profile_revision'=>2],'weight-clear');
$db->beginTransaction();profileFactsImportLegacyProfile($db,$uid,['weight'=>70],'legacy_recorded','cloud_sync');$db->commit();
$after=profileFactsRead($db,$uid);verify(!isset($after['facts']['profile_weight_kg'])&&$after['revision']===3,'withdrawn fact cannot resurrect');
$doc=profileFactsRead($db,$uid);$current=onboardingState($db,$uid);$p=onboardingPreview($db,$u,$sid,['expected_profile_revision'=>$doc['revision'],'expected_session_revision'=>$current['session']['revision'],'changes'=>[['field'=>'goal','value'=>'提升力量']]],'old-preview');
$new=onboardingPatchDraft($db,$u,$sid,['expected_session_revision'=>$p['session_revision'],'changes'=>[['field'=>'goal','value'=>'减脂瘦身']]],'later-edit');
rejected(409,fn()=>onboardingConfirm($db,$u,$sid,['proposal_id'=>$p['proposal_id'],'expected_profile_revision'=>$doc['revision'],'expected_session_revision'=>$new['session']['revision']],'stale-confirm'));
verify(onboardingDraft(onboardingSessionRead($db,$uid,$sid))['fields']['goal']['value']==='减脂瘦身','later draft survives stale proposal');
verify(profileFactSafety(['facts'=>['limitations'=>['value'=>'喘得很厉害，说不出整句话']]],[])['safety_blocked'],'severe symptoms blocked');
verify(!profileFactSafety(['facts'=>['limitations'=>['value'=>'没有胸痛，状态正常']]],[])['safety_blocked'],'negated symptom not positive');
$call=aiRouterRouteOne($db,$u,['capability'=>'profile.preview_change','input'=>['changes'=>[['field'=>'days_per_week','value'=>2,'unit'=>'days_per_week']]]]);
verify($call['status']==='awaiting_confirmation'&&$call['card']['card_type']==='profile_change','natural language tool produces profile preview card');
verify(profileFactsRead($db,$uid)['facts']['days_per_week']['value']===3,'model preview never commits facts');
verify(count(taskCenterProfileProposalRows($db,$uid))>0,'profile previews recover from task center');
$foreign=fixture($db);rejected(404,fn()=>profileProposalPublic($db,$foreign['id'],$call['proposal_id']));
$a=['kind'=>'coach','payload'=>['question'=>'解释','_context_source'=>['type'=>'report','job_id'=>'a','version'=>'v1']]];$b=$a;$b['payload']['_context_source']['job_id']='b';verify(aiRunStableHash($a)!==aiRunStableHash($b),'context source binds idempotency');
$pendingUser=fixture($db);$pid=$pendingUser['id'];$session=onboardingCreateSession($db,$pendingUser,['task_kind'=>'plan_import'],'import-session')['session'];$job=businessUUID();$server=businessUUID();
$db->prepare("INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,onboarding_session_id,created_at,completed_at) VALUES(?,?,?,'parse_plan',?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$pid,$job,$server,$session['id']]);
$cmd=businessUUID();$db->prepare("INSERT INTO data_operations(operation_id,user_id,actor,command_type,payload_hash,aggregate_type,aggregate_id,after_version,status,created_at) VALUES(?,?,'user','BodyWeight.CreateDirect',?,'body_weight','unrelated','1','succeeded',UTC_TIMESTAMP())")->execute([$cmd,$pid,hash('sha256','synthetic')]);
rejected(409,fn()=>onboardingPlanAdopted($db,$pendingUser,$session['id'],['expected_session_revision'=>1,'job_id'=>$job,'command_id'=>$cmd],'wrong-command'));
$adopt=['expected_session_revision'=>1,'job_id'=>$job];$pending=onboardingPlanAdopted($db,$pendingUser,$session['id'],$adopt,'same-adopt');verify($pending['status']==='pending_sync','no false adoption before sync');
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$pid,json_encode(['profile'=>[],'appliedAIJobs'=>[$job]])]);
$done=onboardingPlanAdopted($db,$pendingUser,$session['id'],$adopt,'same-adopt');verify($done['status']==='committed','pending receipt progresses under same identity');
$history=fixture($db);$hu=$history['id'];$q=$db->prepare("INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,completed_at,created_at) VALUES(?,?,?,'food',DATE_SUB(UTC_TIMESTAMP(),INTERVAL ? SECOND),DATE_SUB(UTC_TIMESTAMP(),INTERVAL ? SECOND))");for($i=0;$i<55;$i++)$q->execute([$hu,businessUUID(),businessUUID(),$i,$i]);
$cursor=null;$seen=[];do{$page=taskCenterPage($db,$hu,['limit'=>20]+($cursor?['cursor'=>$cursor]:[]));foreach($page['items'] as $v)$seen[$v['task_key']]=true;$cursor=$page['next_cursor'];}while($cursor);verify(count($seen)===55,'all history pages accessible');
verify(taskCenterStatusGroup('ai_job','succeeded','not_committed')==='awaiting_confirmation','ready plan needs confirmation');verify(taskCenterStatusGroup('command','succeeded','sync_failed')==='needs_action','sync failure not hidden');
$raw=taskCenterProfileProposalRows($db,$uid);$page=taskCenterPage($db,$uid,['group'=>'awaiting_confirmation','limit'=>1]);verify(count($page['items'])===1&&$page['items'][0]['group']==='awaiting_confirmation','filter before pagination');

// Equal-time heterogeneous sources must use exactly the same tie ordering as the cursor.
$tied=fixture($db);$tu=$tied['id'];$time=gmdate('Y-m-d H:i:s',time()-60);$tj=businessUUID();
$db->prepare("INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,completed_at,created_at) VALUES(?,?,?,'food',?,?)")->execute([$tu,$tj,businessUUID(),$time,$time]);
$ts=onboardingCreateSession($db,$tied,['task_kind'=>'explore'],'tie-session')['session']['id'];
$tp=profileChangePreview($db,$tied,['expected_profile_revision'=>0,'changes'=>[['field'=>'goal','value'=>'提升力量']]],'tie-profile')['proposal_id'];
$db->prepare('UPDATE user_onboarding_sessions SET updated_at=? WHERE id=?')->execute([$time,$ts]);$db->prepare('UPDATE user_onboarding_proposals SET updated_at=? WHERE proposal_id=?')->execute([$time,$tp]);
$cursor=null;$keys=[];do{$page=taskCenterPage($db,$tu,['limit'=>1]+($cursor?['cursor'=>$cursor]:[]));foreach($page['items'] as $item)$keys[]=$item['task_key'];$cursor=$page['next_cursor'];}while($cursor);
verify(count($keys)===3&&count(array_unique($keys))===3,'same timestamp mixed source pagination neither drops nor duplicates');
verify(taskCenterDetail($db,$pid,'ai_job',$job)['task']['business_status']==='committed','adopted plan detail matches list status');
// Extra trust fields, duplicate fields, invalid future dates and foreign dismiss are rejected.
rejected(422,fn()=>profileChangePreview($db,$u,['expected_profile_revision'=>3,'changes'=>[['field'=>'goal','value'=>'提升力量','confirmed'=>true]]],'trust-field'));
rejected(422,fn()=>profileChangePreview($db,$u,['expected_profile_revision'=>3,'changes'=>[['field'=>'goal','value'=>'提升力量'],['field'=>'goal','value'=>'减脂瘦身']]],'duplicate-field'));
rejected(422,fn()=>aiRouterRouteOne($db,$u,['capability'=>'profile.preview_change','input'=>['changes'=>[['field'=>'goal','value'=>'提升力量']],'plan_start_date'=>'2026-02-30']]));
rejected(404,fn()=>profileChangeDismiss($db,$foreign,['proposal_id'=>$call['proposal_id']],'foreign-dismiss'));
$no=profileChangeDismiss($db,$u,['proposal_id'=>$call['proposal_id']],'dismiss');verify($no['status']==='dismissed','proposal can be explicitly declined');
rejected(409,fn()=>profileChangeConfirm($db,$u,['proposal_id'=>$call['proposal_id'],'expected_profile_revision'=>3],'dismissed-confirm'));
$expired=profileChangePreview($db,$u,['expected_profile_revision'=>3,'changes'=>[['field'=>'goal','value'=>'提升力量']]],'expired-preview');
$db->prepare('UPDATE user_onboarding_proposals SET expires_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 SECOND) WHERE proposal_id=?')->execute([$expired['proposal_id']]);
rejected(410,fn()=>profileChangeConfirm($db,$u,['proposal_id'=>$expired['proposal_id'],'expected_profile_revision'=>3],'expired-confirm'));
// Inject an actual database failure after facts write: the enclosing transaction must roll back everything.
$fail=profileChangePreview($db,$u,['expected_profile_revision'=>3,'changes'=>[['field'=>'goal','value'=>'提升力量']]],'rollback-preview');
$db->exec("CREATE TRIGGER repair119_projection_failure BEFORE UPDATE ON app_states FOR EACH ROW BEGIN IF NEW.user_id=".$uid." THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='synthetic rollback probe'; END IF; END");
$thrown=false;try{profileChangeConfirm($db,$u,['proposal_id'=>$fail['proposal_id'],'expected_profile_revision'=>3],'rollback-confirm');}catch(PDOException $e){$thrown=true;}finally{$db->exec('DROP TRIGGER repair119_projection_failure');}
verify($thrown,'fault injection actually executed');verify(profileFactsRead($db,$uid)['revision']===3,'profile revision rolled back after projection failure');
verify(profileProposalPublic($db,$uid,$fail['proposal_id'])['status']==='awaiting_confirmation','proposal receipt rolled back');
// Partitioned cloud metadata updates together, with every day/job part retained byte-for-byte.
require_once __DIR__.'/../account-server/public/cloud-parts.php';
$pu=fixture($db);$puid=$pu['id'];$meta=['profile'=>['goal'=>'养成运动习惯'],'appliedAIJobs'=>['keep-job'],'theme'=>'dark'];
cloudPartPut($db,$puid,'meta',$meta);cloudPartPut($db,$puid,'d/2026-10-24',['meals'=>[],'marker'=>'keep-day']);
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,7,?,UTC_TIMESTAMP())')->execute([$puid,json_encode(cloudPartMetadata($meta))]);
$dayBefore=cloudPartGet($db,$puid,'d/2026-10-24');
$pp=profileChangePreview($db,$pu,['expected_profile_revision'=>0,'changes'=>[['field'=>'goal','value'=>'提升力量']]],'partition-preview');
profileChangeConfirm($db,$pu,['proposal_id'=>$pp['proposal_id'],'expected_profile_revision'=>0],'partition-confirm');
verify(cloudPartGet($db,$puid,'meta')['profile']['goal']==='提升力量','partitioned meta profile updated');
verify(cloudPartGet($db,$puid,'meta')['appliedAIJobs']===['keep-job']&&cloudPartGet($db,$puid,'d/2026-10-24')===$dayBefore,'partitioned jobs/days unchanged');
verify((int)$db->query('SELECT revision FROM app_states WHERE user_id='.$puid)->fetchColumn()===8,'partitioned revision increments once');
$db->prepare('DELETE FROM users WHERE id=?')->execute([$uid]);$q=$db->prepare('SELECT COUNT(*) FROM user_profile_tombstones WHERE user_id=?');$q->execute([$uid]);verify((int)$q->fetchColumn()===0,'new privacy state cascades on deletion');

// Execute the shipped CLI on a fresh schema, a repeat, then real column/key drift.
$mn='boji_build119_migration_test';$base->exec('DROP DATABASE IF EXISTS '.$mn);$base->exec('CREATE DATABASE '.$mn.' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');$md=bojiTestDatabase($mn);
$md->exec('CREATE TABLE users LIKE '.$name.'.users');$md->exec('CREATE TABLE ai_user_jobs LIKE '.$name.'.ai_user_jobs');
$md->exec('ALTER TABLE ai_user_jobs DROP COLUMN onboarding_session_id,DROP COLUMN purpose');
function migrate119(string $name,string $mode):array {
 $env=array_merge($_ENV,['BOJI_MIGRATION_DSN'=>rtrim(getenv('BOJI_TEST_DSN_BASE'),';').';dbname='.$name,'BOJI_MIGRATION_USER'=>getenv('BOJI_TEST_DB_USER')?:'root','BOJI_MIGRATION_PASSWORD'=>getenv('BOJI_TEST_DB_PASSWORD')?:'']);
 $p=proc_open([PHP_BINARY,__DIR__.'/../account-server/migrate-onboarding-v2.php',$mode],[1=>['pipe','w'],2=>['pipe','w']],$pipes,null,$env);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);return [proc_close($p),$out,$err];
}
[$exit,$out,$err]=migrate119($mn,'--check');verify($exit===2,'fresh migration check reports missing schema '.$out.$err);
[$exit,$out,$err]=migrate119($mn,'--apply');verify($exit===0,'fresh migration applies '.$out.$err);
[$exit,$out,$err]=migrate119($mn,'--check');verify($exit===0,'fresh migrated schema verified '.$out.$err);
[$exit,$out,$err]=migrate119($mn,'--apply');verify($exit===0,'repeat migration applies safely '.$out.$err);
$md->exec('ALTER TABLE user_profile_documents DROP COLUMN facts_json');
[$exit,$out,$err]=migrate119($mn,'--check');verify($exit===2&&str_contains($out,'facts_json'),'missing critical column detected '.$out.$err);
[$exit,$out,$err]=migrate119($mn,'--apply');verify($exit!==0,'apply does not falsely pass column drift '.$out.$err);
$md->exec('ALTER TABLE user_profile_documents ADD COLUMN facts_json MEDIUMTEXT NOT NULL');
$md->exec('ALTER TABLE user_onboarding_proposals DROP INDEX onboarding_proposal_user');
[$exit,$out,$err]=migrate119($mn,'--check');verify($exit===2&&str_contains($out,'onboarding_proposal_user'),'missing index detected '.$out.$err);
[$exit,$out,$err]=migrate119($mn,'--apply');verify($exit!==0,'apply does not falsely pass index drift '.$out.$err);
$md->exec('ALTER TABLE user_onboarding_proposals ADD KEY onboarding_proposal_user(user_id,status,expires_at)');
$md->exec('ALTER TABLE user_profile_tombstones DROP FOREIGN KEY profile_tombstones_user');
[$exit,$out,$err]=migrate119($mn,'--check');verify($exit===2&&str_contains($out,'profile_tombstones_user'),'missing ownership cascade detected '.$out.$err);
echo 'BUILD119_REPAIR_OK checks='.$checks."\n";
