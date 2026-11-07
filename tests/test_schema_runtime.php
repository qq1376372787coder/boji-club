<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/schema-runtime.php';
function ck136(bool $ok,string $message):void{if(!$ok)throw new RuntimeException($message);}
$parts=bojiSchemaStatements("-- comment;\nSELECT 'a;b', `semi;column`; /* x;y */ SELECT 'it''s fine';");
ck136(count($parts)===2,'SQL strings/comments do not split statements');
$base=getenv('BOJI_TEST_DSN_BASE')?:'';if(!$base)throw new RuntimeException('Isolated DSN required');
$root=new PDO($base,getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'');
$database='boji136_schema_cli_test';$root->exec('DROP DATABASE IF EXISTS '.$database);$root->exec('CREATE DATABASE '.$database);
function init136(string $database):array{
 $env=array_merge($_ENV,['BOJI_MIGRATION_DSN'=>rtrim(getenv('BOJI_TEST_DSN_BASE'),';').';dbname='.$database,'BOJI_MIGRATION_USER'=>getenv('BOJI_TEST_DB_USER')?:'root','BOJI_MIGRATION_PASSWORD'=>getenv('BOJI_TEST_DB_PASSWORD')?:'']);
 $proc=proc_open([PHP_BINARY,__DIR__.'/../account-server/init-schema.php','--apply'],[1=>['pipe','w'],2=>['pipe','w']],$pipes,null,$env);
 $out=stream_get_contents($pipes[1]);fclose($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[2]);return [proc_close($proc),$out,$err];
}
[$code,$out,$err]=init136($database);ck136($code===0,'real empty DB CLI: '.$out.$err);
$db=bojiTestDatabase($database);
foreach(['app_states','admin_accounts','ai_runs','ai_context_bundles','ai_provider_consents','member_feedback_tickets'] as $table)ck136((int)$db->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='$table'")->fetchColumn()===1,'created '.$table);
[$code,$out,$err]=init136($database);ck136($code!==0&&str_contains($err,'non-empty'),'repeat init refuses existing data');
foreach(['migrate-v2-repair.php','migrate-ai-context.php'] as $script)foreach([1,2] as $iteration){[$code,$out,$err]=bojiTestRunMigration($database,['--apply'],$script);ck136($code===0,'real migration repeat '.$script.': '.$out.$err);}
$db->beginTransaction();
require __DIR__.'/../account-server/public/app-config.php';
appConfigLockedState($db);
$other=bojiTestDatabase($database);$other->exec('SET SESSION innodb_lock_wait_timeout=1');$other->beginTransaction();
try{appConfigLockedState($other);throw new LogicException('concurrent config lock should block');}
catch(PDOException $e){ck136((int)$e->errorInfo[1]===1205,'concurrent edit waits on real row lock');}
finally{if($other->inTransaction())$other->rollBack();$db->rollBack();}
echo "SCHEMA_INIT_REPEAT_AND_CONFIG_LOCK_PASS\n";
