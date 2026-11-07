<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/ai-response.php';
$config=require $argv[1];
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$db->exec('CREATE TEMPORARY TABLE ai_user_jobs(user_id BIGINT,server_job_id VARCHAR(36),kind VARCHAR(40),completed_at DATETIME NULL)');
try {
    foreach(['generate_plan'=>'plan','parse_plan'=>'plan','food'=>'meal','report'=>'report','weekly_review'=>'weekly_review'] as $request=>$result) {
        $db->exec('DELETE FROM ai_user_jobs');
        $q=$db->prepare('INSERT INTO ai_user_jobs VALUES(?,?,?,NULL)');$q->execute([1,'fixture',$request]);$q->execute([2,'fixture',$request]);
        aiMarkCompleted($db,1,'fixture',['status'=>'succeeded','result'=>['kind'=>$result]]);
        if((int)$db->query('SELECT count(*) FROM ai_user_jobs WHERE user_id=1 AND completed_at IS NOT NULL')->fetchColumn()!==1)throw new RuntimeException('mapping '.$request);
        if((int)$db->query('SELECT count(*) FROM ai_user_jobs WHERE user_id=2 AND completed_at IS NOT NULL')->fetchColumn()!==0)throw new RuntimeException('owner isolation');
        $before=$db->query('SELECT completed_at FROM ai_user_jobs WHERE user_id=1')->fetchColumn();
        aiMarkCompleted($db,1,'fixture',['status'=>'succeeded','result'=>['kind'=>$result]]);
        if($before!==$db->query('SELECT completed_at FROM ai_user_jobs WHERE user_id=1')->fetchColumn())throw new RuntimeException('idempotence');
    }
    foreach(['meal_batch'=>'food','plan_notes'=>'parse_plan'] as $result=>$request) {
        $db->exec('DELETE FROM ai_user_jobs');$q=$db->prepare('INSERT INTO ai_user_jobs VALUES(?,?,?,NULL)');$q->execute([1,'fixture',$request]);
        aiMarkCompleted($db,1,'fixture',['status'=>'succeeded','result'=>['kind'=>$result]]);
        if((int)$db->query('SELECT count(*) FROM ai_user_jobs WHERE completed_at IS NOT NULL')->fetchColumn()!==1)throw new RuntimeException($result);
    }
    $db->exec('UPDATE ai_user_jobs SET completed_at=NULL');
    foreach([['status'=>'running','result'=>['kind'=>'plan_notes']],['status'=>'succeeded','result'=>['kind'=>'unknown']],['status'=>'succeeded','result'=>['kind'=>'meal']]] as $response) aiMarkCompleted($db,1,'fixture',$response);
    if((int)$db->query('SELECT count(*) FROM ai_user_jobs WHERE completed_at IS NOT NULL')->fetchColumn()!==0)throw new RuntimeException('wrong result must not complete task');
    echo 'PASS 7 real SQL completion mappings, owner isolation, idempotence and wrong-result guard; temporary table only'.PHP_EOL;
} finally {$db->exec('DROP TEMPORARY TABLE ai_user_jobs');}
