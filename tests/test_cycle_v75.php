<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
function check75(bool $value,string $message):void { global $checks; if(!$value)throw new LogicException($message); $checks++; }
$cycle=['start'=>'2026-10-14','endDate'=>'2026-10-15','plannedDates'=>['2026-10-14'],'sourceJobID'=>'old-plan','explanationVersion'=>1];
$day=['exercises'=>[],'meals'=>[],'planCycle'=>$cycle];
cloudValidate($cycle,'cycle'); check75(true,'new interval field accepted by actual cloud schema');
$state=['days'=>['2026-10-14'=>$day,'2026-10-15'=>$day]];
check75(cloudExperienceValid($state),'short cycle accepts both remaining days');
$bad=$state;$bad['days']['2026-10-16']=$day;check75(!cloudExperienceValid($bad),'day outside interval rejected');
$bad=$state;$bad['days']['2026-10-14']['planCycle']['endDate']='2026-10-13';check75(!cloudExperienceValid($bad),'negative interval rejected');
$bad=$state;$bad['days']['2026-10-14']['planCycle']['endDate']='2026-10-21';check75(!cloudExperienceValid($bad),'over seven days rejected');
$bad=$state;$bad['days']['2026-10-14']['planCycle']['plannedDates']=['2026-10-16'];check75(!cloudExperienceValid($bad),'planned date outside short interval rejected');
$legacy=$state;foreach($legacy['days'] as &$value)unset($value['planCycle']['endDate']);unset($value);
check75(cloudExperienceValid($legacy),'old seven-day cycle remains compatible');
$new=['days'=>(object)$state['days']];$old=$new;
$new['days']->{'2026-10-14'}['planCycle']['endDate']='2026-10-14';unset($new['days']->{'2026-10-14'}['planCycle']['sourceJobID'],$new['days']->{'2026-10-14'}['planCycle']['explanationVersion']);
$merged=cloudReconcileRecords($new,$old);
check75(!isset($merged['days']->{'2026-10-14'}['planCycle']['sourceJobID']),'different interval cannot inherit stale rationale');
$roundTrip=['days'=>(object)$state['days']];unset($roundTrip['days']->{'2026-10-14'}['planCycle']['endDate']);
$merged=cloudReconcileRecords($roundTrip,['days'=>(object)$state['days']]);
check75($merged['days']->{'2026-10-14'}['planCycle']['endDate']==='2026-10-15','legacy client cannot erase truncated boundary');
echo "PASS {$checks} v75 interval and provenance checks\n";
