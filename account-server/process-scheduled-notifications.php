<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require __DIR__.'/public/scheduled-notifications.php';
$config=require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
if(!scheduleReady($db)){fwrite(STDERR,"SCHEDULE_SCHEMA_REQUIRED\n");exit(2);}
$lock=fopen(sys_get_temp_dir().'/boji-notification-schedules-'.hash('sha256',$config['dsn']).'.lock','c');if(!$lock||!flock($lock,LOCK_EX|LOCK_NB))exit(0);
try{
 if(!clubPushConfigured($config))throw new RuntimeException('APNS_NOT_CONFIGURED');
 if(!clubPushTransportReady())throw new RuntimeException('APNS_HTTP2_UNAVAILABLE');
 $now=time();$result=scheduleSeed($db,$now)+scheduleDispatch($db,$config,$now);echo json_encode($result,JSON_THROW_ON_ERROR).PHP_EOL;if(!empty($result['plan_errors']))exit(1);
}catch(Throwable $e){fwrite(STDERR,'SCHEDULE_FAILED: '.get_class($e).PHP_EOL);exit(1);}finally{flock($lock,LOCK_UN);}
