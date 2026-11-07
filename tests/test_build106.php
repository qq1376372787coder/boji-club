<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/task-recovery.php';
require __DIR__.'/../account-server/public/automation.php';
$checks=0;
function check106(bool $ok,string $message):void {global $checks;if(!$ok)throw new RuntimeException($message);$checks++;}
$row=['created_at'=>'2026-10-16 01:02:03','client_job_id'=>'11111111-1111-1111-1111-111111111111'];
$cursor=taskRecoveryCursor($row);
check106(taskRecoveryPosition($cursor)===array_values($row),'cursor preserves both timestamp and tie-breaking ID');
check106(taskRecoveryPosition('')===null,'first page has no position');
check106(taskRecoveryCursor(null)===null,'last page has no next cursor');
foreach(['+++',str_repeat('x',257),'123',rtrim(strtr(base64_encode('["bad","id"]'),'+/','-_'),'=')] as $bad) {
    try{taskRecoveryPosition($bad);throw new RuntimeException('malformed cursor accepted');}catch(InvalidArgumentException){check106(true,'bad cursor rejected');}
}
$goal=['version'=>1,'id'=>'11111111-1111-1111-1111-111111111111','recordedAt'=>123,'private'=>'ignore','profile'=>['age'=>30,'height'=>175,'weight'=>70,'goal'=>'增肌','nickname'=>'private','avatarImage'=>'private','limitations'=>'膝盖限制']];
$clean=clubAutomationGoal($goal);
check106(!isset($clean['private'],$clean['profile']['nickname'],$clean['profile']['avatarImage']),'old-goal context never includes identity/avatar');
check106($clean['profile']['limitations']==='膝盖限制'&&$clean['profile']['age']===30,'necessary goal restrictions retained');
echo "PASS {$checks} Build 106 cursor and goal minimization contracts\n";
