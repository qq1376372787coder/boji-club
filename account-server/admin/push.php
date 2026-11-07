<?php
// 推送管理页：设备与回执可观测、普通主动预算配置（范围校验+修改记录）、账号级手动停发。
$nowBj=new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai'));
$todayKey=$nowBj->format('Y-m-d');
$deviceStats=query('SELECT COUNT(*) total,COALESCE(SUM(enabled=1),0) enabled FROM club_push_devices')->fetch();
$receiptStats=query('SELECT status,COUNT(*) n FROM club_push_receipts GROUP BY status')->fetchAll();
$receiptByStatus=[];foreach($receiptStats as $r)$receiptByStatus[$r['status']]=(int)$r['n'];
$reasonTop=query("SELECT reason,COUNT(*) n FROM club_push_receipts WHERE status IN ('skipped','failed') AND reason IS NOT NULL GROUP BY reason ORDER BY n DESC LIMIT 8")->fetchAll();
$todayStats=query("SELECT COALESCE(SUM(status='sent'),0) sent,COALESCE(SUM(status='sent' AND budget_class='proactive'),0) proactive_sent,COALESCE(SUM(budget_class='proactive' AND status IN ('reserved','sent')),0) proactive_used,COALESCE(SUM(status='reserved'),0) reserved,COALESCE(SUM(status='failed'),0) failed FROM club_push_budget WHERE budget_day=?",[$todayKey])->fetch();
$limitRow=query("SELECT setting_value FROM club_push_settings WHERE setting_key='proactive_daily_limit'")->fetchColumn();
$proactiveLimit=max(0,min(20,$limitRow===false?1:(int)$limitRow));
$budgetHistory=query("SELECT a.*,b.username FROM admin_audit a LEFT JOIN admin_accounts b ON b.id=a.admin_id WHERE a.action='update_push_budget' ORDER BY a.id DESC LIMIT 10")->fetchAll();
$listPage=max(1,min(100000,(int)($_GET['page']??1)));$listOffset=($listPage-1)*20;
$blocks=query('SELECT b.*,u.status account_status,a.username blocked_by_name FROM club_push_account_blocks b JOIN users u ON u.id=b.user_id LEFT JOIN admin_accounts a ON a.id=b.blocked_by ORDER BY b.updated_at DESC,b.user_id LIMIT 21 OFFSET '.$listOffset)->fetchAll();
$moreBlocks=count($blocks)>20;$blocks=array_slice($blocks,0,20);
$reasonLabels=['NotNotifiable'=>'通知已关闭或当前不适用','BudgetExceeded'=>'今天的主动提醒次数已用完','SemanticDuplicate'=>'同一提醒已经发过','SourceCancelled'=>'相关任务已取消','SourceGone'=>'相关内容已删除','BadDeviceToken'=>'通知接收凭证失效','Unregistered'=>'该设备已停止接收通知','TransportUnavailable'=>'网络暂不可用','NetworkError'=>'网络错误','UnknownError'=>'未知错误'];
?>


<?php if($pagePanel==='statistics'):?><section class="card"><div class="section-head"><div><h2>今日统计</h2><p class="muted"><?=h($todayKey)?> · 北京时间</p></div></div>
<div class="metrics"><?php foreach([['今日已提交推送',safeNumber($todayStats['sent']??0),'苹果推送服务已接收的通知数。'],['其中主动跟进',safeNumber($todayStats['proactive_sent']??0),'系统主动发起的跟进通知。'],['已使用的主动提醒名额',safeNumber($todayStats['proactive_used']??0),'所有账号合计，包含正在重试的通知。'],['失败 / 等待重试',safeNumber($todayStats['failed']??0).' / '.safeNumber($todayStats['reserved']??0),'未能发出 / 稍后自动重试。']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<p class="muted">每位用户的次数上限，在“发送频率”中设置；失败重试不会重复占名额。</p>
</section><?php endif ?>
<?php if($pagePanel==='statistics'):?><section class="card"><div class="section-head"><div><h2>设备与回执</h2><p class="muted">通知设备与最近 7 天的发送结果。</p></div></div>
<div class="metrics"><?php foreach([['登记设备',safeNumber($deviceStats['total']??0),'累计登记的设备数'],['启用中',safeNumber($deviceStats['enabled']??0),'已在 App 中开启通知的设备。'],['等待发送',safeNumber($receiptByStatus['pending']??0),'尚未发出，或等待重新发送。'],['已提交给苹果',safeNumber($receiptByStatus['sent']??0),'苹果推送服务已接收，不代表用户已读。']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<div class="metrics"><?php foreach([['未发送',safeNumber($receiptByStatus['skipped']??0),'达到次数上限、重复通知或内容已失效。'],['发送失败',safeNumber($receiptByStatus['failed']??0),'多次重试后仍未发出的通知。']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<h3>未发送的主要原因</h3><?php foreach($reasonTop as $r):?><div class="stat-line"><span><?=h($reasonLabels[$r['reason']]??$r['reason'])?></span><strong><?=safeNumber($r['n'])?></strong></div><?php endforeach?><?php if(!$reasonTop):?><p class="empty">暂无跳过或失败记录</p><?php endif?>
</section><?php endif ?>
<?php if($pagePanel==='budget'):?><section class="card"><div class="section-head"><div><h2>每日主动提醒次数</h2><p class="muted">每天最多发给每位用户 0—20 条主动跟进提醒。填 0 暂停主动跟进；用户自行设置的提醒不受影响。</p></div></div>
<form method="post" data-confirm="保存后，下一次主动提醒会按新次数限制发送。是否继续？"><?php csrfField()?><input type="hidden" name="action" value="push_budget_update">
<div class="profile-grid"><label>每账号每日上限<input type="number" name="proactive_daily_limit" min="0" max="20" step="1" value="<?=$proactiveLimit?>" required><small>默认 1 条；训练/餐次提醒与报告通知不占此预算。</small></label></div>
<label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：内测打扰频次调整"></textarea></label>
<button>保存发送频率</button></form>
<details><summary>最近修改记录</summary><h3>修改记录</h3><?php foreach($budgetHistory as $item):?><div class="record"><p><?=h($item['detail'])?></p><small><?=h($item['username']??'管理员')?> · <?=h(stamp($item['created_at']))?></small></div><?php endforeach?><?php if(!$budgetHistory):?><p class="empty">暂无修改记录</p><?php endif?>
</details></section><?php endif ?>
<?php if($pagePanel==='blocks'):?><section class="card"><div class="section-head"><div><h2>手动停发账号推送</h2><p class="muted">停发后该账号所有设备不再收到推送；设备登记、回执与用户设置保留，恢复后继续调度。</p></div></div>
<form method="post" data-confirm="确认停发该账号的推送？"><?php csrfField()?><input type="hidden" name="action" value="push_block">
<div class="profile-grid"><label>成员编号或账号 ID<input name="user_id" maxlength="32" placeholder="例如 NO. 010001" required></label></div>
<label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：用户投诉打扰，临时停发"></textarea></label>
<button class="danger">停发该账号推送</button></form>
<?php $blockTotal=(int)query('SELECT COUNT(*) FROM club_push_account_blocks')->fetchColumn();?><h3>当前停发名单<?php if($blockTotal>count($blocks)):?> <small class="muted">共 <?=safeNumber($blockTotal)?> 个，显示最近 <?=count($blocks)?> 个</small><?php endif?></h3><div class="table-wrap"><table><thead><tr><th>成员</th><th>账号状态</th><th>原因</th><th>操作人 / 时间</th><th></th></tr></thead><tbody>
<?php foreach($blocks as $block):$blockId=(int)$block['user_id'];?><tr><td><a href="?p=user&amp;id=<?=$blockId?>"><?=h(clubNumber($blockId))?></a></td><td><?=badge($block['account_status'])?></td><td><?=h($block['reason'])?></td><td><?=h($block['blocked_by_name']??'管理员')?> · <?=h(stamp($block['updated_at']))?></td><td><details><summary>恢复</summary><form method="post" class="compact-form"><?php csrfField()?><input type="hidden" name="action" value="push_unblock"><input type="hidden" name="user_id" value="<?=$blockId?>"><input name="reason" required minlength="2" maxlength="200" placeholder="恢复原因"><button>恢复推送</button></form></details></td></tr><?php endforeach?>
<?php if(!$blocks):?><tr><td colspan="5" class="empty">当前没有停发中的账号</td></tr><?php endif?>
</tbody></table></div><?php adminPageCount($listPage,$moreBlocks);?></section><?php endif ?>
