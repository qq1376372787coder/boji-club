<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
$db=bojiTestDatabase('bojiclub_outbox_repair_test');bojiTestSchema($db,__DIR__.'/../account-server');
$db->exec('DELETE FROM users');
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13400000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");$uid=(int)$db->lastInsertId();
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,json_encode(['profile'=>['goal'=>'力量'],'days'=>[]])]);
$event='11111111-2222-3333-4444-555555555555';
$db->prepare("INSERT INTO domain_outbox(event_id,operation_id,user_id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,status,attempts,next_attempt,created_at,updated_at) VALUES(?,? ,?,'schedule','fixture',1,'PlanRescheduled','{}','pending',0,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$event,$event,$uid]);
$configPath=__DIR__.'/../account-server/config.php';
if(file_exists($configPath))throw new RuntimeException('Run in an unconfigured isolated checkout; refusing to replace config.php');
$base=getenv('BOJI_TEST_DSN_BASE')?:'mysql:unix_socket='.getenv('BOJI_TEST_MYSQL_SOCKET');
file_put_contents($configPath,"<?php return ".var_export(['dsn'=>$base.';dbname=bojiclub_outbox_repair_test;charset=utf8mb4','db_user'=>getenv('BOJI_TEST_DB_USER')?:'root','db_password'=>getenv('BOJI_TEST_DB_PASSWORD')?:''],true).';');
$count=0;
function verify(bool $ok,string $msg):void{global $count;$count++;if(!$ok)throw new RuntimeException('FAIL: '.$msg);}
function worker():void{
    $p=proc_open([PHP_BINARY,__DIR__.'/../account-server/process-domain-outbox.php'],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
    $out=stream_get_contents($pipes[1]).stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
    if(proc_close($p)!==0)throw new RuntimeException($out);
}
try {
    worker();
    verify($db->query('SELECT status FROM domain_outbox')->fetchColumn()==='published','worker publishes');
    verify((int)$db->query('SELECT COUNT(*) FROM domain_consumer_inbox')->fetchColumn()===1,'receipt recorded');
    verify((int)$db->query("SELECT COUNT(*) FROM user_memory_items WHERE content='当前目标：力量'")->fetchColumn()===1,'real memory projection updated');
    $db->exec("UPDATE domain_outbox SET status='pending'");worker();
    verify((int)$db->query('SELECT COUNT(*) FROM domain_consumer_inbox')->fetchColumn()===1,'redelivery deduplicated');
    verify((int)$db->query('SELECT COUNT(*) FROM user_memory_items')->fetchColumn()===1,'projection not duplicated');
    $db->exec("UPDATE domain_outbox SET status='processing',attempts=1,lease_token='old',updated_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)");worker();
    verify($db->query('SELECT status FROM domain_outbox')->fetchColumn()==='published','crashed lease recovered');
    $db->exec("UPDATE domain_outbox SET status='processing',attempts=5,lease_token='old',updated_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)");worker();
    verify($db->query('SELECT status FROM domain_outbox')->fetchColumn()==='dead_letter','exhausted crashed lease dead-lettered');
    echo "Outbox repair: $count assertions passed\n";
} finally {unlink($configPath);}
