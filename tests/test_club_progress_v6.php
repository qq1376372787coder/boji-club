<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/club-progress.php';
function check(bool $ok,string $message): void { if(!$ok) throw new RuntimeException($message); }
$state=['days'=>[],'aiJobs'=>[]]; $today='2026-10-03'; $start=new DateTimeImmutable('2026-01-01');
for($i=0;$i<365;$i++) {
    $date=$start->modify('+'.$i.' days')->format('Y-m-d');
    $state['days'][$date]=['exercises'=>[['sets'=>[['completed'=>true,'reps'=>$i%3===0?0:10]]]],'workoutSavedAt'=>1,'meals'=>array_fill(0,$i%4,[]),'health'=>['steps'=>['value'=>100]],'weeklyReview'=>['result'=>[],'jobID'=>'weekly-'.$i]];
    $state['aiJobs'][]=['id'=>'report-'.$i,'request'=>['date'=>$date],'result'=>['kind'=>'report']];
}
$verifiedCalls=0;$verify=static function($id,$kind) use(&$verifiedCalls): bool { $verifiedCalls++;return $kind==='report'; };
$index=clubBuildProgressIndex($state,$today,$verify);$firstCalls=$verifiedCalls;
for($season=0;$season<100;$season++) {
    $lo=$season*2; $hi=$lo+30;$begin=$start->modify('+'.$lo.' days')->format('Y-m-d');$end=$start->modify('+'.$hi.' days')->format('Y-m-d');
    $counts=clubProgressRange($index,$begin,$end);$training=0;$meals=0;$mealDays=0;$days=0;
    for($i=$lo;$i<=$hi;$i++) { $date=$start->modify('+'.$i.' days')->format('Y-m-d');if($date>$today)continue;$training+=$i%3===0?0:1;$meals+=$i%4;$mealDays+=$i%4===0?0:1;$days++; }
    check($counts['training_days']===$training && $counts['meal_records']===$meals && $counts['meal_days']===$mealDays && $counts['health_days']===$days && $counts['daily_reports']===$days && $counts['weekly_reviews']===0,'Range totals changed');
}
check($verifiedCalls===$firstCalls,'AI verification repeated for each season');
check(array_sum(clubProgressRange($index,'2027-01-01','2027-02-01'))===0,'Future days counted');
check(array_sum(clubProgressRange($index,'2026-11-01','2026-01-01'))===0,'Inverted interval counted');
check(array_sum(clubProgressRange(clubBuildProgressIndex([],$today,$verify),'2026-01-01',$today))===0,'Empty index failed');
echo "PASS 100 season ranges, future/empty bounds, verification reuse\n";
