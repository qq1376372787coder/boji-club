<?php
$root=dirname(__DIR__,2);$c=require $root.'/account-server/config.php';
if(!str_contains($c['dsn'],'dbname=boji136_admin_test;'))throw new RuntimeException('isolated DB required');
$db=new PDO($c['dsn'],$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
require $root.'/account-server/public/member-feedback.php';
$id=fbUUID128();$result=fbWrite128($db,1,$id,['client_id'=>fbUUID128(),'text'=>'测试：训练结束后无法查看总结，请帮忙检查。','attachments'=>[],'new'=>true,'category'=>'problem','metadata'=>['app_version'=>'0.15.9','build'=>'137','device_family'=>'iPhone','os_version'=>'26.0']]);
for($i=1;$i<=25;$i++){
 $db->prepare("INSERT INTO club_reward_catalog(kind,name,detail,icon,active,created_at,updated_at) SELECT 'badge',?,'隔离测试徽章','seal',1,UTC_TIMESTAMP(),UTC_TIMESTAMP() WHERE NOT EXISTS(SELECT 1 FROM club_reward_catalog WHERE name=?)")->execute(['Workspace-'.$i,'Workspace-'.$i]);
 $db->prepare("INSERT INTO notification_templates(category,name,title,body,created_at,updated_at) VALUES('training',?,'训练提醒','准备开始今天的训练。',UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE name=VALUES(name)")->execute(['Workspace-'.$i]);
}
$db->prepare("INSERT INTO club_seasons(slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,created_at,updated_at) VALUES('workspace-test','测试活动','真实参与规则','按完成记录统计','2026-10-01','2026-11-30','2026-11-01',UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE title=VALUES(title)")->execute();
$season=$db->query("SELECT id FROM club_seasons WHERE slug='workspace-test'")->fetchColumn();
$db->prepare("INSERT INTO club_tasks(season_id,title,detail,metric,target,created_at) SELECT ?,'训练三天','完成训练计一天','training_days',3,UTC_TIMESTAMP() WHERE NOT EXISTS(SELECT 1 FROM club_tasks WHERE season_id=?)")->execute([$season,$season]);
file_put_contents(sys_get_temp_dir().'/boji-workspace-fixture.json',json_encode(['ticket'=>$id,'last'=>$result['ticket']['last_message_id'],'season'=>$season]));
echo 'Synthetic workspace fixture ready'.PHP_EOL;
