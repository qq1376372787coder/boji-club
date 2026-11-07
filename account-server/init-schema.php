<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli'){http_response_code(404);exit(1);}
require __DIR__.'/schema-runtime.php';
try {
    $dsn=getenv('BOJI_MIGRATION_DSN')?:'';
    if($dsn==='' || !preg_match('/(?:^|;)dbname=[A-Za-z0-9_]+(?:;|$)/',$dsn))throw new RuntimeException('Explicit BOJI_MIGRATION_DSN with database required');
    $db=new PDO($dsn,getenv('BOJI_MIGRATION_USER')?:'root',getenv('BOJI_MIGRATION_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    $tables=(int)$db->query('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()')->fetchColumn();
    $apply=in_array('--apply',$argv,true);
    if($apply && $tables!==0)throw new RuntimeException('Refusing to initialize a non-empty database; use incremental migration CLI');
    $count=$apply?bojiApplySchema($db,__DIR__):0;
    echo json_encode(['mode'=>$apply?'apply':'check','empty'=>$tables===0,'statements_applied'=>$count],JSON_THROW_ON_ERROR)."\n";
} catch(Throwable $error){fwrite(STDERR,$error->getMessage()."\n");exit(1);}
