<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli') { http_response_code(404); exit; }
$config=require __DIR__.'/config.php';
if(getenv('BOJI_MIGRATION_ROOT')==='1') {
    if(!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/',$config['dsn'],$match)) throw new RuntimeException('Database name missing');
    $socket=getenv('BOJI_MYSQL_SOCKET')?:'/run/mysqld/mysqld.sock';
    if(!str_starts_with($socket,'/')||str_contains($socket,';'))throw new RuntimeException('Invalid database socket path');
    $config['dsn']='mysql:unix_socket='.$socket.';dbname='.$match[1].';charset=utf8mb4';
    $config['db_user']='root'; $config['db_password']='';
}
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$apply=in_array('--apply',$argv,true); $changes=[];
foreach(['reviewed_at'=>'DATETIME NULL','reviewed_by'=>'BIGINT UNSIGNED NULL'] as $column=>$definition) {
    $q=$db->prepare('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?');
    $q->execute(['club_reward_claims',$column]);
    if(!(int)$q->fetchColumn()) { $changes[]=$column; if($apply) $db->exec('ALTER TABLE club_reward_claims ADD COLUMN '.$column.' '.$definition); }
}
echo json_encode(['applied'=>$apply,'columns'=>$changes],JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT).PHP_EOL;
