<?php
declare(strict_types=1);
require __DIR__.'/test_club_insights.php';
$checks=0;$session='00000000-0000-4000-8000-000000000001';$exercise='00000000-0000-4000-8000-000000000002';$set='00000000-0000-4000-8000-000000000003';
$workout=$event;$workout['kind']='workout';$workout['sourceSessionID']=$session;$workout['groupID']='2026-10-15/workout/'.$session;
$workout['action']=['type'=>'workout_summary','date'=>'2026-10-15','sessionID'=>$session];
cloudValidate($workout,'insightEvent');checkInsights(true,'session summary event and typed destination accepted');
$state=['days'=>(object)['2026-10-15'=>['exercises'=>[],'meals'=>[],'insightEvents'=>[$workout]]]];
checkInsights(cloudInsightsValid($state),'session-specific group valid');
$bad=$workout;unset($bad['sourceSessionID']);checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>['insightEvents'=>[$bad]]]]),'summary requires source session');
$bad=$workout;$bad['action']['sessionID']=$exercise;checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>['insightEvents'=>[$bad]]]]),'action cannot open a different session');
$bad=$workout;$bad['action']['date']='2026-10-14';checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>['insightEvents'=>[$bad]]]]),'action cannot open a different date');
foreach(['read'=>'reading','unread'=>'reading','archive'=>'archive','unarchive'=>'archive'] as $action=>$category) {
    $record=$feedback;$record['kind']='workout';$record['action']=$action;$record['scope']='workout/'.$category.'/'.$record['eventID'];
    cloudValidate($record,'insightFeedback');checkInsights(cloudInsightsValid(['days'=>['2026-10-15'=>['insightFeedback'=>[$record]]]]),'read and archive independent scope '.$action);
}
$base=['version'=>1,'capturedAt'=>800000000,'restSeconds'=>90,'sets'=>[['id'=>$set,'exerciseID'=>$exercise,'unit'=>'reps','targetReps'=>12,'targetWeight'=>22.5]]];
cloudValidate($base,'executionBaseline');checkInsights(cloudExecutionTargetsValid(['days'=>[['workoutSessions'=>[['executionBaseline'=>$base]]]]]),'new execution targets accepted');
foreach([['targetWeight',-1],['targetWeight',2001],['targetReps',0],['targetReps',1001]] as [$key,$value]) {
 $bad=$base;$bad['sets'][0][$key]=$value;checkInsights(!cloudExecutionTargetsValid(['days'=>[['workoutSessions'=>[['executionBaseline'=>$bad]]]]]),'invalid captured target rejected');
}
$bad=$base;$bad['restSeconds']=3601;checkInsights(!cloudExecutionTargetsValid(['days'=>[['workoutSessions'=>[['executionBaseline'=>$bad]]]]]),'invalid captured rest rejected');
$bad=$base;$bad['sets'][0]['unit']='time';$bad['sets'][0]['targetSeconds']=30;checkInsights(!cloudExecutionTargetsValid(['days'=>[['workoutSessions'=>[['executionBaseline'=>$bad]]]]]),'timed target rejects invented load');
$legacy=$base;unset($legacy['restSeconds'],$legacy['sets'][0]['targetReps'],$legacy['sets'][0]['targetWeight']);checkInsights(cloudExecutionTargetsValid(['days'=>[['workoutSessions'=>[['executionBaseline'=>$legacy]]]]]),'legacy targets stay compatible');
$old=['days'=>(object)['2026-10-15'=>['exercises'=>[],'meals'=>[],'insightEvents'=>[$workout]]]];
$without=cloudReconcileRecords(['days'=>(object)[]],$old);checkInsights($without['days']->{'2026-10-15'}['insightEvents'][0]['action']===$workout['action'],'old client cannot erase typed summary action');
echo "PASS {$checks} session insight and execution target checks\n";
