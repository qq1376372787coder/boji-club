<?php
declare(strict_types=1);

/** Build once per request. Every season then uses two binary searches. */
function clubBuildProgressIndex(array $state, string $today, callable $verify, string $start='0000-00-00', string $end='9999-12-31'): array {
    $zero=['training_days'=>0,'meal_days'=>0,'weekly_reviews'=>0,'meal_records'=>0,'daily_reports'=>0,'health_days'=>0];
    $events=[];
    foreach (($state['days'] ?? []) as $date=>$day) {
        if(!is_string($date) || $date>$today || $date<$start || $date>$end || !is_array($day)) continue;
        $counts=$zero; $trained=false;
        foreach (($day['exercises'] ?? []) as $exercise) foreach (($exercise['sets'] ?? []) as $set) {
            if(!empty($set['completed']) && (isset($set['durationSeconds']) ? (int)$set['durationSeconds']>0 : (int)($set['reps']??0)>0)) { $trained=true; break 2; }
        }
        $confirmed=$trained && !empty($day['workoutSavedAt']);
        if(!empty($day['workoutSessions'])) {
            $confirmed=false;
            foreach($day['workoutSessions'] as $session) {
                if(empty($session['savedAt'])) continue;
                foreach($day['exercises'] as $exercise) {
                    if(strtolower($exercise['workoutSessionID']??'')!==strtolower($session['id'])) continue;
                    foreach($exercise['sets'] as $set) if(!empty($set['completed']) && (isset($set['durationSeconds']) ? (int)$set['durationSeconds']>0 : (int)($set['reps']??0)>0)) { $confirmed=true; break 3; }
                }
            }
        }
        if($confirmed) $counts['training_days']=1;
        if(!empty($day['meals']) && is_array($day['meals'])) { $counts['meal_days']=1; $counts['meal_records']=count($day['meals']); }
        $health=$day['health']??null;
        if(is_array($health) && (count(array_filter(['steps','activeEnergy','heartRate','restingHeartRate','sleep','bodyMass','bodyFatPercentage','leanBodyMass','height','bodyMassIndex','waistCircumference'],fn($key)=>is_array($health[$key]??null)))>0 || !empty($health['workouts']))) $counts['health_days']=1;
        if(is_array($day['weeklyReview']??null) && is_array($day['weeklyReview']['result']??null) && $verify((string)($day['weeklyReview']['jobID']??''),'weekly_review')) $counts['weekly_reviews']=1;
        $events[$date]=$counts;
    }
    foreach (($state['aiJobs']??[]) as $job) {
        $date=(string)($job['request']['date']??'');
        if(($job['result']['kind']??'')==='report' && $date!=='' && $date<=$today && $date>=$start && $date<=$end && $verify((string)($job['id']??''),'report')) {
            $events[$date]??=$zero; $events[$date]['daily_reports']=1;
        }
    }
    ksort($events,SORT_STRING); $prefix=[$zero]; $total=$zero;
    foreach($events as $counts) { foreach($zero as $metric=>$_) $total[$metric]+=$counts[$metric]; $prefix[]=$total; }
    return ['dates'=>array_keys($events),'prefix'=>$prefix];
}

function clubProgressBound(array $dates, string $date, bool $inclusive): int {
    $lo=0; $hi=count($dates);
    while($lo<$hi) { $mid=intdiv($lo+$hi,2); if($dates[$mid]<$date || ($inclusive && $dates[$mid]===$date)) $lo=$mid+1; else $hi=$mid; }
    return $lo;
}

function clubProgressRange(array $index, string $start, string $end): array {
    $before=$index['prefix'][clubProgressBound($index['dates'],$start,false)];
    $after=$index['prefix'][clubProgressBound($index['dates'],$end,true)];
    foreach($after as $metric=>$value) $after[$metric]=$start<=$end ? $value-$before[$metric] : 0;
    return $after;
}

function clubProgress(PDO $db, int $userId, array $season, ?array $state=null): array {
    static $indexes=[];
    [$start,$end]=$GLOBALS['bojiClubProgressWindow']??[$season['starts_on'],$season['ends_on']];
    $key=$userId.':'.$start.':'.$end;
    if(!isset($indexes[$key])) {
        $today=(new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        $state=$state??clubState($db,$userId);
        $refs=[];
        foreach(($state['days']??[]) as $day) {
            $review=$day['weeklyReview']??null;
            if(is_array($review)&&is_array($review['result']??null)&&is_string($review['jobID']??null)) $refs[]=['id'=>$review['jobID'],'kind'=>'weekly_review'];
        }
        foreach(($state['aiJobs']??[]) as $job) if(($job['result']['kind']??'')==='report'&&is_string($job['id']??null)) $refs[]=['id'=>$job['id'],'kind'=>'report'];
        $verified=verifiedAICompletions($db,$userId,$refs);
        $indexes[$key]=clubBuildProgressIndex($state,$today,fn($id,$kind)=>$verified[strtolower((string)$id)]??false,$start,$end);
    }
    return clubProgressRange($indexes[$key],$season['starts_on'],$season['ends_on']);
}

function clubProgressWindow(array $seasons): ?array {
    if(!$seasons) return null;
    return [min(array_column($seasons,'starts_on')),max(array_column($seasons,'ends_on'))];
}
