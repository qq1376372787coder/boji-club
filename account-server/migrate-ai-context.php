<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
$config=getenv('BOJI_MIGRATION_DSN')?['dsn'=>getenv('BOJI_MIGRATION_DSN'),'db_user'=>getenv('BOJI_MIGRATION_USER')?:'root','db_password'=>getenv('BOJI_MIGRATION_PASSWORD')?:'']:require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$apply=in_array('--apply',$argv,true);
require_once __DIR__.'/schema-runtime.php';
if($apply)foreach(bojiSchemaStatements(file_get_contents(__DIR__.'/migrations/20261028-ai-context-schema.sql')) as $sql)$db->exec($sql);
$q=$db->query("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ai_context_bundles' AND COLUMN_NAME IN ('id','user_id','conversation_id','content_hash','snapshot_cipher','expires_at','created_at')");
$ok=(int)$q->fetchColumn()===7;$q=$db->query("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ai_provider_consents'");$ok=$ok&&(int)$q->fetchColumn()===4;$q=$db->query("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ai_stream_leases'");$ok=$ok&&(int)$q->fetchColumn()===3;echo json_encode(['status'=>$ok?'SCHEMA_OK':'MISSING_SCHEMA','apply'=>$apply])."\n";exit($ok?0:2);
