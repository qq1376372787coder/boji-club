<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require __DIR__.'/schema-runtime.php';
$config=getenv('BOJI_MIGRATION_DSN')?['dsn'=>getenv('BOJI_MIGRATION_DSN'),'db_user'=>getenv('BOJI_MIGRATION_USER')?:'root','db_password'=>getenv('BOJI_MIGRATION_PASSWORD')?:'']:require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$sql=file_get_contents(__DIR__.'/migrations/20261028-scheduled-notifications.sql');
$tables=['notification_plan_settings','notification_schedule_runs','notification_schedule_deliveries'];
$apply=in_array('--apply',$argv,true);if(!$db->query("SELECT GET_LOCK('boji-scheduled-notifications-schema',10)")->fetchColumn())throw new RuntimeException('migration lock unavailable');
try{
 if($apply)foreach(bojiSchemaStatements($sql) as $statement)$db->exec($statement);
 $missing=[];foreach($tables as $table){$q=$db->prepare('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');$q->execute([$table]);if(!(int)$q->fetchColumn())$missing[]=$table;}
 foreach(['notification_plan_settings'=>'plan_id,state,revision,audience_json,enabled_at,updated_by,updated_at','notification_schedule_runs'=>'id,plan_id,plan_revision,occurrence_date,scheduled_for,expires_at,payload_json,recipient_count,created_at','notification_schedule_deliveries'=>'id,run_id,user_id,status,attempts,next_attempt,lease_token,lease_until,device_id,reason,receipt_id,created_at,updated_at'] as $table=>$columns){try{$db->query("SELECT $columns FROM $table LIMIT 0");}catch(PDOException $e){$missing[]=$table.'.columns';}}
 foreach(['notification_plan_settings'=>['PRIMARY'=>['plan_id',0]],'notification_schedule_runs'=>['scheduled_plan_once_daily'=>['plan_id,occurrence_date',0]],'notification_schedule_deliveries'=>['scheduled_user_once'=>['run_id,user_id',0],'scheduled_delivery_queue'=>['status,next_attempt',1]]] as $table=>$keys)foreach($keys as $key=>[$columns,$nonUnique]){$q=$db->prepare('SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols,MAX(NON_UNIQUE) AS non_unique FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND INDEX_NAME=?');$q->execute([$table,$key]);$index=$q->fetch();if(($index['cols']??null)!==$columns||(int)($index['non_unique']??-1)!==$nonUnique)$missing[]=$table.'.'.$key;}
 foreach(['scheduled_plan_owner'=>['notification_plan_settings','notification_plans'],'scheduled_run_plan'=>['notification_schedule_runs','notification_plans'],'scheduled_delivery_run'=>['notification_schedule_deliveries','notification_schedule_runs'],'scheduled_delivery_user'=>['notification_schedule_deliveries','users']] as $key=>[$table,$parent]){$q=$db->prepare('SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND CONSTRAINT_NAME=? AND TABLE_NAME=? AND REFERENCED_TABLE_NAME=? AND DELETE_RULE=\'CASCADE\'');$q->execute([$key,$table,$parent]);if(!(int)$q->fetchColumn())$missing[]=$table.'.'.$key;}
 echo json_encode(['status'=>$missing?'SCHEMA_REQUIRED':'SCHEMA_OK','missing'=>$missing,'data_deleted'=>false],JSON_THROW_ON_ERROR).PHP_EOL;
 exit($missing?2:0);
}finally{$db->query("SELECT RELEASE_LOCK('boji-scheduled-notifications-schema')");}
