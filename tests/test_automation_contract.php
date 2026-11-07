<?php
declare(strict_types=1);
require __DIR__.'/test_club_history.php';
require __DIR__.'/../account-server/public/automation.php';
$checks=0;
$prefs=['version'=>1,'enabled'=>true,'daily'=>true,'weekly'=>true,'workout'=>true,'partial'=>false,'hour'=>21,'zone'=>'Asia/Shanghai','enabled_at'=>time()-10];
checkHistory(clubAutomationPreferences($prefs)===$prefs,'explicit automation opt-in preserves flags');
foreach([['hour'=>24],['zone'=>'invalid/zone'],['weekly'=>1],['enabled_at'=>time()+3600],['enabled'=>true,'daily'=>false,'weekly'=>false,'workout'=>false]] as $bad) {
    try{clubAutomationPreferences(array_replace($prefs,$bad));throw new LogicException('invalid settings accepted');}catch(InvalidArgumentException){checkHistory(true,'invalid automation setting rejected');}
}
$id='11111111-1111-1111-1111-111111111111';
$exercise=['id'=>$id,'name'=>'卧推','muscle'=>'胸','sets'=>[['id'=>$id,'weight'=>20,'reps'=>10,'completed'=>false]],'restSeconds'=>90];
cloudValidate($exercise,'exercise');checkHistory(true,'rest override accepted');
$previous=['profile'=>$profile,'days'=>['2026-10-15'=>['exercises'=>[$exercise],'meals'=>[]]]];
$incoming=$previous;unset($incoming['days']['2026-10-15']['exercises'][0]['restSeconds']);
$merged=cloudPreserveLegacyExperience($incoming,$previous);
checkHistory($merged['days']['2026-10-15']['exercises'][0]['restSeconds']===90,'old client omission cannot erase rest override');
$incoming['days']['2026-10-15']['exercises'][0]['restSeconds']=null;
$merged=cloudPreserveLegacyExperience($incoming,$previous);
checkHistory(array_key_exists('restSeconds',$merged['days']['2026-10-15']['exercises'][0])&&$merged['days']['2026-10-15']['exercises'][0]['restSeconds']===null,'explicit reset returns to default rest');
$bad=$exercise;$bad['restSeconds']=3601;rejectsHistory(fn()=>cloudValidate($bad,'exercise'),'out-of-range rest rejected');
$proposal=['version'=>1,'changes'=>[['date'=>'2026-10-16','exercise'=>0,'set'=>0,'field'=>'reps','value'=>11,'reason'=>'依据已确认记录核对目标']],'baseline'=>$plan['sessions']];
cloudValidate($proposal,'parameterProposal');checkHistory(true,'parameter proposal survives cloud schema');
$proposal['changes'][0]['field']='delete';rejectsHistory(fn()=>cloudValidate($proposal,'parameterProposal'),'mutation field rejected');
echo "PASS {$checks} automation, rest and proposal contracts\n";
$meals=[['id'=>$id,'name'=>'鸡蛋','calories'=>150,'protein'=>12,'carbs'=>1,'fat'=>10]];
$fingerprint=clubAutomationMealFingerprint($meals);
$media=$meals;$media[0]['photoRemoteID']='synthetic-photo.jpg';$media[0]['estimated']=true;
checkHistory($fingerprint===clubAutomationMealFingerprint($media),'media/provenance changes do not invalidate food completeness');
$changed=$meals;$changed[0]['calories']=300;
checkHistory($fingerprint!==clubAutomationMealFingerprint($changed),'actual food edit invalidates stored completeness evidence');
$reordered=$meals;$reordered[]=array_replace($meals[0],['id'=>'22222222-2222-2222-2222-222222222222']);
checkHistory(clubAutomationMealFingerprint($reordered)===clubAutomationMealFingerprint(array_reverse($reordered)),'meal list order cannot change coverage evidence');
echo "PASS {$checks} total automation contracts including coverage freshness\n";
