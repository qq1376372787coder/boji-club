<?php
declare(strict_types=1);
function fail(string $message,int $status=400): never { throw new RuntimeException($message,$status); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=[];
function fb63(bool $ok,string $name): void { global $checks;if(!$ok)throw new RuntimeException($name);$checks[]=$name; }
$id='00000000-0000-4000-8000-000000000001';$setID='00000000-0000-4000-8000-000000000002';$exerciseID='00000000-0000-4000-8000-000000000003';
$baseline=['version'=>1,'capturedAt'=>800000000,'sets'=>[['id'=>$setID,'exerciseID'=>$exerciseID,'unit'=>'time','targetSeconds'=>600]]];
$feedback=['version'=>1,'status'=>'green','reason'=>'target_completed','evidence'=>['开始时的目标已经登记完成。'],'next_step'=>'保持稳定执行。'];
cloudValidate($baseline,'executionBaseline');cloudValidate($feedback,'trainingFeedback');fb63(true,'new contracts accepted');
$day=['exercises'=>[['id'=>$exerciseID,'name'=>'跑步','muscle'=>'心肺耐力','sets'=>[['id'=>$setID,'weight'=>0,'reps'=>0,'durationSeconds'=>600,'completed'=>true]],'workoutSessionID'=>$id]],'meals'=>[],'workoutSessions'=>[['id'=>$id,'startedAt'=>800000000,'savedAt'=>800001000,'executionBaseline'=>$baseline]],'activeWorkoutSessionID'=>$id,'workoutStartedAt'=>800000000,'workoutSavedAt'=>800001000];
cloudValidate($day,'day');fb63(cloudWorkoutSessionsValid(['days'=>['2026-10-13'=>$day]]),'snapshot day validates with mirror fields');
$legacy=$day;unset($legacy['workoutSessions'][0]['executionBaseline']);
$old=['days'=>['2026-10-13'=>$day],'aiJobs'=>[]];$incoming=['days'=>['2026-10-13'=>$legacy],'aiJobs'=>[]];
$saved=cloudPreservePlanExplanations($incoming,$old);
fb63($saved['days']->{'2026-10-13'}['workoutSessions'][0]['executionBaseline']===$baseline,'old client cannot drop snapshot');
$edited=$incoming;$edited['days']['2026-10-13']['workoutSessions'][0]['executionBaseline']=$baseline;$edited['days']['2026-10-13']['workoutSessions'][0]['executionBaseline']['sets'][0]['targetSeconds']=60;
$saved=cloudPreservePlanExplanations($edited,$old);
fb63($saved['days']->{'2026-10-13'}['workoutSessions'][0]['executionBaseline']===$baseline,'committed snapshot cannot be shortened');
$report=['kind'=>'report','notes'=>[],'summary'=>'结论','training'=>'训练','nutrition'=>'饮食','recovery'=>'恢复','training_feedback'=>$feedback];cloudValidate($report,'result');
$prior=['days'=>[],'aiJobs'=>[['id'=>'feedback-fixture','result'=>$report]]];$missing=$report;unset($missing['training_feedback']);
$saved=cloudPreservePlanExplanations(['days'=>[],'aiJobs'=>[['id'=>'feedback-fixture','result'=>$missing]]],$prior);
fb63($saved['aiJobs'][0]['result']['training_feedback']===$feedback,'old client preserves report feedback');
$tampered=$report;$tampered['training_feedback']['status']='red';
$saved=cloudPreservePlanExplanations(['days'=>[],'aiJobs'=>[['id'=>'feedback-fixture','result'=>$tampered]]],$prior);
fb63($saved['aiJobs'][0]['result']['training_feedback']===$feedback,'same report retains original status');
$otherDay=$legacy;$otherDay['workoutSessions'][0]['id']='00000000-0000-4000-8000-000000000004';
$saved=cloudPreservePlanExplanations(['days'=>['2026-10-14'=>$otherDay],'aiJobs'=>[]],$old);
fb63(!isset($saved['days']->{'2026-10-14'}['workoutSessions'][0]['executionBaseline']),'different day and session never inherits old target');
$bad=$day;$bad['workoutSessions'][0]['executionBaseline']['sets'][]=$baseline['sets'][0];fb63(!cloudWorkoutSessionsValid(['days'=>['2026-10-13'=>$bad]]),'duplicate target rejected');
$bad=$day;$bad['workoutSessions'][0]['executionBaseline']['sets'][0]['targetSeconds']=0;fb63(!cloudWorkoutSessionsValid(['days'=>['2026-10-13'=>$bad]]),'zero duration target rejected');
$bad=$day;$bad['workoutSessions'][0]['executionBaseline']['capturedAt']=800002000;fb63(!cloudWorkoutSessionsValid(['days'=>['2026-10-13'=>$bad]]),'capture after confirmation rejected');
foreach(['purple',true,100] as $status){$bad=$feedback;$bad['status']=$status;try{cloudValidate($bad,'trainingFeedback');fb63(false,'invalid status accepted');}catch(RuntimeException $e){fb63($e->getCode()===400,'invalid status rejected');}}
echo json_encode(['passed'=>true,'checks'=>count($checks),'labels'=>$checks],JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
