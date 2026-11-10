<?php
declare(strict_types=1);
require_once getenv('BOJI_TEST_CLOUD_VALIDATION') ?: __DIR__.'/../../account-server/public/cloud-validation.php';
function fail(string $message,int $code=400): never { throw new RuntimeException($message); }
function check(bool $value,string $label): void { if(!$value)throw new RuntimeException($label); echo "PLAN PASS $label\n"; }
$id='11111111-1111-1111-1111-111111111111';$other='22222222-2222-2222-2222-222222222222';
$action=['id'=>'33333333-3333-3333-3333-333333333333','planID'=>'manual-plan-test','kind'=>'ended','createdAt'=>800000000,'exerciseIDs'=>[$id],'clearsCycle'=>true];
cloudValidate($action,'planLifecycleAction');
$day=['exercises'=>[['id'=>$id,'sets'=>[]],['id'=>$other,'sets'=>[]]],'meals'=>[['id'=>'keep']],'planActions'=>[$action],'planCycle'=>['start'=>'2026-10-21','sourceJobID'=>'manual-plan-test','plannedDates'=>['2026-10-21']]];
$next=cloudApplyPlanActions($day);
check(count($next['exercises'])===1 && $next['exercises'][0]['id']===$other,'remove only targeted pending exercise');
check(count($next['meals'])===1,'meal untouched');
$started=$day;$started['workoutStartedAt']=800000001;
check(cloudApplyPlanActions($started)===$started,'concurrent start protected');
$completed=$day;$completed['exercises'][0]['sets']=[['completed'=>true]];
check(cloudApplyPlanActions($completed)===$completed,'concurrent completed set protected');
$replacement=$day;$replacement['exercises']=[['id'=>$other,'sets'=>[]]];$replacement['planCycle']['sourceJobID']='new-plan';
check(isset(cloudApplyPlanActions($replacement)['planCycle']),'new rest cycle retained');
$empty=$day;$empty['exercises']=[['id'=>$id,'sets'=>[]]];
check(!isset(cloudApplyPlanActions($empty)['planCycle']),'owned cancelled cycle removed');
$previous=['days'=>['2026-10-21'=>$day]];$legacy=['days'=>['2026-10-21'=>['exercises'=>[['id'=>$id,'sets'=>[]]],'meals'=>[]]]];
$preserved=cloudPreserveHistory($legacy,$previous);
check(count(((array)$preserved['days'])['2026-10-21']['planActions'])===1,'old-client upload retains cancellation');
$clean=cloudApplyPlanActions(((array)$preserved['days'])['2026-10-21']);
check($clean['exercises']===[],'old-client upload cannot resurrect cancelled plan');
$draft=['id'=>$id,'singleDay'=>true];$meta=cloudPreserveV2Meta(['syncSchemaVersion'=>2,'planDrafts'=>[['id'=>$id]]],['planDrafts'=>[$draft]]);
check($meta['planDrafts'][0]['singleDay']===true,'old client preserves single-day intent');
$restored=cloudRestoreCancelledExecution(['exercises'=>[],'meals'=>[],'planActions'=>[$action]],$started);
check(count($restored['exercises'])===1 && isset($restored['workoutStartedAt']),'cancel upload restores concurrently started server exercise');
echo "PLAN_LIFECYCLE_OK 10 checks\n";
