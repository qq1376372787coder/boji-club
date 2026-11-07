<?php
declare(strict_types=1);
function fail(string $message,int $status=400):never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$meal=['id'=>'550E8400-E29B-41D4-A716-446655440000','name'=>'餐食','category'=>'早餐','calories'=>0,'protein'=>0,'carbs'=>0,'fat'=>0];
cloudValidate($meal,'meal');
cloudValidate($meal+['nutritionKnown'=>false],'meal');
cloudValidate($meal+['nutritionKnown'=>true],'meal');
$checks=3;
foreach([0,'false',[]] as $value) {
    try { cloudValidate($meal+['nutritionKnown'=>$value],'meal');throw new LogicException('invalid nutrition flag accepted'); }
    catch(RuntimeException $e) { $checks++; }
}
echo "PASS {$checks} v21 cloud nutrition checks\n";
