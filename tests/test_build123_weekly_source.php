<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/context-continuation.php';
const TEST_JOB='12345678-1234-1234-1234-123456789012';
class SourceStatement123 extends PDOStatement {
 private array $parameters=[];
 public function __construct() {}
 public function execute(?array $params=null):bool {$this->parameters=$params??[];return true;}
 public function fetch(int $mode=PDO::FETCH_DEFAULT,int $cursorOrientation=PDO::FETCH_ORI_NEXT,int $cursorOffset=0):mixed {
  if(($this->parameters[0]??0)!==7||($this->parameters[1]??'')!==TEST_JOB)return false;
  return ['client_job_id'=>TEST_JOB,'server_job_id'=>TEST_JOB,'kind'=>'coach','created_at'=>'2020-01-15 12:00:00','completed_at'=>'2020-01-15 12:01:00'];
 }
}
class SourcePDO123 extends PDO {
 public function __construct() {}
 public function prepare(string $query,array $options=[]):PDOStatement|false {return new SourceStatement123();}
}
$GLOBALS['boji_action_transport']=fn()=>['status'=>'succeeded','result'=>['kind'=>'coach','coach'=>['purpose'=>$GLOBALS['purpose123']??'weekly','answer'=>'已保存的周度解读']]];
$db=new SourcePDO123();$source=['type'=>'weekly','id'=>TEST_JOB,'summary'=>'客户端伪造全文'];
$snapshot=contextSourceResolve($db,7,$source);
if(($snapshot['summary']??'')!=='已保存的周度解读')throw new RuntimeException('did not use saved weekly result');
if(contextSourcePrompt($snapshot)['type']!=='weekly')throw new RuntimeException('lost typed weekly source');
function rejects123(callable $fn,int $code):void {try{$fn();}catch(RuntimeException $e){if($e->getCode()===$code)return;throw $e;}throw new RuntimeException('invalid source accepted');}
rejects123(fn()=>contextSourceResolve($db,8,$source),404);
rejects123(fn()=>contextSourceResolve($db,7,$source+['version'=>'old']),409);
$GLOBALS['purpose123']='dialogue';rejects123(fn()=>contextSourceResolve($db,7,$source),409);
unset($GLOBALS['boji_action_transport'],$GLOBALS['purpose123']);
echo "PASS 5 frozen weekly source and ownership/version/type checks (isolated PDO/transport fixtures)\n";
