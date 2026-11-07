<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
$config=is_file(__DIR__.'/config.php')?require __DIR__.'/config.php':[];
if(($dsn=getenv('BOJI_MIGRATION_DSN'))!==false&&$dsn!==''){$config['dsn']=$dsn;$config['db_user']=getenv('BOJI_MIGRATION_USER')?:'root';$config['db_password']=getenv('BOJI_MIGRATION_PASSWORD')?:'';}
if(getenv('BOJI_MIGRATION_ROOT')==='1'){
 if(!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/',$config['dsn']??'',$match))throw new RuntimeException('Database name missing');
 $socket=getenv('BOJI_MYSQL_SOCKET')?:'/run/mysqld/mysqld.sock';if(!str_starts_with($socket,'/')||str_contains($socket,';'))throw new RuntimeException('Invalid socket');
 $config=['dsn'=>'mysql:unix_socket='.$socket.';dbname='.$match[1].';charset=utf8mb4','db_user'=>'root','db_password'=>''];
}
if(empty($config['dsn']))throw new RuntimeException('Migration database is not configured');
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$files=['20261024-ai-conversations.sql','20261025-ai-action-proposals.sql','20261025-user-memory-items.sql','20261025-ai-feedback-usage.sql','20261024-domain-consumer-inbox.sql','20261025-training-commands.sql','20261025-ai-capabilities.sql','20261025-domain-projections.sql','20261025-action-system.sql','20261025-ai-runs.sql'];
$apply=in_array('--apply',$argv,true);$tables=[];
try {
 foreach($files as $file){
  $sql=implode("\n",array_filter(file(__DIR__.'/migrations/'.$file,FILE_IGNORE_NEW_LINES),fn($v)=>!preg_match('/^\s*--/',$v)));
  preg_match_all('/CREATE TABLE IF NOT EXISTS ([a-z_]+)/i',$sql,$names);$tables=array_merge($tables,$names[1]);
  if($apply)foreach(array_filter(array_map('trim',explode(';',$sql))) as $statement){
   // Both supported engines accept plain ADD; duplicate-field/index errors are safe no-ops.
   $statement=preg_replace('/ADD (COLUMN|UNIQUE KEY|KEY|INDEX) IF NOT EXISTS/i','ADD $1',$statement);
   if(preg_match('/ALTER TABLE ai_action_proposals\s+MODIFY COLUMN kind ENUM\(([^)]+)\)/i',$statement,$enum)){
    $existing=$db->query("SHOW COLUMNS FROM ai_action_proposals LIKE 'kind'")->fetch(PDO::FETCH_ASSOC)['Type']??'';
    preg_match_all("/'([^']+)'/",$existing,$have);preg_match_all("/'([^']+)'/",$enum[1],$want);
    if(!array_diff($want[1],$have[1]))continue; // never shrink an enum when reapplying earlier migrations
   }
   try{$db->exec($statement);}catch(PDOException $e){if(!in_array((int)($e->errorInfo[1]??0),[1060,1061],true))throw $e;}
  }
 }
 if($apply){
  // CREATE TABLE IF NOT EXISTS does not add missing columns/indexes to an
  // existing table. Repair the new Run tables explicitly so --apply can
  // recover a drifted schema (negative tests drop each item).
  $columnRepairs=[
   ['ai_runs','conversation_id',"ALTER TABLE ai_runs ADD conversation_id VARCHAR(64) NOT NULL AFTER user_id"],
   ['ai_runs','client_message_id',"ALTER TABLE ai_runs ADD client_message_id CHAR(36) NOT NULL AFTER conversation_id"],
   ['ai_runs','server_job_id',"ALTER TABLE ai_runs ADD server_job_id CHAR(36) NOT NULL AFTER client_message_id"],
   ['ai_runs','message_id',"ALTER TABLE ai_runs ADD message_id CHAR(36) NOT NULL AFTER server_job_id"],
   ['ai_runs','trace_id',"ALTER TABLE ai_runs ADD trace_id CHAR(32) NOT NULL AFTER message_id"],
   ['ai_runs','status',"ALTER TABLE ai_runs ADD status VARCHAR(16) NOT NULL AFTER trace_id"],
   ['ai_runs','last_seq',"ALTER TABLE ai_runs ADD last_seq INT UNSIGNED NOT NULL DEFAULT 0 AFTER status"],
   ['ai_runs','event_floor',"ALTER TABLE ai_runs ADD event_floor INT UNSIGNED NOT NULL DEFAULT 1 AFTER last_seq"],
   ['ai_runs','request_hash',"ALTER TABLE ai_runs ADD request_hash CHAR(64) NOT NULL AFTER last_seq"],
   ['ai_runs','request_json',"ALTER TABLE ai_runs ADD request_json MEDIUMTEXT NOT NULL AFTER request_hash"],
   ['ai_runs','result_json',"ALTER TABLE ai_runs ADD result_json MEDIUMTEXT NULL AFTER request_json"],
   ['ai_runs','error_code',"ALTER TABLE ai_runs ADD error_code VARCHAR(64) NULL AFTER result_json"],
   ['ai_runs','lease_owner',"ALTER TABLE ai_runs ADD lease_owner VARCHAR(80) NULL AFTER error_code"],
   ['ai_runs','lease_expires_at',"ALTER TABLE ai_runs ADD lease_expires_at DATETIME NULL AFTER lease_owner"],
   ['ai_runs','attempts',"ALTER TABLE ai_runs ADD attempts INT UNSIGNED NOT NULL DEFAULT 0 AFTER lease_expires_at"],
   ['ai_runs','created_at',"ALTER TABLE ai_runs ADD created_at DATETIME NOT NULL AFTER attempts"],
   ['ai_runs','updated_at',"ALTER TABLE ai_runs ADD updated_at DATETIME NOT NULL AFTER created_at"],
   ['ai_run_events','seq',"ALTER TABLE ai_run_events ADD seq INT UNSIGNED NOT NULL AFTER run_id"],
   ['ai_run_events','event_id',"ALTER TABLE ai_run_events ADD event_id CHAR(36) NOT NULL AFTER seq"],
   ['ai_run_events','type',"ALTER TABLE ai_run_events ADD type VARCHAR(40) NOT NULL AFTER event_id"],
   ['ai_run_events','data_json',"ALTER TABLE ai_run_events ADD data_json MEDIUMTEXT NOT NULL AFTER type"],
   ['ai_run_events','created_at',"ALTER TABLE ai_run_events ADD created_at DATETIME NOT NULL AFTER data_json"],
  ];
  $columnCheck=$db->prepare('SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=? AND column_name=?');
  foreach($columnRepairs as [$t,$c,$ddl]){try{$columnCheck->execute([$t,$c]);if(!$columnCheck->fetchColumn())$db->exec($ddl);}catch(PDOException $e){if(!in_array((int)($e->errorInfo[1]??0),[1060,1061],true))throw $e;}}
  $indexRepairs=[
   ['ai_runs','ai_runs_client',"ALTER TABLE ai_runs ADD UNIQUE KEY ai_runs_client (user_id, client_message_id)"],
   ['ai_runs','ai_runs_claim',"ALTER TABLE ai_runs ADD KEY ai_runs_claim (status, lease_expires_at)"],
   ['ai_runs','ai_runs_conversation',"ALTER TABLE ai_runs ADD KEY ai_runs_conversation (user_id, conversation_id, created_at)"],
   ['ai_runs','ai_runs_cleanup',"ALTER TABLE ai_runs ADD KEY ai_runs_cleanup (status, updated_at)"],
   ['ai_run_events','ai_run_events_event',"ALTER TABLE ai_run_events ADD UNIQUE KEY ai_run_events_event (event_id)"],
  ];
  $indexCheck=$db->prepare('SELECT 1 FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name=? AND index_name=?');
  foreach($indexRepairs as [$t,$i,$ddl]){try{$indexCheck->execute([$t,$i]);if(!$indexCheck->fetchColumn())$db->exec($ddl);}catch(PDOException $e){if(!in_array((int)($e->errorInfo[1]??0),[1060,1061],true))throw $e;}}
 }
 $missing=[];$q=$db->prepare('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name=?');
 foreach(array_unique($tables) as $t){$q->execute([$t]);if(!(int)$q->fetchColumn())$missing[]='table:'.$t;}
 $q=$db->prepare('SELECT COLUMN_TYPE FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=? AND column_name=?');
 foreach([['data_operations','idempotency_key'],['data_operations','undo_json'],['data_operations','trace_id'],['ai_action_proposals','trace_id'],['ai_usage_ledger','trace_id'],['ai_action_messages','trace_id'],['ai_action_calls','trace_id'],['user_action_preferences','proactive_learning'],['domain_outbox','trace_id'],['ai_action_proposals','kind'],['active_workout_sessions','session_id'],['ai_action_calls','input_json'],['domain_projection_state','aggregate_version']] as [$t,$c]){$q->execute([$t,$c]);$type=$q->fetchColumn();if($type===false)$missing[]="column:$t.$c";elseif($t==='ai_action_proposals'&&$c==='kind'&&(!str_contains($type,"'exercise_swap'")||!str_contains($type,"'plan_activation'")||!str_contains($type,"'training_finish'")))$missing[]='enum:proposal.kind';}
 foreach(array_unique($tables) as $t){
  foreach($files as $file){$sql=file_get_contents(__DIR__.'/migrations/'.$file);if(!preg_match('/CREATE TABLE IF NOT EXISTS '.preg_quote($t,'/').'\s*\((.*?)\)\s*ENGINE/s',$sql,$m))continue;
   preg_match_all('/(?:^|,|\n)\s*([a-z_]+)\s+(?:BIGINT|INT|VARCHAR|CHAR|TEXT|MEDIUMTEXT|LONGTEXT|JSON|ENUM|DATETIME|TIMESTAMP|TINYINT|BOOLEAN)\b/i',$m[1],$fields);
   foreach($fields[1] as $c){$q->execute([$t,$c]);if($q->fetchColumn()===false)$missing[]='column:'.$t.'.'.$c;}
   preg_match_all('/\b(?:UNIQUE KEY|INDEX|KEY)\s+([a-z_]+)\s*\(/i',$m[1],$indexes);
   $indexQuery=$db->prepare('SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name=? AND index_name=?');
   foreach($indexes[1] as $index){$indexQuery->execute([$t,$index]);if(!(int)$indexQuery->fetchColumn())$missing[]='index:'.$t.'.'.$index;}
   if(str_contains($m[1],'PRIMARY KEY')){$indexQuery->execute([$t,'PRIMARY']);if(!(int)$indexQuery->fetchColumn())$missing[]='primary:'.$t;}
  }
 }
 $q=$db->prepare("SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='data_operations' AND index_name='data_ops_idem' AND non_unique=0");$q->execute();if(!(int)$q->fetchColumn())$missing[]='unique:data_operations.data_ops_idem';
 echo json_encode(['mode'=>$apply?'apply':'check','missing'=>$missing,'missing_tables'=>$missing,'compatible'=>!$missing],JSON_UNESCAPED_UNICODE)."\n";exit($missing?1:0);
}catch(Throwable $e){fwrite(STDERR,'Migration failed: '.get_class($e).': '.$e->getMessage()."\n");exit(1);}
