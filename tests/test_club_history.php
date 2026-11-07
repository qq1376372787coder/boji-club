<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/cloud-parts.php';
$checks=0;
function checkHistory(bool $value,string $label):void { global $checks;if(!$value)throw new LogicException($label);$checks++; }
function rejectsHistory(callable $action,string $label):void { try{$action();}catch(RuntimeException){checkHistory(true,$label);return;}throw new LogicException($label); }
$profile=['nickname'=>'薄肌成员','age'=>28,'height'=>175,'weight'=>68,'goal'=>'增肌','experience'=>'新手','venue'=>'健身房','daysPerWeek'=>3,'focus'=>'全身'];
$nutrition=['caloriesMin'=>2000,'caloriesMax'=>2200,'proteinMin'=>100,'proteinMax'=>130,'fatMin'=>50,'fatMax'=>70,'meals'=>3,'note'=>'参考'];
$goal=['version'=>1,'id'=>'00000000-0000-0000-0000-000000000001','recordedAt'=>800000000,'profile'=>$profile,'nutrition'=>$nutrition];
$plan=['version'=>1,'id'=>'manual-plan-test','recordedAt'=>800000000,'source'=>'manual','title'=>'自选增肌计划','start'=>'2026-10-15','duration'=>7,
    'sessions'=>[['date'=>'2026-10-15','label'=>'胸肩','exercises'=>[['name'=>'哑铃卧推','muscle'=>'胸','sets'=>[['weight'=>10,'reps'=>12]],'library_query'=>'dumbbell bench press']]]],
    'requestedProfile'=>$profile,'adoptedProfile'=>$profile,'nutrition'=>$nutrition,'previousIDs'=>[],'scopeDates'=>['2026-10-15'],'retainedDates'=>[]];
cloudValidate($goal,'goalVersion');checkHistory(true,'production goal schema accepts snapshot');
cloudValidate($plan,'planVersion');checkHistory(true,'production plan schema accepts snapshot');
$day=['exercises'=>[],'meals'=>[],'goalVersions'=>[$goal],'planVersions'=>[$plan]];
cloudValidate($day,'day');checkHistory(true,'day payload accepts histories');
$bad=$goal;$bad['version']=2;rejectsHistory(fn()=>cloudValidate($bad,'goalVersion'),'unknown goal version rejected');
$bad=$goal;$bad['profile']['weight']=-1;rejectsHistory(fn()=>cloudValidate($bad,'goalVersion'),'invalid nested profile rejected');
$bad=$plan;$bad['duration']=8;rejectsHistory(fn()=>cloudValidate($bad,'planVersion'),'invalid duration rejected');
$bad=$plan;$bad['source']='fake';rejectsHistory(fn()=>cloudValidate($bad,'planVersion'),'unknown source rejected');
$bad=$plan;$bad['sessions'][0]['date']='not-a-date';rejectsHistory(fn()=>cloudValidate($bad,'planVersion'),'invalid snapshot dates rejected');
$old=['days'=>(object)['2026-10-15'=>$day]];
$legacy=['days'=>(object)['2026-10-15'=>['exercises'=>[],'meals'=>[]]]];
$merged=cloudReconcileRecords($legacy,$old);
checkHistory($merged['days']->{'2026-10-15'}['goalVersions']===[$goal],'legacy client retains goal history');
checkHistory($merged['days']->{'2026-10-15'}['planVersions']===[$plan],'legacy client retains plan history');
$missing=cloudReconcileRecords(['days'=>(object)[]],$old);
checkHistory(isset($missing['days']->{'2026-10-15'}['planVersions']),'omitting the anchor day cannot erase history');
cloudValidate($missing['days']->{'2026-10-15'},'day');checkHistory(true,'history-only restored day remains valid');
$changed=$old;$changed['days']=(object)['2026-10-15'=>$day];
$changed['days']->{'2026-10-15'}['planVersions'][0]['title']='覆盖旧方案';
$changed['days']->{'2026-10-15'}['goalVersions'][0]['profile']['goal']='改写过去';
$preserved=cloudReconcileRecords($changed,$old);
checkHistory($preserved['days']->{'2026-10-15'}['planVersions'][0]['title']===$plan['title'],'committed plan snapshot is immutable');
checkHistory($preserved['days']->{'2026-10-15'}['goalVersions'][0]['profile']['goal']===$profile['goal'],'committed goal snapshot is immutable');
$newPlan=$plan;$newPlan['id']='manual-plan-next';$newPlan['previousIDs']=[$plan['id']];
$newGoal=$goal;$newGoal['id']='00000000-0000-0000-0000-000000000002';$newGoal['profile']['goal']='减脂';
$changed['days']->{'2026-10-15'}['planVersions']=[$newPlan];$changed['days']->{'2026-10-15'}['goalVersions']=[$newGoal];
$combined=cloudReconcileRecords($changed,$old);
checkHistory(count($combined['days']->{'2026-10-15'}['planVersions'])===2,'new plans append instead of replacing old versions');
checkHistory(count($combined['days']->{'2026-10-15'}['goalVersions'])===2,'new goals append instead of replacing old versions');
$again=cloudReconcileRecords($combined,$old);
checkHistory($again==$combined,'retry does not duplicate versions');
$parts=cloudPartSplit(['days'=>$combined['days'],'profile'=>$profile]);
checkHistory(isset($parts['d/2026-10-15']['planVersions']),'history travels in the day partition');
checkHistory(!isset($parts['meta']['planVersions']),'history does not grow the shared metadata partition');
$other=cloudReconcileRecords(['days'=>(object)[]],['days'=>(object)[]]);
checkHistory((array)$other['days']===[],'empty account inherits no history');
echo "PASS {$checks} Club history schema, partition and legacy checks\n";
