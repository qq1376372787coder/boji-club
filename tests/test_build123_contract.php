<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never {throw new RuntimeException($message);}
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/profile-facts.php';
$id='11111111-1111-1111-1111-111111111111';
$session=['id'=>$id,'startedAt'=>100,'endedAt'=>300,'savedAt'=>301,'pauseIntervals'=>[['start'=>120,'end'=>150]]];
cloudValidate($session,'workoutSession');
$state=['days'=>['2020-01-01'=>['activeWorkoutSessionID'=>$id,'workoutStartedAt'=>100,'workoutEndedAt'=>300,'workoutSavedAt'=>301,'workoutSessions'=>[$session],'exercises'=>[['workoutSessionID'=>$id,'sets'=>[['completed'=>true,'reps'=>8]]]]]]];
if(!cloudWorkoutSessionsValid($state))throw new RuntimeException('valid pauses rejected');
$bad=$state;$bad['days']['2020-01-01']['workoutSessions'][0]['pauseIntervals'][]=['start'=>140,'end'=>180];
if(cloudWorkoutSessionsValid($bad))throw new RuntimeException('overlap accepted');
$bad=$state;unset($bad['days']['2020-01-01']['workoutSessions'][0]['pauseIntervals'][0]['end']);
if(cloudWorkoutSessionsValid($bad))throw new RuntimeException('open pause accepted on saved workout');
if((profileFactFieldDefinitions()['nickname']['maxLength']??0)!==40)throw new RuntimeException('nickname schema');
echo "PASS Build123 pause schema, semantic boundaries, nickname fact definition\n";
