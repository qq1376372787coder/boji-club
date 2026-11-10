<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$passed=0;
foreach([7,14,28] as $length) { cloudValidate($length,'planDuration');$passed++; }
foreach([0,8,21,29,999,14.0,'14',true] as $bad) {
    try { cloudValidate($bad,'planDuration');throw new LogicException('Invalid plan duration accepted'); }
    catch(RuntimeException) { $passed++; }
}
$day=['exercises'=>[],'meals'=>[],'movedFromDate'=>'2026-10-15','plannedMoveDestination'=>'2026-10-14'];
cloudValidate($day,'day');$passed++;
$result=['kind'=>'plan','notes'=>[],'plan_days'=>28,'sessions'=>[]];cloudValidate($result,'result');$passed++;
$a='00000000-0000-4000-8000-000000000001';$b='00000000-0000-4000-8000-000000000002';
$exercise=['id'=>$a,'name'=>'深蹲','muscle'=>'大腿','sets'=>[['id'=>$a,'weight'=>0,'reps'=>10,'completed'=>false]],'workoutSessionID'=>$a];
$previous=['days'=>['2026-10-15'=>['exercises'=>[$exercise],'meals'=>[],'workoutSessions'=>[['id'=>$a]],'activeWorkoutSessionID'=>$a]]];
$copy=$exercise;$copy['id']=$b;$copy['sets'][0]['id']=$b;$copy['workoutSessionID']=$b;
$moved=['days'=>['2026-10-15'=>['exercises'=>[],'meals'=>[],'workoutSessions'=>[['id'=>$a]],'activeWorkoutSessionID'=>$a,'plannedMoveDestination'=>'2026-10-14'],'2026-10-14'=>['exercises'=>[$copy],'meals'=>[],'workoutSessions'=>[['id'=>$b]],'activeWorkoutSessionID'=>$b,'movedFromDate'=>'2026-10-15']]];
if(!cloudWorkoutSessionsPreserved($previous,$moved)||!cloudWorkoutSessionsValid($moved))throw new LogicException('Advancing a plan must retain source session metadata and keep destination unconfirmed');$passed++;
foreach($moved['days'] as $item){cloudValidate($item,'day');$passed++;}
echo json_encode(['passed'=>$passed],JSON_THROW_ON_ERROR)."\n";
