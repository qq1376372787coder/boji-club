<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/cloud-validation.php';
require __DIR__.'/../account-server/public/club-progress.php';
function fail(string $message, int $status = 400): void { throw new RuntimeException($message); }
$checks=0;
function check112(bool $ok, string $message): void {
    global $checks;
    if (!$ok) throw new RuntimeException($message);
    $checks++;
}
$source=['id'=>'fixture-scale','name'=>'Synthetic scale'];
$health=['date'=>'2026-10-18','timeZone'=>'Asia/Shanghai','updatedAt'=>814000000,'workouts'=>[]];
foreach (['bodyMass'=>55,'bodyFatPercentage'=>22.5,'leanBodyMass'=>42.6,'height'=>165,'bodyMassIndex'=>20.2,'waistCircumference'=>70] as $key=>$value) {
    $health[$key]=['value'=>$value,'source'=>$source,'recordedAt'=>813999000.25];
}
cloudValidate($health,'health','fixture.health');
check112(count($health)===10,'new body measurements and sampling timestamps accepted');
$decoded=json_decode(json_encode($health,JSON_THROW_ON_ERROR),true,512,JSON_THROW_ON_ERROR);
check112($decoded['bodyFatPercentage']['value']===22.5,'body-fat unit remains percentage points');
check112($decoded['bodyMass']['recordedAt']===813999000.25,'sample time precision retained');
$state=['days'=>['2026-10-18'=>['exercises'=>[],'meals'=>[],'health'=>$health]],'aiJobs'=>[]];
$index=clubBuildProgressIndex($state,'2026-10-18',static fn($id,$kind): bool=>false);
check112(clubProgressRange($index,'2026-10-18','2026-10-18')['health_days']===1,'measurement-only date counted once');
$bad=$health;$bad['bodyMass']['recordedAt']='yesterday';
try { cloudValidate($bad,'health','fixture.health'); $rejected=false; } catch(RuntimeException $e) { $rejected=true; }
check112($rejected,'non-numeric sample date rejected');
$bad=$health;$bad['leanBodyMass']['value']=true;
try { cloudValidate($bad,'health','fixture.health'); $rejected=false; } catch(RuntimeException $e) { $rejected=true; }
check112($rejected,'boolean body measurement rejected');
$legacy=['date'=>'2026-10-18','timeZone'=>'Asia/Shanghai','updatedAt'=>814000000,'workouts'=>[],
         'steps'=>['value'=>100,'source'=>$source]];
cloudValidate($legacy,'health','fixture.health');
check112(!isset($legacy['bodyMass']),'legacy payload accepted without invented body values');

$manual=['kilograms'=>68.4,'updatedAt'=>814000000,'bodyFatPercentage'=>21.5,'waistCircumferenceCM'=>74.2,'recordedAt'=>813999000,'source'=>'manual'];
cloudValidate($manual,'bodyWeight','fixture.bodyWeight');
check112($manual['bodyFatPercentage']===21.5 && $manual['source']==='manual','optional manual body measurements accepted');
$badManual=$manual;$badManual['bodyFatPercentage']=71;
try { cloudValidate($badManual,'bodyWeight','fixture.bodyWeight'); $rejected=false; } catch(RuntimeException $e) { $rejected=true; }
check112($rejected,'out-of-range body fat rejected');
$badManual=$manual;$badManual['source']='apple';
try { cloudValidate($badManual,'bodyWeight','fixture.bodyWeight'); $rejected=false; } catch(RuntimeException $e) { $rejected=true; }
check112($rejected,'unknown manual measurement source rejected');
echo "PASS {$checks} Build 112 health cloud and progress checks\n";
