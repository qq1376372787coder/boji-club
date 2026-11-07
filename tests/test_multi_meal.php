<?php
declare(strict_types=1);
function fail(string $message,int $status=400): never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$item=['id'=>'m1','date'=>'2026-10-09','category'=>'早餐','name'=>'水煮鸡蛋','notes'=>[],
    'components'=>[['id'=>'sample','name'=>'鸡蛋','amount'=>2,'unit'=>'个','calories'=>150,'protein'=>13,'carbs'=>1,'fat'=>10,'basis'=>'described','details'=>[]]],
    'estimated'=>true,'calories'=>150,'protein'=>13,'carbs'=>1,'fat'=>10];
$batch=['kind'=>'meal_batch','estimated'=>true,'notes'=>[],'meals'=>[$item]];
cloudValidate($batch,'result');
cloudValidate(['kind'=>'meal','notes'=>[],'name'=>'旧版餐食','calories'=>150],'result');
foreach(['date'=>'2026-02-30','calories'=>'150','components'=>'bad'] as $key=>$bad) {
    $invalid=$batch;$invalid['meals'][0][$key]=$bad;$rejected=false;
    try { cloudValidate($invalid,'result'); } catch(RuntimeException $e) { $rejected=true; }
    if(!$rejected) throw new RuntimeException('Invalid '.$key.' was accepted');
}
$invalid=$batch;unset($invalid['meals'][0]['id']);$rejected=false;
try { cloudValidate($invalid,'result'); } catch(RuntimeException $e) { $rejected=true; }
if(!$rejected) throw new RuntimeException('Missing ID accepted');
echo "6 cloud contract cases passed; no database was accessed\n";
