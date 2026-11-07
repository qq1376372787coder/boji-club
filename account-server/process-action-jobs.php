<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require_once __DIR__.'/public/app-config.php';require_once __DIR__.'/public/ai-router.php';require_once __DIR__.'/public/ai-response.php';require_once __DIR__.'/public/cloud-validation.php';
$config=require __DIR__.'/config.php';$GLOBALS['config']=$config;
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
function lockActiveUser(PDO $db,int $uid):void{$q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn())throw new RuntimeException('inactive_account');}
function fail(string $message,int $code=400):never{businessReject($code,['error'=>$message]);}
echo json_encode(['plans'=>actionProcessPlanJobs($db,$config),'messages'=>actionProcessMessages($db,$config)])."\n";
