<?php
declare(strict_types=1);
function fail(string $message, int $status=400): never { throw new RuntimeException($message); }
require __DIR__.'/../account-server/public/cloud-validation.php';
$checks=0;
function accepted(array $value): void { global $checks; cloudValidate($value,'day'); $checks++; }
function rejected(array $value): void { global $checks; try { cloudValidate($value,'day'); } catch(RuntimeException $e) { $checks++; return; } throw new RuntimeException('invalid weight accepted'); }
$day=['exercises'=>[],'meals'=>[]];
accepted($day);
accepted($day+['bodyWeight'=>['kilograms'=>68.2,'updatedAt'=>812000000]]);
accepted($day+['bodyWeight'=>['kilograms'=>null,'updatedAt'=>812000001]]);
foreach([0,19,401,true,'68',INF,NAN] as $kg) rejected($day+['bodyWeight'=>['kilograms'=>$kg,'updatedAt'=>812000000]]);
rejected($day+['bodyWeight'=>['kilograms'=>68,'updatedAt'=>'bad']]);
rejected($day+['bodyWeight'=>['kilograms'=>68]]);
echo "PASS {$checks} phase2 cloud checks\n";
