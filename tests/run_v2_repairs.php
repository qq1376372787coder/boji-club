<?php
declare(strict_types=1);
// Isolated MySQL credentials are mandatory. No production config is read.
require __DIR__.'/php_test_bootstrap.php';
$base=getenv('BOJI_TEST_DSN_BASE')?:'';
if($base==='') {
 $socket=getenv('BOJI_TEST_MYSQL_SOCKET');
 if(!$socket){fwrite(STDERR,"Set BOJI_TEST_DSN_BASE or BOJI_TEST_MYSQL_SOCKET to an isolated database server.\n");exit(2);}
 $base='mysql:unix_socket='.$socket;
}
if(file_exists(__DIR__.'/../account-server/config.php')){fwrite(STDERR,"Use an unconfigured isolated checkout; config.php must not exist.\n");exit(2);}
$db=new PDO($base,getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
foreach(['bojiclub_ai_conversations_test','bojiclub_repair_test','bojiclub_outbox_repair_test','bojiclub_timestamp_repair_test'] as $name)$db->exec('CREATE DATABASE IF NOT EXISTS '.$name.' CHARACTER SET utf8mb4');
bojiTestSchema(bojiTestDatabase('bojiclub_ai_conversations_test'),__DIR__.'/../account-server');
foreach(['test_ai_conversations.php','test_ai_proposals.php','test_ai_memory.php','test_proposal_intake.php','test_v2_repair.php','test_outbox_repair.php','test_timestamp_repair.php'] as $test){
 $child=proc_open([PHP_BINARY,__DIR__.'/'.$test],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
 $out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
 fwrite(STDOUT, $test.': '.$out);if($err!=='')fwrite(STDERR,$err);
 if(proc_close($child)!==0)exit(1);
}
echo "All 7 V2 PHP/MySQL suites passed\n";
