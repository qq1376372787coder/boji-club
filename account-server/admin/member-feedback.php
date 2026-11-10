<?php
require_once dirname(__DIR__).'/public/member-feedback.php';
function fbAdminPost128(PDO $db,string $action):void{
 if(!in_array($action,['feedback_reply','feedback_status'],true))return;
 requireAdminPage('feedback');requireAdminWrite($action);
 $id=fbID128($_POST['ticket_id']??null);$t=fbQuery128($db,'SELECT * FROM member_feedback_tickets WHERE id=?',[$id])->fetch();if(!$t)fbError128('反馈不存在。',404);
 if($action==='feedback_reply'){
  fbWrite128($db,(int)$t['user_id'],$id,['client_id'=>$_POST['client_id']??null,'text'=>$_POST['text']??'','attachments'=>[],'expected_last_message_id'=>(int)($_POST['last_message_id']??-1)],(int)$GLOBALS['admin']['id']);flash('回复已保存，用户可在 App 中查看。');
 }else{
  $status=$_POST['status']??'';if(!in_array($status,['open','closed'],true))fbError128('状态不正确。');
  $db->beginTransaction();try{fbLock128($db,(int)$t['user_id']);$fresh=fbQuery128($db,'SELECT last_message_id FROM member_feedback_tickets WHERE id=? FOR UPDATE',[$id])->fetchColumn();if((int)$fresh!==(int)($_POST['last_message_id']??-1))fbError128('反馈已有新消息，请刷新后再更新状态。',409);fbQuery128($db,'UPDATE member_feedback_tickets SET status=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$status,$id]);audit('status_member_feedback',(int)$t['user_id'],'反馈 '.$id.' → '.$status);$db->commit();}catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}flash($status==='closed'?'已标记为已解决。':'已重新打开反馈。');
 }
 redirect('feedback','&ticket='.rawurlencode($id));
}
function fbAdminPanel128(PDO $db):void{
 $labels=['open'=>'待回复','replied'=>'已回复','closed'=>'已解决'];$types=['problem'=>'问题反馈','suggestion'=>'功能建议','other'=>'其他'];
 $id=$_GET['ticket']??'';
 if($id!==''){
  $t=fbQuery128($db,'SELECT t.*,p.nickname FROM member_feedback_tickets t LEFT JOIN profiles p ON p.user_id=t.user_id WHERE t.id=?',[fbID128($id)])->fetch();
  if(!$t){echo '<section class="card"><p>反馈不存在。</p></section>';return;}
  $before=max(0,(int)($_GET['before']??0));$detail=fbDetail128($db,(int)$t['user_id'],$id,$before);$meta=json_decode($t['metadata_json'],true)??[];
  ?>
  <p><a href="?p=feedback">← 返回反馈列表</a></p>
  <section class="card"><div class="section-head"><div><h2><?=h($t['title'])?></h2><p><?=h($types[$t['category']])?> · <?=h($labels[$t['status']])?> · <?=h(stamp($t['created_at']))?></p></div><a href="?p=user&amp;id=<?=(int)$t['user_id']?>"><?=h($t['nickname']?:clubNumber((int)$t['user_id']))?></a></div><p class="muted">版本 <?=h(($meta['app_version']??'—').' / Build '.($meta['build']??'—'))?> · <?=h(($meta['device_family']??'').' '.($meta['os_version']??''))?></p><small class="muted">反馈编号 <?=h($id)?></small></section>
  <?php if($detail['has_older']):?><p><a href="?p=feedback&amp;ticket=<?=h($id)?>&amp;before=<?=(int)$detail['messages'][0]['id']?>">查看更早消息</a> · <a href="?p=feedback&amp;ticket=<?=h($id)?>">回到最新</a></p><?php endif?>
  <?php foreach($detail['messages'] as $m):?><section class="card feedback-message"><div class="section-head"><strong><?=$m['author']==='admin'?'薄肌俱乐部回复':'用户反馈'?></strong><small><?=h(stamp(substr($m['created_at'],0,19)))?></small></div><p class="prose"><?=nl2br(h($m['text']))?></p><div class="feedback-media-grid"><?php foreach($m['attachments'] as $a):$url='?p=feedback_media&id='.rawurlencode($a['id']);?>
  <figure><?php if($a['kind']==='image'):?><a href="<?=h($url)?>" target="_blank" rel="noopener"><img src="<?=h($url)?>" alt="用户反馈照片" loading="lazy"></a><?php else:?><video controls preload="metadata" playsinline src="<?=h($url)?>"></video><?php endif?><figcaption><?=h($a['kind']==='image'?'照片':'视频')?> · <?=number_format($a['bytes']/1048576,1)?> MB</figcaption></figure><?php endforeach?></div></section><?php endforeach?>
  <?php if(adminCanWriteAction('feedback_reply')):?><section class="card"><h2>回复用户</h2><form method="post"><?php csrfField()?><input type="hidden" name="action" value="feedback_reply"><input type="hidden" name="ticket_id" value="<?=h($id)?>"><input type="hidden" name="last_message_id" value="<?=(int)$t['last_message_id']?>"><input type="hidden" name="client_id" value="<?=h(fbUUID128())?>"><label>回复内容<textarea name="text" maxlength="4000" required rows="5" placeholder="告诉用户处理结果，或需要补充哪些信息。"><?=h($_POST['text']??'')?></textarea></label><button>保存回复</button><p class="muted">回复后用户可在 App 的“反馈与回复”中查看，显示未读标记。</p></form></section>
  <section class="card"><form method="post"><?php csrfField()?><input type="hidden" name="action" value="feedback_status"><input type="hidden" name="ticket_id" value="<?=h($id)?>"><input type="hidden" name="last_message_id" value="<?=(int)$t['last_message_id']?>"><input type="hidden" name="status" value="<?=$t['status']==='closed'?'open':'closed'?>"><button class="quiet"><?=$t['status']==='closed'?'重新打开':'标记已解决'?></button></form></section><?php endif;
  return;
 }
 $status=$_GET['status']??'all';if(!in_array($status,['all','open','replied','closed'],true))$status='all';$q=mb_substr(trim((string)($_GET['q']??'')),0,100);$page=max(1,min(100000,(int)($_GET['page']??1)));$args=[];$where='1=1';
 if($status!=='all'){$where.=' AND t.status=?';$args[]=$status;}
 if($q!==''){$where.=' AND (t.title LIKE ? OR t.id=? OR CAST(t.user_id AS CHAR)=? OR p.nickname LIKE ?)';array_push($args,'%'.$q.'%',$q,$q,'%'.$q.'%');}
 $offset=($page-1)*20;$rows=fbQuery128($db,"SELECT t.*,p.nickname FROM member_feedback_tickets t LEFT JOIN profiles p ON p.user_id=t.user_id WHERE $where ORDER BY t.updated_at DESC,t.id DESC LIMIT 21 OFFSET $offset",$args)->fetchAll();$more=count($rows)>20;$rows=array_slice($rows,0,20);
 ?>
 <section class="card"><form method="get" class="filters"><input type="hidden" name="p" value="feedback"><label>状态<select name="status"><?php foreach(['all'=>'全部']+$labels as $key=>$name):?><option value="<?=h($key)?>" <?=$status===$key?'selected':''?>><?=h($name)?></option><?php endforeach?></select></label><label>查找反馈<input name="q" value="<?=h($q)?>" maxlength="100" placeholder="标题、昵称、用户编号或反馈编号"></label><button>筛选</button></form></section>
 <section class="card"><div class="table-wrap"><table><thead><tr><th>反馈</th><th>成员</th><th>状态</th><th>更新时间</th><th></th></tr></thead><tbody><?php foreach($rows as $t):?><tr><td><strong><?=h($t['title'])?></strong><small><?=h($types[$t['category']])?></small></td><td><?=h($t['nickname']?:clubNumber((int)$t['user_id']))?></td><td><?=h($labels[$t['status']])?></td><td><?=h(stamp($t['updated_at']))?></td><td><a href="?p=feedback&amp;ticket=<?=h($t['id'])?>">查看与回复 →</a></td></tr><?php endforeach;if(!$rows):?><tr><td colspan="5" class="empty">暂无符合条件的反馈</td></tr><?php endif?></tbody></table></div><p><?php if($page>1):?><a href="?<?=h(http_build_query(['p'=>'feedback','status'=>$status,'q'=>$q,'page'=>$page-1]))?>">上一页</a> <?php endif?>第 <?=$page?> 页 <?php if($more):?><a href="?<?=h(http_build_query(['p'=>'feedback','status'=>$status,'q'=>$q,'page'=>$page+1]))?>">下一页</a><?php endif?></p></section>
 <?php
}
