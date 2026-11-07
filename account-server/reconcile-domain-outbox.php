<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require_once __DIR__.'/cli-bootstrap.php';
require_once __DIR__.'/public/domain-consumers.php';
$config=require __DIR__.'/config.php';
$GLOBALS['config']=$config;
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
try{
 $consumers=['personal-memory-v1','notifications-v1','club-progress-v1','home-insight-v1'];$gaps=domainProjectionGaps($db,$consumers);$processed=[];
 foreach($consumers as $consumer){$q=$db->prepare('SELECT COUNT(*) FROM domain_consumer_inbox WHERE consumer=?');$q->execute([$consumer]);$processed[$consumer]=['processed'=>(int)$q->fetchColumn(),'missing'=>count($gaps[$consumer]??[])];}
 $check=in_array('--check',$argv,true);$result=$check?['missing'=>array_sum(array_map('count',$gaps)),'requeued'=>0]:domainReconcile($db,$consumers);
 echo json_encode(['mode'=>$check?'check':'apply','consumers'=>$processed]+$result)."\n";exit($check&&$result['missing']>0?2:0);
}catch(Throwable $e){fwrite(STDERR,'Projection check failed: '.get_class($e)."\n");exit(1);}
