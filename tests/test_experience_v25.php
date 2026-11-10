<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/club-progress.php';
$checks=0;
function check(bool $value,string $name):void { global $checks; if(!$value) throw new LogicException($name); $checks++; }
$a='00000000-0000-4000-8000-000000000001';$b='00000000-0000-4000-8000-000000000002';$date='2026-10-04';
$set=['id'=>$a,'weight'=>20,'reps'=>10,'completed'=>true];
$exercise=['id'=>$a,'name'=>'卧推','muscle'=>'胸','sets'=>[$set],'workoutSessionID'=>$a];
$day=['exercises'=>[$exercise],'meals'=>[],'workoutSessions'=>[['id'=>$a,'startedAt'=>800000000,'endedAt'=>800003600,'savedAt'=>800003601],['id'=>$b]],'activeWorkoutSessionID'=>$b];
$state=['days'=>[$date=>$day]];
check(cloudWorkoutSessionsValid(['days'=>[$date=>['exercises'=>[],'meals'=>[]]]]),'old records stay valid');
cloudValidate($day,'day');check(cloudWorkoutSessionsValid($state),'new record schema and metadata accepted');
$index=clubBuildProgressIndex($state,'2026-10-05',fn()=>true);check(clubProgressRange($index,$date,$date)['training_days']===1,'unfinished second session retains confirmed day');
$two=$state;$two['days'][$date]['exercises'][]=$exercise;$two['days'][$date]['exercises'][1]['id']=$b;$two['days'][$date]['exercises'][1]['workoutSessionID']=$b;
$two['days'][$date]['workoutSessions'][1]['savedAt']=800013601;$two['days'][$date]['workoutSavedAt']=800013601;
check(cloudWorkoutSessionsValid($two),'two confirmed sessions valid');
check(clubProgressRange(clubBuildProgressIndex($two,'2026-10-05',fn()=>true),$date,$date)['training_days']===1,'two sessions count one training day');
check(clubProgressRange(clubBuildProgressIndex($two,'2026-10-03',fn()=>true),$date,$date)['training_days']===0,'future day excluded');
$bad=$state;$bad['days'][$date]['workoutSessions'][1]['id']=$a;check(!cloudWorkoutSessionsValid($bad),'duplicate metadata rejected');
$bad=$state;$bad['days'][$date]['activeWorkoutSessionID']='00000000-0000-4000-8000-000000000099';check(!cloudWorkoutSessionsValid($bad),'unknown active ID rejected');
$bad=$state;unset($bad['days'][$date]['exercises'][0]['workoutSessionID']);check(!cloudWorkoutSessionsValid($bad),'unassigned exercise rejected');
$bad=$state;$bad['days'][$date]['workoutSessions'][1]['savedAt']=800013601;$bad['days'][$date]['workoutSavedAt']=800013601;check(!cloudWorkoutSessionsValid($bad),'empty confirmed session rejected');
$bad=$state;$bad['days'][$date]['workoutSessions'][0]['endedAt']=1;check(!cloudWorkoutSessionsValid($bad),'backwards time rejected');
$bad=$two;$bad['days'][$date]['workoutSavedAt']=1;check(!cloudWorkoutSessionsValid($bad),'inconsistent active mirror rejected');
$linked=$two;$linked['days'][$date]['health']=['workouts'=>[['id'=>'watch']]];$linked['days'][$date]['workoutSessions'][0]['linkedDeviceWorkoutID']='watch';
check(cloudWorkoutSessionsValid($linked),'first session link retained');
$bad=$linked;$bad['days'][$date]['workoutSessions'][1]['linkedDeviceWorkoutID']='watch';$bad['days'][$date]['linkedDeviceWorkoutID']='watch';check(!cloudWorkoutSessionsValid($bad),'one watch record cannot attach twice');
$bad=$linked;unset($bad['days'][$date]['health']);check(!cloudWorkoutSessionsValid($bad),'link requires shared device record');
check(cloudWorkoutSessionsPreserved($state,$two),'normal updates preserve session IDs');
check(!cloudWorkoutSessionsPreserved($state,['days'=>[$date=>['exercises'=>[],'meals'=>[]]]]),'old client cannot drop metadata');
check(!cloudWorkoutSessionsPreserved($state,['days'=>[]]),'old client cannot remove session day');
$bad=$state;$bad['days'][$date]['exercises'][0]['sets'][0]['reps']=0;unset($bad['days'][$date]['workoutSessions'][0]['savedAt']);
check(clubProgressRange(clubBuildProgressIndex($bad,'2026-10-05',fn()=>true),$date,$date)['training_days']===0,'invalid groups do not count');
check(!cloudWorkoutSessionsPreserved($state,['days'=>(object)[$date=>['exercises'=>[],'meals'=>[]]]]),'converted JSON dictionaries reject old overwrite with no exception');
echo "PASS {$checks} v25 PHP session and reward checks\n";
