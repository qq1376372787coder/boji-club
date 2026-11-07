<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
$db=bojiTestDatabase('bojiclub_timestamp_repair_test');bojiTestSchema($db,__DIR__.'/../account-server');$db->exec('DELETE FROM users');
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13300000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");$uid=(int)$db->lastInsertId();
$stamp=time();$date='2026-10-24';$body=['kilograms'=>72.5,'updatedAt'=>$stamp];
$state=['profile'=>[],'days'=>[$date=>['exercises'=>[],'meals'=>[],'bodyWeight'=>$body]]];
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid,json_encode($state)]);
$db->prepare("INSERT INTO data_operations(operation_id,user_id,actor,command_type,payload_hash,aggregate_type,aggregate_id,before_version,after_version,status,created_at) VALUES('11111111-2222-3333-4444-555555555555',?,'user','BodyWeight.Create',?,'body',?,'1','2','succeeded',UTC_TIMESTAMP())")->execute([$uid,str_repeat('a',64),$date]);
$configPath=__DIR__.'/../account-server/config.php';if(file_exists($configPath))throw new RuntimeException('Refusing configured checkout');
$base=getenv('BOJI_TEST_DSN_BASE')?:'mysql:unix_socket='.getenv('BOJI_TEST_MYSQL_SOCKET');
file_put_contents($configPath,"<?php return ".var_export(['dsn'=>$base.';dbname=bojiclub_timestamp_repair_test;charset=utf8mb4','db_user'=>getenv('BOJI_TEST_DB_USER')?:'root','db_password'=>getenv('BOJI_TEST_DB_PASSWORD')?:''],true).';');
$n=0;
function verify(bool $ok,string $message):void{global $n;$n++;if(!$ok)throw new RuntimeException($message);}
function repair(bool $apply):array{
 $cmd=[PHP_BINARY,__DIR__.'/../account-server/repair-v2-bodyweight-timestamps.php'];if($apply)$cmd[]='--apply';
 $proc=proc_open($cmd,[1=>['pipe','w'],2=>['pipe','w']],$pipes);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
 if(proc_close($proc)!==0)throw new RuntimeException($out.$err);return json_decode($out,true,512,JSON_THROW_ON_ERROR);
}
try {
 $process=proc_open([PHP_BINARY,__DIR__.'/../account-server/migrate-v2-repair.php','--check'],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
 $migration=stream_get_contents($pipes[1]);$errors=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
 verify(proc_close($process)===0 && json_decode($migration,true)['missing_tables']===[], 'migration check confirms complete additive schema: '.$errors);
 $process=proc_open([PHP_BINARY,__DIR__.'/../account-server/migrate-v2-repair.php','--apply'],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
 $migration=stream_get_contents($pipes[1]);$errors=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
 verify(proc_close($process)===0 && json_decode($migration,true)['missing_tables']===[], 'additive migration reapplies safely: '.$errors);
 verify((int)$db->query('SELECT COUNT(*) FROM users')->fetchColumn()===1,'additive migration preserves existing users');
 $dry=repair(false);verify($dry['candidates']===1 && $dry['repaired']===0,'dry run detects candidate without mutation');
 verify((int)$db->query('SELECT revision FROM app_states')->fetchColumn()===1,'dry run keeps revision');
 $done=repair(true);verify($done['repaired']===1,'apply repairs correlated timestamp');
 $saved=json_decode($db->query('SELECT state_json FROM app_states')->fetchColumn(),true);
 verify($saved['days'][$date]['bodyWeight']['updatedAt']===$stamp-978307200,'repair uses existing Swift epoch');
 verify($saved['days'][$date]['bodyWeight']['kilograms']===72.5,'weight value preserved');
 verify((int)$db->query("SELECT COUNT(*) FROM data_operations WHERE command_type='BodyWeight.TimestampRepair'")->fetchColumn()===1,'repair audited');
 $again=repair(true);verify($again['repaired']===0,'repair is idempotent');
 echo "Timestamp repair: $n assertions passed\n";
}finally{unlink($configPath);}
