<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never {throw new RuntimeException($message);}
function respond(int $status,array $body=[]):never {throw new UnexpectedValueException(json_encode(['status'=>$status,'body'=>$body],JSON_THROW_ON_ERROR));}
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/ai-response.php';
try {aiQuotaFailure(0);} catch(UnexpectedValueException $e) {
    $reply=json_decode($e->getMessage(),true,flags:JSON_THROW_ON_ERROR);
    if($reply['status']!==429 || $reply['body']['code']!=='quota_exceeded' || $reply['body']['retry_after']!==57600)throw new RuntimeException('quota protocol and Beijing midnight');
}
$n=0;
function check50(bool $ok,string $label):void {global $n;if(!$ok)throw new RuntimeException($label);$n++;echo 'PASS '.$label.PHP_EOL;}
$job=['id'=>'abc','status'=>'succeeded','result'=>['kind'=>'report','summary'=>'已保存的报告']];
$old=['days'=>(object)[],'aiJobs'=>[$job]];
$incoming=['days'=>(object)[],'aiJobs'=>[]];
check50(cloudReconcileRecords($incoming,$old)['aiJobs']===[$job],'empty local cache does not delete cloud report');
$incoming['aiJobs']=[['id'=>'abc','status'=>'pending']];
check50(cloudReconcileRecords($incoming,$old)['aiJobs']===[$job],'stale pending task does not erase result');
$incoming['deletedAIJobIDs']=['ABC'];
check50(cloudReconcileRecords($incoming,$old)['aiJobs']===[],'explicit tombstone removes report case-insensitively');
$deleted=$old;$deleted['deletedAIJobIDs']=['abc'];
check50(cloudReconcileRecords($old,$deleted)['aiJobs']===[],'old device cannot resurrect deleted result');
foreach(['plan'=>['generate_plan','parse_plan'],'plan_notes'=>['parse_plan'],'meal'=>['food'],'meal_batch'=>['food'],'report'=>['report'],'weekly_review'=>['weekly_review'],'unknown'=>[]] as $kind=>$expected) check50(aiCompletionKinds($kind)===$expected,'completion mapping '.$kind);
$filtered=publicAIResponse(['error'=>'服务繁忙','code'=>'capacity','retry_after'=>60,'secret'=>'private']);
check50($filtered===['error'=>'服务繁忙','code'=>'capacity','retry_after'=>60],'public errors preserve bounded retry metadata without secrets');
echo 'ALL '.$n.' AI STABILITY PHP CHECKS PASSED'.PHP_EOL;
