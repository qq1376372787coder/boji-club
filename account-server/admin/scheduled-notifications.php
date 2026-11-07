<?php
declare(strict_types=1);
require_once dirname(__DIR__).'/public/scheduled-notifications.php';
function scheduleAdminAudience(array $post):array{
 $mode=(string)($post['audience_mode']??'selected');$refs=trim((string)($post['user_refs']??''));$ids=[];
 if($mode==='selected'&&$refs!=='')foreach(preg_split('/[,;\r\n]+/',$refs) as $value)$ids[]=adminMemberId(trim($value));
 return scheduleAudience(['mode'=>$mode,'user_ids'=>$ids]);
}
function scheduleAdminSave(PDO $db,array $post,int $adminId,bool $update):int{
 if(!scheduleReady($db))throw new RuntimeException('通知计划数据库尚未升级，请先完成服务部署。');
 if(isset($post['send_time'])){
  if(!preg_match('/^(\d{2}):(\d{2})$/D',(string)$post['send_time'],$match))throw new RuntimeException('请选择发送时间。');
  $post['hour']=(int)$match[1];$post['minute']=(int)$match[2];
 }
 $post['audience']=scheduleAdminAudience($post);$values=schedulePlanInput($post);$id=$update?(int)($post['id']??0):0;
 $db->beginTransaction();try{
  $template=scheduleQuery($db,'SELECT id,category FROM notification_templates WHERE id=? AND active=1',[$values['template_id']])->fetch();if(!$template)throw new RuntimeException('通知文案不存在，请重新选择。');
  $args=[$values['template_id'],$values['name'],$template['category'],$values['weekdays'],$values['hour'],$values['minute'],$values['timezone']];
  if($update){
   $old=scheduleQuery($db,'SELECT p.id,s.revision FROM notification_plans p LEFT JOIN notification_plan_settings s ON s.plan_id=p.id WHERE p.id=? FOR UPDATE',[$id])->fetch();if(!$old)throw new RuntimeException('计划不存在。');
   if((int)($post['expected_revision']??-1)!==(int)($old['revision']??0))throw new RuntimeException('计划已在其他窗口修改，请刷新后核对。');
   scheduleQuery($db,"UPDATE notification_plans SET template_id=?,name=?,category=?,weekdays=?,hour=?,minute=?,timezone=?,trigger_type='weekday',threshold=0,active=0,updated_at=UTC_TIMESTAMP() WHERE id=?",[...$args,$id]);
  }else{
   scheduleQuery($db,"INSERT INTO notification_plans(template_id,name,category,weekdays,hour,minute,timezone,trigger_type,threshold,active,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'weekday',0,0,UTC_TIMESTAMP(),UTC_TIMESTAMP())",$args);$id=(int)$db->lastInsertId();
  }
  scheduleQuery($db,"INSERT INTO notification_plan_settings(plan_id,state,revision,audience_json,updated_by,updated_at) VALUES(?,'draft',1,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE state='draft',revision=revision+1,audience_json=VALUES(audience_json),enabled_at=NULL,updated_by=VALUES(updated_by),updated_at=UTC_TIMESTAMP()",[$id,json_encode($values['audience'],JSON_THROW_ON_ERROR),$adminId]);
  $db->commit();return $id;
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
function scheduleAdminSetState(PDO $db,array $post,array $config,int $adminId,bool $publish):void{
 if(!scheduleReady($db))throw new RuntimeException('通知计划数据库尚未升级。');
 $id=filter_var($post['id']??null,FILTER_VALIDATE_INT);if(!$id)throw new RuntimeException('计划不存在。');
 if($publish){
  $hash=scheduleQuery($db,'SELECT password_hash FROM admin_accounts WHERE id=?',[$adminId])->fetchColumn();
  if(!$hash||!password_verify((string)($post['current_password']??''),$hash))throw new RuntimeException('管理员密码不正确。');
  if(!clubPushConfigured($config))throw new RuntimeException('苹果推送尚未配置，暂时不能启用自动发送。');
 }
 $db->beginTransaction();try{
  $p=scheduleQuery($db,'SELECT p.*,s.state,s.revision,s.audience_json FROM notification_plans p JOIN notification_plan_settings s ON s.plan_id=p.id WHERE p.id=? FOR UPDATE',[$id])->fetch();if(!$p)throw new RuntimeException('请先保存计划草稿。');
  if((int)($post['expected_revision']??-1)!==(int)$p['revision'])throw new RuntimeException('计划已在其他窗口修改，请刷新后核对。');
  if($publish){
   $t=scheduleQuery($db,'SELECT category FROM notification_templates WHERE id=? AND active=1 AND enabled=1',[$p['template_id']])->fetch();if(!$t)throw new RuntimeException('所选通知文案已停用，请先启用文案。');
   if($p['trigger_type']!=='weekday'||(int)$p['threshold']!==0)throw new RuntimeException('请先将旧版计划改为按星期定时，并重新保存。');
   $count=scheduleRecipientCount($db,scheduleAudience(json_decode($p['audience_json'],true)),$t['category']);
   if($count<1||$count>10000)throw new RuntimeException($count<1?'当前没有已开启通知的接收成员，不能启用。':'接收人数超过 10000，请缩小范围。');
   if(filter_var($post['confirmed_count']??null,FILTER_VALIDATE_INT)!==$count)throw new RuntimeException('接收人数已变化，请刷新并重新核对人数。');
  }
  scheduleQuery($db,'UPDATE notification_plan_settings SET state=?,revision=revision+1,enabled_at=?,updated_by=?,updated_at=UTC_TIMESTAMP() WHERE plan_id=?',[$publish?'enabled':'paused',$publish?gmdate('Y-m-d H:i:s'):null,$adminId,$id]);
  scheduleQuery($db,'UPDATE notification_plans SET active=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$publish?1:0,$id]);$db->commit();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
