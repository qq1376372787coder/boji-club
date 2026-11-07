<?php
declare(strict_types=1);
require __DIR__.'/test_club_insights.php';
require __DIR__.'/../account-server/public/ai-response.php';
$checks=0;
$coach=['answer'=>'基于当次登记，核对下一次训练的实际重量与次数。','sources'=>[['id'=>'day/2026-10-15','date'=>'2026-10-15','label'=>'已登记记录','detail'=>'已确认完成3组，饮食未确认完整。']],
 'actions'=>[['type'=>'training','date'=>'2026-10-15']]];
cloudValidate(['kind'=>'coach','notes'=>[],'coach'=>$coach],'result');checkInsights(true,'coach result cloud schema accepted');
foreach(['training','nutrition','body','plans','daily','weekly'] as $kind) {
 $action=['type'=>$kind,'date'=>'2026-10-15'];cloudValidate($action,'coachAction');checkInsights(true,'allowed read/open action '.$kind);
}
foreach(['delete','purchase','modify_plan','send_message'] as $kind) rejectInsights(fn()=>cloudValidate(['type'=>$kind,'date'=>'2026-10-15'],'coachAction'),'unsafe operation rejected '.$kind);
$bad=$coach;$bad['sources'][0]['date']='not-a-date';rejectInsights(fn()=>cloudValidate($bad,'coachAnswer'),'invalid source date rejected');
checkInsights(aiCompletionKinds('coach')===['coach'],'coach does not count as a daily or weekly reward');
$old=['days'=>(object)[],'aiJobs'=>[['id'=>'job','result'=>['kind'=>'coach','notes'=>[],'coach'=>$coach]]]];
$new=$old;unset($new['aiJobs'][0]['result']['coach']);$merged=cloudReconcileRecords($new,$old);
checkInsights($merged['aiJobs'][0]['result']['coach']===$coach,'legacy omission preserves full coach answer and evidence');
echo "PASS {$checks} Club coach schema, safe action and compatibility checks\n";
