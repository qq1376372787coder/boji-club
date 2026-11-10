<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/cloud-parts.php';
$checks=0;
function checkInsights(bool $value,string $label):void { global $checks;if(!$value)throw new LogicException($label);$checks++; }
function rejectInsights(callable $action,string $label):void {try{$action();}catch(RuntimeException){checkInsights(true,$label);return;}throw new LogicException($label);}
$a='insight/'.str_repeat('a',64);$b='insight/'.str_repeat('b',64);$c='insight/'.str_repeat('c',64);
$event=['version'=>1,'id'=>$a,'date'=>'2026-10-15','groupID'=>'2026-10-15/training','kind'=>'training','recordedAt'=>800000000,'previousIDs'=>[],
    'state'=>'active','evidenceDigest'=>str_repeat('d',64),'title'=>'训练已保存','detail'=>'已确认完成3组','evidence'=>'依据已保存组次','priority'=>100,'isTodayReminder'=>false];
$feedback=['version'=>1,'id'=>'feedback/'.str_repeat('a',64),'date'=>'2026-10-15','recordedAt'=>800000001,'kind'=>'training',
    'action'=>'helpful','eventID'=>$a,'scope'=>'training/helpful/'.$a,'previousIDs'=>[]];
$day=['exercises'=>[],'meals'=>[],'insightEvents'=>[$event],'insightFeedback'=>[$feedback]];
cloudValidate($event,'insightEvent');checkInsights(true,'event DTO accepted');
cloudValidate($feedback,'insightFeedback');checkInsights(true,'feedback DTO accepted');
cloudValidate($day,'day');checkInsights(true,'day DTO includes ledger');
$state=['days'=>(object)['2026-10-15'=>$day]];
checkInsights(cloudInsightsValid($state),'valid causal graph accepted');
checkInsights(cloudExperienceValid($state),'production experience validation checks ledger');
$bad=$event;$bad['kind']='unknown';rejectInsights(fn()=>cloudValidate($bad,'insightEvent'),'unknown generated kind rejected');
$bad=$event;$bad['evidenceDigest']='not-hash';rejectInsights(fn()=>cloudValidate($bad,'insightEvent'),'malformed evidence fingerprint rejected');
$bad=$event;$bad['id']='not-id';rejectInsights(fn()=>cloudValidate($bad,'insightEvent'),'malformed event ID rejected');
$bad=$event;$bad['state']='unknown';rejectInsights(fn()=>cloudValidate($bad,'insightEvent'),'unknown new event state rejected');
$bad=$feedback;$bad['action']='unknown';rejectInsights(fn()=>cloudValidate($bad,'insightFeedback'),'unknown new preference rejected');
$bad=$state;$bad['days']=(object)['2026-10-16'=>$day];checkInsights(!cloudInsightsValid($bad),'event cannot move to a different day');
$bad=$day;$bad['insightEvents'][0]['groupID']='2026-10-15/body';checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'group must match its evidence date and kind');
$bad=$day;$bad['insightEvents'][0]['previousIDs']=[$a];checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'self cycle rejected');
$one=$event;$one['previousIDs']=[$b];$two=$event;$two['id']=$b;$two['previousIDs']=[$a];
$bad=$day;$bad['insightEvents']=[$one,$two];checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'two-node cycle rejected without recursion');
$bad=$day;$bad['insightEvents'][0]['previousIDs']=[$b,$b];checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'duplicate parents rejected');
$bad=$day;$bad['insightEvents'][0]['previousIDs']=[$b];checkInsights(cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'partial restore can retain an absent external reference');
$bad=$day;unset($bad['insightFeedback'][0]['eventID']);checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'helpful feedback requires its event');
$bad=$day;$bad['insightFeedback'][0]['scope']='nutrition/preference';checkInsights(!cloudInsightsValid(['days'=>['2026-10-15'=>$bad]]),'wrong feedback scope rejected');
$old=$state;$legacy=['days'=>(object)['2026-10-15'=>['exercises'=>[],'meals'=>[]]]];
$preserved=cloudReconcileRecords($legacy,$old);
checkInsights($preserved['days']->{'2026-10-15'}['insightEvents']===[$event],'old client preserves ledger');
checkInsights($preserved['days']->{'2026-10-15'}['insightFeedback']===[$feedback],'old client preserves preferences');
$missing=cloudReconcileRecords(['days'=>(object)[]],$old);
checkInsights(isset($missing['days']->{'2026-10-15'}['insightEvents']),'missing day retains ledger');
$changed=$day;$changed['insightEvents'][0]['detail']='改写原结论';$changed['insightFeedback'][0]['action']='reduce';
$immutable=cloudReconcileRecords(['days'=>['2026-10-15'=>$changed]],$old);
checkInsights($immutable['days']->{'2026-10-15'}['insightEvents'][0]['detail']===$event['detail'],'committed observation cannot be rewritten');
checkInsights($immutable['days']->{'2026-10-15'}['insightFeedback'][0]['action']==='helpful','committed preference cannot be rewritten');
$next=$event;$next['id']=$b;$next['previousIDs']=[$a];$next['recordedAt']=800000010;$next['detail']='已更新重量';
$incoming=$day;$incoming['insightEvents']=[$next];
$merged=cloudReconcileRecords(['days'=>['2026-10-15'=>$incoming]],$old);
checkInsights(count($merged['days']->{'2026-10-15'}['insightEvents'])===2,'new evidence appends an observation');
checkInsights(cloudInsightsValid($merged),'new linked observation remains valid');
$another=$event;$another['id']=$c;$another['previousIDs']=[$a];$another['detail']='另一设备更新了次数';
$concurrent=$day;$concurrent['insightEvents']=[$another];
$merged=cloudReconcileRecords(['days'=>['2026-10-15'=>$concurrent]],$merged);
checkInsights(count($merged['days']->{'2026-10-15'}['insightEvents'])===3,'concurrent evidence remains separate');
checkInsights(cloudInsightsValid($merged),'concurrent branches are valid');
checkInsights(cloudReconcileRecords($merged,$old)==$merged,'retry does not duplicate observations');
$parts=cloudPartSplit($merged);
checkInsights(isset($parts['d/2026-10-15']['insightEvents']) && !isset($parts['meta']['insightEvents']),'observations use day partitions');
$empty=cloudReconcileRecords(['days'=>(object)[]],['days'=>(object)[]]);checkInsights((array)$empty['days']===[],'empty account inherits no ledger');
echo "PASS {$checks} insight schema, causal graph and compatibility checks\n";
