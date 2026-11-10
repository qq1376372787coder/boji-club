<?php
declare(strict_types=1);
/** CLI retention wrapper; see aiRunPruneEvents(). */
if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__ . '/public/action-support.php';
require_once __DIR__ . '/public/ai-response.php';
require_once __DIR__ . '/public/ai-conversations.php';
require_once __DIR__ . '/public/ai-runs.php';
$config = require __DIR__ . '/config.php';
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
try {
    $total=['pruned_runs'=>0,'deleted_events'=>0,'stale_runs_failed'=>0,'batches'=>0];
    $total['purged_photo_inputs']=aiRunPruneImageInputs($db);
    $deadline=microtime(true)+90;
    $batch=max(1,min(500,(int)($argv[2]??100)));
    for($i=0;$i<20 && microtime(true)<$deadline;$i++){
        $result=aiRunPruneEvents($db,(int)($argv[1]??30),$batch);
        foreach(['pruned_runs','deleted_events','stale_runs_failed'] as $key)$total[$key]+=$result[$key];
        $total['batches']++;
        if($result['pruned_runs']<$batch && $result['stale_runs_failed']<$batch)break;
    }
    echo json_encode($total,JSON_UNESCAPED_UNICODE)."\n";
}
catch (Throwable $error) { fwrite(STDERR, 'Prune failed: '.get_class($error)."\n"); exit(1); }

$db->exec('DELETE FROM ai_context_bundles WHERE expires_at<UTC_TIMESTAMP() LIMIT 500');
$db->exec('DELETE FROM ai_stream_leases WHERE expires_at<UTC_TIMESTAMP() LIMIT 500');
