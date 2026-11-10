<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
function check77(bool $value,string $message):void { global $checks;if(!$value)throw new LogicException($message);$checks++; }
foreach([7200,21600] as $seconds){cloudValidate($seconds,'seconds');check77(true,'long actual seconds preserved');}
try { cloudValidate(21601,'seconds');throw new LogicException('over-limit accepted'); } catch(RuntimeException $e){check77(true,'invalid seconds rejected');}
$a='00000000-0000-4000-8000-000000000001';$b='00000000-0000-4000-8000-000000000002';
$previous=['days'=>['2026-10-15'=>['workoutSessions'=>[['id'=>$a],['id'=>$b]],'exercises'=>[]]]];
$incoming=['emptySessionDeletionVersion'=>1,'days'=>['2026-10-15'=>['workoutSessions'=>[['id'=>$a]],'exercises'=>[]]]];
check77(cloudWorkoutSessionsPreserved($previous,$incoming),'empty session deletion allowed');
$old=$incoming;unset($old['emptySessionDeletionVersion']);check77(!cloudWorkoutSessionsPreserved($previous,$old),'legacy client cannot delete sessions');
foreach(['startedAt','endedAt','savedAt','linkedDeviceWorkoutID','executionBaseline'] as $field){$protected=$previous;$protected['days']['2026-10-15']['workoutSessions'][1][$field]=1;check77(!cloudWorkoutSessionsPreserved($protected,$incoming),'protected session retained');}
$protected=$previous;$protected['days']['2026-10-15']['exercises']=[['workoutSessionID'=>$b]];check77(!cloudWorkoutSessionsPreserved($protected,$incoming),'existing action retained');
$protected=$incoming;$protected['days']['2026-10-15']['exercises']=[['workoutSessionID'=>$b]];check77(!cloudWorkoutSessionsPreserved($previous,$protected),'incoming action retained');
$empty=$incoming;$empty['days']['2026-10-15']['workoutSessions']=[];check77(!cloudWorkoutSessionsPreserved($previous,$empty),'last session protected');
$missing=$incoming;$missing['days']=[];check77(!cloudWorkoutSessionsPreserved($previous,$missing),'whole-day deletion cannot drop sessions');
echo "PASS {$checks} v77 duration and session deletion checks\n";
