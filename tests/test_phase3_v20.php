<?php
declare(strict_types=1);
function fail(string $message, int $status=400): never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
$text=str_repeat("按真实记录分析。\n",150);
$daily=['kind'=>'report','notes'=>[],'summary'=>$text,'training'=>$text,'nutrition'=>$text,'recovery'=>$text];
cloudValidate($daily,'result');$checks++;
$weekly=['kind'=>'weekly_review','summary'=>$text,'training'=>$text,'nutrition'=>$text,'recovery'=>$text,'appearance'=>'本次没有照片','photoFeedback'=>[],'decision'=>'keep','reason'=>$text,'notes'=>[],'sessions'=>[]];
cloudValidate($weekly,'weeklyResult');$checks++;
$roundtrip=json_decode(json_encode($weekly,JSON_THROW_ON_ERROR),true,512,JSON_THROW_ON_ERROR);
if($roundtrip!==$weekly) throw new RuntimeException('long report changed during serialization');$checks++;
$daily['summary']=str_repeat('长',20001);
try { cloudValidate($daily,'result');throw new LogicException('unbounded cloud text accepted'); } catch(RuntimeException $e) { $checks++; }
echo "PASS {$checks} phase3 cloud checks\n";
