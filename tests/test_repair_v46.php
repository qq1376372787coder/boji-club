<?php
declare(strict_types=1);
$source=file_get_contents(__DIR__.'/../account-server/public/weekly.php');
foreach(['aiRequestJSON','aiRetryConsumesUsage'] as $name){preg_match('/function '.$name.'\(.*?\n\}/s',$source,$match);eval($match[0]);}
function check46(bool $passed,string $name):void {if(!$passed)throw new RuntimeException($name);echo 'PASS '.$name.PHP_EOL;}
check46(aiRequestJSON(new stdClass())==='{}','retry encodes an empty JSON object');
check46(aiRequestJSON(null)==='','GET has no JSON body');
check46(json_decode(aiRequestJSON(['id'=>'test','payload'=>['meals'=>[]]]))->payload->meals===[],'nested arrays remain arrays');
check46(!aiRetryConsumesUsage(202,['retry_started'=>false]),'concurrent no-op retry does not consume quota');
check46(!aiRetryConsumesUsage(202,['retry_started'=>true]),'a real retry never charges quota');
check46(!aiRetryConsumesUsage(503,null),'uncertain upstream outcome never charges quota');
check46(str_contains($source,"'_quota_owner'=>aiQuotaOwner"),'production retry assigns trusted account ownership');
