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
 $status=$_GET['status']??'all';if(!isset(($labels+['all'=>'全部'])[$status]))$status='all';
 $q=mb_substr(trim((string)($_GET['q']??'')),0,100);$page=max(1,min(100000,(int)($_GET['page']??1)));$args=[];$where='1=1';
 if($status!=='all'){$where.=' AND t.status=?';$args[]=$status;}
 if($q!==''){$where.=' AND (t.title LIKE ? OR t.id=? OR CAST(t.user_id AS CHAR)=? OR p.nickname LIKE ?)';array_push($args,'%'.$q.'%',$q,$q,'%'.$q.'%');}
 $offset=($page-1)*20;$rows=fbQuery128($db,"SELECT t.*,p.nickname FROM member_feedback_tickets t LEFT JOIN profiles p ON p.user_id=t.user_id WHERE $where ORDER BY t.updated_at DESC,t.id DESC LIMIT 21 OFFSET $offset",$args)->fetchAll();$more=count($rows)>20;$rows=array_slice($rows,0,20);
 $id=(string)($_GET['ticket']??'');$ticket=null;
 if($id!=='')$ticket=fbQuery128($db,'SELECT t.*,p.nickname FROM member_feedback_tickets t LEFT JOIN profiles p ON p.user_id=t.user_id WHERE t.id=?',[fbID128($id)])->fetch()?:null;
 $url=static fn(array $values)=>adminUrl($values+['p'=>'feedback','status'=>$status,'q'=>$q,'page'=>$page],false);
 ?>
 <form method="get" class="filters section-filter"><input type="hidden" name="p" value="feedback"><label>状态<select name="status"><?php foreach(['all'=>'全部']+$labels as $key=>$name):?><option value="<?=h($key)?>" <?=$status===$key?'selected':''?>><?=h($name)?></option><?php endforeach?></select></label><label>查找反馈<input name="q" value="<?=h($q)?>" maxlength="100" placeholder="标题、昵称或成员编号"></label><button>搜索</button></form>
 <div class="feedback-workspace"><aside class="card ticket-list" aria-label="反馈列表"><div class="section-head"><h2>反馈工单</h2><small>第 <?=$page?> 页</small></div>
 <?php foreach($rows as $row):?><a class="ticket-row <?=$row['id']===$id?'selected':''?>" href="<?=h($url(['ticket'=>$row['id']]))?>" <?=$row['id']===$id?'aria-current="page"':''?>><span class="ticket-row-top"><strong><?=h($row['title'])?></strong><span class="badge <?=$row['status']==='open'?'pending':'disabled'?>"><?=h($labels[$row['status']])?></span></span><small><?=h($row['nickname']?:clubNumber((int)$row['user_id']))?> · <?=h(stamp($row['updated_at']))?></small></a><?php endforeach?>
 <?php if(!$rows):?><p class="empty">暂无符合条件的反馈</p><?php endif?>
 <nav class="pagination" aria-label="反馈翻页"><?php if($page>1):?><a href="<?=h($url(['page'=>$page-1]))?>">上一页</a><?php endif?><?php if($more):?><a href="<?=h($url(['page'=>$page+1]))?>">下一页</a><?php endif?></nav></aside>
 <section class="card ticket-detail" aria-label="反馈详情">
 <?php if(!$ticket):?><div class="ticket-placeholder"><h2><?=$id!==''?'反馈不存在':'选择一条反馈'?></h2><p class="muted">在这里查看附件并回复用户。</p></div><?php else:
 $before=max(0,(int)($_GET['before']??0));$detail=fbDetail128($db,(int)$ticket['user_id'],$id,$before);$meta=json_decode($ticket['metadata_json'],true)??[];
 ?>
 <header class="ticket-header"><div><h2><?=h($ticket['title'])?></h2><p class="muted"><?=h($types[$ticket['category']])?> · <?=h($labels[$ticket['status']])?> · <a data-member-drawer href="?p=user&amp;id=<?=(int)$ticket['user_id']?>"><?=h($ticket['nickname']?:clubNumber((int)$ticket['user_id']))?></a></p></div>
 <?php if(adminCanWriteAction('feedback_status')):?><form method="post" data-inline-editor><?php csrfField()?><input type="hidden" name="action" value="feedback_status"><input type="hidden" name="ticket_id" value="<?=h($id)?>"><input type="hidden" name="last_message_id" value="<?=(int)$ticket['last_message_id']?>"><input type="hidden" name="status" value="<?=$ticket['status']==='closed'?'open':'closed'?>"><button class="secondary"><?=$ticket['status']==='closed'?'重新打开':'标记已解决'?></button></form><?php endif?></header>
 <details class="ticket-metadata"><summary>设备与版本</summary><p>版本 <?=h(($meta['app_version']??'—').' / Build '.($meta['build']??'—'))?> · <?=h(($meta['device_family']??'').' '.($meta['os_version']??''))?></p><small>反馈编号 <?=h($id)?></small></details>
 <div class="ticket-conversation" tabindex="0" aria-label="反馈消息">
 <?php if($detail['has_older']):?><a href="<?=h($url(['ticket'=>$id,'before'=>(int)$detail['messages'][0]['id']]))?>">查看更早消息</a><?php endif?><?php if($before):?><a href="<?=h($url(['ticket'=>$id]))?>">回到最新</a><?php endif?>
 <?php foreach($detail['messages'] as $m):?><article class="ticket-message <?=$m['author']==='admin'?'from-admin':''?>"><div class="section-head"><strong><?=$m['author']==='admin'?'俱乐部回复':'用户'?></strong><small><?=h(stamp(substr($m['created_at'],0,19)))?></small></div><p class="prose"><?=nl2br(h($m['text']))?></p><div class="feedback-media-grid"><?php foreach($m['attachments'] as $attachment):$mediaUrl='?p=feedback_media&id='.rawurlencode($attachment['id']);?><figure><?php if($attachment['kind']==='image'):?><a href="<?=h($mediaUrl)?>" target="_blank" rel="noopener"><img src="<?=h($mediaUrl)?>" alt="反馈照片，点击查看原图" loading="lazy"></a><?php else:?><video controls preload="metadata" playsinline src="<?=h($mediaUrl)?>"></video><?php endif?><figcaption><?=number_format($attachment['bytes']/1048576,1)?> MB</figcaption></figure><?php endforeach?></div></article><?php endforeach?></div>
 <?php if(adminCanWriteAction('feedback_reply')):?><form method="post" class="ticket-reply" data-inline-editor><?php csrfField()?><input type="hidden" name="action" value="feedback_reply"><input type="hidden" name="ticket_id" value="<?=h($id)?>"><input type="hidden" name="last_message_id" value="<?=(int)$ticket['last_message_id']?>"><input type="hidden" name="client_id" value="<?=h($_POST['client_id']??fbUUID128())?>"><label>回复用户<textarea name="text" maxlength="4000" required rows="3" placeholder="输入处理结果，或询问需要补充的信息。"><?=h(($_POST['action']??'')==='feedback_reply'?($_POST['text']??''):'')?></textarea></label><div class="section-head"><small class="muted">用户可在 App 中查看回复</small><button>发送回复</button></div></form><?php endif?>
 <?php endif?></section></div>
 <?php
}
