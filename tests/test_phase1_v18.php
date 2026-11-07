<?php
declare(strict_types=1);
function fail(string $message, int $status=400): never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
function check(bool $value, string $name): void { global $checks; if(!$value) throw new RuntimeException($name); $checks++; }
function rejected(callable $action, string $name): void { try { $action(); } catch(RuntimeException $e) { check(true,$name); return; } throw new RuntimeException($name); }
$id='550e8400-e29b-41d4-a716-446655440000';
$day=['exercises'=>[],'meals'=>[]];
cloudValidate($day,'day');check(true,'old day accepted');
$target=['caloriesMin'=>1800,'caloriesMax'=>2100,'proteinMin'=>80,'proteinMax'=>120,'fatMin'=>40,'fatMax'=>60,'meals'=>3,'note'=>'fixture'];
$day+=['workoutStartedAt'=>812000000,'workoutEndedAt'=>812003600,'linkedDeviceWorkoutID'=>'watch-1','nutritionTarget'=>$target];
cloudValidate($day,'day');check(true,'new optional day fields accepted');
foreach(['workoutStartedAt','workoutEndedAt'] as $key) {
    $bad=$day;$bad[$key]='wrong';rejected(fn()=>cloudValidate($bad,'day'),'invalid timestamp rejected');
}
$bad=$day;$bad['nutritionTarget']['proteinMin']='unknown';rejected(fn()=>cloudValidate($bad,'day'),'invalid historical target rejected');
$exercise=['id'=>$id,'name'=>'卧推','muscle'=>'胸','sets'=>[],'deletedSetIDs'=>[$id]];
cloudValidate($exercise,'exercise');check(true,'deleted set tombstones accepted');
$bad=$exercise;$bad['deletedSetIDs']=['wrong'];rejected(fn()=>cloudValidate($bad,'exercise'),'invalid tombstones rejected');
$workout=['id'=>'watch-1','name'=>'力量训练','start'=>812000000,'end'=>812003600,'minutes'=>60,'source'=>['id'=>'watch','name'=>'Watch']];
cloudValidate($workout,'workout');check(true,'old device workout accepted');
$workout+=['activityKind'=>'strength','averageHeartRate'=>120];
cloudValidate($workout,'workout');check(true,'new device workout accepted');
$workout['averageHeartRate']='120';rejected(fn()=>cloudValidate($workout,'workout'),'invalid heart rate type rejected');
echo "PASS {$checks} cloud contract checks\n";
