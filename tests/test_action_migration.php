<?php
declare(strict_types=1);
require __DIR__.'/php_test_bootstrap.php';
if(!getenv('BOJI_TEST_DSN_BASE'))throw new RuntimeException('Disposable test DSN required');
$db=bojiTestDatabase('bojiclub_it');
putenv('BOJI_MIGRATION_DSN='.rtrim(getenv('BOJI_TEST_DSN_BASE'),';').';dbname=bojiclub_it;charset=utf8mb4');
putenv('BOJI_MIGRATION_USER='.(getenv('BOJI_TEST_DB_USER')?:'root'));putenv('BOJI_MIGRATION_PASSWORD='.(getenv('BOJI_TEST_DB_PASSWORD')?:''));
function migration(string $mode):array{
 $p=proc_open([PHP_BINARY,__DIR__.'/../account-server/migrate-v2-repair.php',$mode],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
 $out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$code=proc_close($p);return [$code,json_decode($out,true),$err];
}
[$code,$out,$err]=migration('--apply');if($code!==0)throw new RuntimeException($err); // repeat must retain advanced enum rows
$db->exec('ALTER TABLE ai_action_calls RENAME COLUMN input_json TO _migration_probe_input');
try{[$code,$out]=migration('--check');if($code!==1||!in_array('column:ai_action_calls.input_json',$out['missing']??[],true))throw new RuntimeException('Missing column falsely passed');}
finally{$db->exec('ALTER TABLE ai_action_calls RENAME COLUMN _migration_probe_input TO input_json');}
[$code,$out,$err]=migration('--check');if($code!==0||!$out['compatible'])throw new RuntimeException($err);
echo "Action migration: repeat apply, missing-column detection and restored compatibility passed\n";
