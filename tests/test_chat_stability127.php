<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/chat-input.php';
function pass127(bool $condition,string $name):void{if(!$condition)throw new RuntimeException($name);echo "PASS $name\n";}
function reject127(callable $f,string $name):void{try{$f();}catch(RuntimeException $e){pass127(true,$name);return;}throw new RuntimeException('accepted '.$name);}
$id='11111111-1111-1111-1111-111111111111';
$session=['id'=>$id,'startedAt'=>814100000.1234567,'endedAt'=>814100600.1234567,'savedAt'=>814100600.1234567];
$state=['days'=>['2026-10-25'=>['workoutSessions'=>[$session],'exercises'=>[['id'=>'e1','workoutSessionID'=>$id,'sets'=>[['id'=>'s1','weight'=>12.5,'reps'=>8,'completed'=>true]]]]]]];
$request=['date'=>'2026-10-25','payload'=>['purpose'=>'workout','source_session'=>$id,'days'=>[['date'=>'2026-10-25','payload'=>['workout_sessions'=>[$session],'exercises'=>[['exercise_id'=>'e1','session_id'=>$id,'sets'=>[['id'=>'s1','weight'=>12.5,'reps'=>8,'completed'=>true]]]]]]]]];
chatWorkoutValidateState($state,$request);pass127(true,'identical confirmed source');
$small=$request;$small['payload']['days'][0]['payload']['workout_sessions'][0]['savedAt']+=0.00000011920928955;
chatWorkoutValidateState($state,$small);pass127(true,'sub microsecond timestamp discrepancy accepted');
$large=$request;$large['payload']['days'][0]['payload']['workout_sessions'][0]['endedAt']+=2;
reject127(fn()=>chatWorkoutValidateState($state,$large),'actual end time change rejected');
$bad=$request;$bad['payload']['days'][0]['payload']['exercises'][0]['sets'][0]['reps']=9;
reject127(fn()=>chatWorkoutValidateState($state,$bad),'actual set correction rejected');
$bad=$request;$bad['payload']['days'][0]['payload']['exercises'][0]['session_id']='22222222-2222-2222-2222-222222222222';
reject127(fn()=>chatWorkoutValidateState($state,$bad),'different session rejected');
reject127(fn()=>chatWorkoutValidateState([],$request),'unsynced source rejected');
pass127(chatSameTimestamp127(null,null),'both unrecorded times match');
pass127(!chatSameTimestamp127(null,0),'missing time is not zero');
pass127(!chatSameTimestamp127(INF,INF),'nonfinite time rejected');
pass127(!chatSameTimestamp127('invalid',10),'invalid time rejected');
pass127(chatSamePauses127([['start'=>100.1234567,'end'=>120.1234567]],[['start'=>100.1234568,'end'=>120.1234568]]),'pause wire precision accepted');
pass127(!chatSamePauses127([['start'=>100,'end'=>120]],[['start'=>100,'end'=>121]]),'actual pause correction rejected');
pass127(!chatSamePauses127([['start'=>100,'end'=>null]],[['start'=>100,'end'=>120]]),'open and closed pause differ');
pass127(!chatSamePauses127([], [['start'=>100,'end'=>120]]),'pause count mismatch rejected');
echo "14 CHECKS PASSED\n";
