<?php
declare(strict_types=1);
// Applies reviewed public activity wording only. IDs, targets, rewards and user records remain unchanged.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$mode=$argv[1]??'check';
if (!in_array($mode,['check','apply'],true)) throw new RuntimeException('Use check or apply');
$configPath=$argv[2]??__DIR__.'/config.php';
$backupPath=$argv[3]??__DIR__.'/copy-before-20261002.json';
$c=require $configPath;
$db=new PDO($c['dsn'],$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$edits=[
 ['club_seasons',2,'subtitle','认真完成这一期，解锁属于你的 Club Keepsake。','完成本期任务，收藏你的 Club Keepsake。'],
 ['club_seasons',2,'official_note','把训练、饮食和每周复盘变成一条真实可追踪的成长路线。','把训练、饮食和每周回顾串起来，记录这段时间的变化。'],
 ['club_seasons',2,'rules_text','任务进度以 App 中已保存并同步的训练、饮食和周复盘记录为准。完成核心任务后可领取本期 Club Keepsake。','任务进度以活动期间已确认并同步的训练、饮食和每周回顾记录为准。训练任务需在 3 个不同日期完成至少一组并确认记录；饮食任务需在 5 个不同日期各记录至少一餐；每周回顾任务需完成一次 AI 分析。每个奖励按对应任务解锁。本期 Club Keepsake 为电子徽章，获得后进入个人收藏。'],
 ['club_tasks',8,'title','完成本季核心任务','完成 3 个训练日，收藏 Club Keepsake'],
 ['club_tasks',8,'detail','完成本季核心任务后，解锁本期实体 Club Keepsake。','在 3 个不同日期完成至少一组训练，确认并同步记录后，获得本期 Club Keepsake（电子徽章）。'],
 ['club_tasks',5,'detail','完成真实训练，不需要一次练很久，先让节奏稳定下来。','在 3 个不同日期完成至少一组训练，并确认、同步记录。先找到适合自己的节奏。'],
 ['club_tasks',6,'detail','每天至少记录一餐，让饮食和训练开始互相印证。','在 5 个不同日期，各保存并同步至少一餐，即可完成任务。'],
 ['club_tasks',7,'detail','结合训练、饮食和身体感受，看看这一周发生了什么。','完成一次每周回顾的 AI 分析并同步结果，回看训练、饮食和身体感受。'],
 ['club_tasks',7,'title','完成一次周复盘','完成一次每周回顾'],
 ['club_rewards',5,'title','First Light','初光纪念 · First Light'],
];
$db->beginTransaction();
try {
 $season=$db->query('SELECT id,title,status FROM club_seasons WHERE id=2 FOR UPDATE')->fetch();
 if (!$season || $season['title']!=='十月成长季' || !in_array($season['status'],['published','archived'],true)) throw new RuntimeException('Activity changed; re-review required');
 $types=$db->query('SELECT id,reward_type FROM club_rewards WHERE season_id=2 ORDER BY id FOR UPDATE')->fetchAll();
 if (array_map('intval',array_column($types,'id'))!==[5,6,7,8] || array_filter($types,fn($x)=>$x['reward_type']!=='badge')) throw new RuntimeException('Reward types changed; re-review required');
 $tasks=$db->query('SELECT id,metric,target FROM club_tasks WHERE season_id=2 ORDER BY id FOR UPDATE')->fetchAll();
 $shape=array_map(fn($x)=>[(int)$x['id'],$x['metric'],(int)$x['target']],$tasks);
 if ($shape!==[[5,'training_days',3],[6,'meal_days',5],[7,'weekly_reviews',1],[8,'training_days',3]]) throw new RuntimeException('Task conditions changed; re-review required');
 $before=[];$pending=[];
 foreach($edits as [$table,$id,$field,$old,$new]) {
  $q=$db->prepare("SELECT $field FROM $table WHERE id=? FOR UPDATE");$q->execute([$id]);$row=$q->fetch();
  if (!$row) throw new RuntimeException('Missing activity record');
  if ($row[$field]===$new) continue;
  if ($row[$field]!==$old) throw new RuntimeException('Copy changed; re-review required');
  $before[]=['table'=>$table,'id'=>$id,'field'=>$field,'before'=>$old,'after'=>$new];
  $pending[]=[$table,$id,$field,$old,$new];
 }
 if ($mode==='check') {$db->rollBack();echo json_encode(['ready'=>true,'text_fields_to_update'=>count($pending)]),PHP_EOL;exit;}
 if ($pending) {
  $backup=['date_utc'=>gmdate('c'),'scope'=>'Public wording only','changes'=>$before];
  if (file_exists($backupPath)) throw new RuntimeException('Backup already exists; use a new path');
  if (file_put_contents($backupPath,json_encode($backup,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR),LOCK_EX)===false) throw new RuntimeException('Backup write failed');
  chmod($backupPath,0600);
 }
 foreach($pending as [$table,$id,$field,$old,$new]) {
  $q=$db->prepare("UPDATE $table SET $field=? WHERE id=? AND $field=?");$q->execute([$new,$id,$old]);
  if ($q->rowCount()!==1) throw new RuntimeException('Concurrent copy edit; aborting');
 }
 $db->commit();echo json_encode(['applied'=>true,'text_fields_updated'=>count($pending),'backup_created'=>(bool)$pending]),PHP_EOL;
} catch(Throwable $e) {if($db->inTransaction())$db->rollBack();throw $e;}
