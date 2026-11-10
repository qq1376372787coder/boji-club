<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never {throw new RuntimeException($message);}
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
function check49(bool $value,string $label):void {global $checks;if(!$value)throw new RuntimeException($label);$checks++;echo 'PASS '.$label.PHP_EOL;}
function reject49(callable $fn,string $label):void {try{$fn();}catch(RuntimeException){check49(true,$label);return;}throw new RuntimeException($label);}
$explanation=['version'=>1,'summary'=>['目标','日期','器械'],'sections'=>[['id'=>'body','title'=>'身体资料','basis'=>'生成时填写','detail'=>'资料局限']],'sessions'=>[['date'=>'2026-10-11','purpose'=>'本堂课的实际内容']]];
$sessions=[['date'=>'2026-10-11','label'=>'基础训练','exercises'=>[['name'=>'俯卧撑','muscle'=>'胸','sets'=>[['reps'=>10]],'library_id'=>'fixture']]]];
$result=['kind'=>'plan','notes'=>[],'title'=>'专属计划','sessions'=>$sessions,'explanation'=>$explanation];
cloudValidate($result,'result');check49(true,'new plan explanation validates');
$legacy=$result;unset($legacy['explanation']);cloudValidate($legacy,'result');check49(true,'legacy plan has no required explanation');
foreach(['version'=>2,'summary'=>'bad','sessions'=>[['date'=>'2026-02-30','purpose'=>'bad']],'sections'=>[['id'=>'body','title'=>'body','detail'=>'missing basis']]] as $key=>$value){$bad=$result;$bad['explanation'][$key]=$value;reject49(fn()=>cloudValidate($bad,'result'),'reject malformed '.$key);}
$cycle=['start'=>'2026-10-11','plannedDates'=>['2026-10-11'],'sourceJobID'=>'plan-1','explanationVersion'=>1];
cloudValidate($cycle,'cycle');check49(true,'source marker validates');
$plain=$cycle;unset($plain['sourceJobID'],$plain['explanationVersion']);cloudValidate($plain,'cycle');check49(true,'legacy cycle validates');
$day=['exercises'=>[],'meals'=>[],'planCycle'=>$cycle];
$job=['id'=>'plan-1','digest'=>'fixture','request'=>['id'=>'plan-1','kind'=>'generate_plan','date'=>'2026-10-11','payload'=>[]],'status'=>'succeeded','result'=>$result,'created'=>0,'consumed'=>true];
cloudValidate($job,'job');check49(true,'retained job and snapshot contract validates');
$old=['days'=>(object)['2026-10-11'=>$day],'aiJobs'=>[$job]];
$oldClient=$old;$oldClient['days']=(object)['2026-10-11'=>['exercises'=>[],'meals'=>[],'planCycle'=>$plain]];unset($oldClient['aiJobs'][0]['result']['explanation']);
$merged=cloudReconcileRecords($oldClient,$old);
check49($merged['days']->{'2026-10-11'}['planCycle']===$cycle,'old client does not drop cycle source');
check49($merged['aiJobs'][0]['result']['explanation']===$explanation,'old client does not drop unchanged plan reasons');
$newClient=$oldClient;$newClient['days']->{'2026-10-11'}['planCycle']['explanationVersion']=1;
$merged=cloudReconcileRecords($newClient,$old);
check49(!isset($merged['days']->{'2026-10-11'}['planCycle']['sourceJobID']),'new client can explicitly clear source');
$changed=$oldClient;$changed['aiJobs'][0]['result']['sessions'][0]['exercises'][0]['sets'][0]['reps']=12;
$merged=cloudReconcileRecords($changed,$old);
check49(!isset($merged['aiJobs'][0]['result']['explanation']),'different prescription does not inherit reasons');
$other=$oldClient;$other['days']->{'2026-10-11'}['planCycle']['start']='2026-10-12';
$merged=cloudReconcileRecords($other,$old);
check49(!isset($merged['days']->{'2026-10-11'}['planCycle']['sourceJobID']),'different cycle does not inherit source');
$deleted=$oldClient;$deleted['aiJobs']=[];$deleted['days']=(object)[];$deleted['deletedAIJobIDs']=['plan-1'];
$merged=cloudReconcileRecords($deleted,$old);
check49($merged['aiJobs']===[] && (array)$merged['days']===[],'deleted records are not resurrected');
$merged=cloudReconcileRecords($old,['days'=>(object)[]]);
check49($merged['aiJobs'][0]['result']['explanation']===$explanation,'first sync retains explanation');
echo 'ALL '.$checks.' PLAN EXPLANATION PHP CHECKS PASSED; NO DATABASE ACCESSED'.PHP_EOL;
