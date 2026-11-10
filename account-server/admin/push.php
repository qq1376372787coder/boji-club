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
$blocks=query('SELECT b.*,u.status account_status,a.username blocked_by_name FROM club_push_account_blocks b JOIN users u ON u.id=b.user_id LEFT JOIN admin_accounts a ON a.id=b.blocked_by ORDER BY b.updated_at DESC LIMIT 50')->fetchAll();
$reasonLabels=['NotNotifiable'=>'开关关闭或不适用','BudgetExceeded'=>'普通主动预算已用完','SemanticDuplicate'=>'同语义组已有设备发送','SourceCancelled'=>'任务已删除或取消','SourceGone'=>'对象已失效（延后期间被删）','BadDeviceToken'=>'设备令牌失效','Unregistered'=>'设备已注销','TransportUnavailable'=>'网络暂不可用','NetworkError'=>'网络错误','UnknownError'=>'未知错误'];
?>
<section class="hero"><div><span class="eyebrow">CLUB PUSH</span><h2>每一次打扰，都有预算、有去重、有记录。</h2><p>普通主动推送按账号每日限量；用户明确设置的训练/餐次提醒与报告通知走各自开关，不占此预算。</p></div><span class="hero-mark">P</span></section>
<section class="card"><div class="section-head"><div><h2>今日统计</h2><p class="muted">「今日」按后台统计时区北京时间（Asia/Shanghai）计算，预算日同口径。今日 <?=h($todayKey)?>（北京）。</p></div></div>
<div class="metrics"><?php foreach([['今日送达（唯一语义组）',safeNumber($todayStats['sent']??0),'成功按唯一业务任务计数：同语义组一天至多一条，多设备不重复'],['其中普通主动',safeNumber($todayStats['proactive_sent']??0),'占用账号每日预算的主动跟进'],['普通主动预算占用',safeNumber($todayStats['proactive_used']??0).' / '.$proactiveLimit,'reserved+sent 合计；APNs 网络重试复用原预约，不重复扣减'],['发送失败 / 预约中',safeNumber($todayStats['failed']??0).' / '.safeNumber($todayStats['reserved']??0),'failed 为终态失败（允许接管重发）；reserved 为退避重试中']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<p class="muted">预算按账号级预约（同一事务、幂等）：发送前先占名额，被预算抑制的候选记为 skipped＋BudgetExceeded（可回执分布中核对），不是静默丢弃。</p>
</section>
<section class="card"><div class="section-head"><div><h2>设备与回执</h2><p class="muted">club_push_devices 设备数 · club_push_receipts 状态分布（保留 7 天）。</p></div></div>
<div class="metrics"><?php foreach([['登记设备',safeNumber($deviceStats['total']??0),'累计登记的设备数'],['启用中',safeNumber($deviceStats['enabled']??0),'enabled=1 且会参与调度'],['回执 pending',safeNumber($receiptByStatus['pending']??0),'排队或退避重试中'],['回执 sent',safeNumber($receiptByStatus['sent']??0),'已成功送达 APNs']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<div class="metrics"><?php foreach([['回执 skipped',safeNumber($receiptByStatus['skipped']??0),'预算抑制/语义去重/对象失效等，含原因'],['回执 failed',safeNumber($receiptByStatus['failed']??0),'重试 5 次后仍失败的终态记录']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<h3>跳过 / 失败原因 Top</h3><?php foreach($reasonTop as $r):?><div class="stat-line"><span><?=h($reasonLabels[$r['reason']]??$r['reason'])?><small> <?=h($r['reason'])?></small></span><strong><?=safeNumber($r['n'])?></strong></div><?php endforeach?><?php if(!$reasonTop):?><p class="empty">暂无跳过或失败记录</p><?php endif?>
</section>
<section class="card"><div class="section-head"><div><h2>普通主动推送预算</h2><p class="muted">每账号每日上限，范围 0—20；0 表示暂停发送普通主动推送。只约束打扰用户的主动推送，不限制首页新洞察；修改会记入操作记录。</p></div></div>
<form method="post" data-confirm="确认保存普通主动推送预算？下次发送预约时生效。"><?php csrfField()?><input type="hidden" name="action" value="push_budget_update">
<div class="profile-grid"><label>每账号每日上限<input type="number" name="proactive_daily_limit" min="0" max="20" step="1" value="<?=$proactiveLimit?>" required><small>默认 1 条；训练/餐次提醒与报告通知不占此预算。</small></label></div>
<label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：内测打扰频次调整"></textarea></label>
<button>保存预算设置</button></form>
<h3>修改记录</h3><?php foreach($budgetHistory as $item):?><div class="record"><p><?=h($item['detail'])?></p><small><?=h($item['username']??'管理员')?> · <?=h(stamp($item['created_at']))?></small></div><?php endforeach?><?php if(!$budgetHistory):?><p class="empty">暂无修改记录</p><?php endif?>
</section>
<section class="card"><div class="section-head"><div><h2>手动停发账号推送</h2><p class="muted">停发后该账号所有设备不再收到推送；设备登记、回执与用户设置保留，恢复后继续调度。</p></div></div>
<form method="post" data-confirm="确认停发该账号的推送？"><?php csrfField()?><input type="hidden" name="action" value="push_block">
<div class="profile-grid"><label>成员编号（user_id）<input type="number" name="user_id" min="1" step="1" required></label></div>
<label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：用户投诉打扰，临时停发"></textarea></label>
<button class="danger">停发该账号推送</button></form>
<h3>当前停发名单</h3><div class="table-wrap"><table><thead><tr><th>成员</th><th>账号状态</th><th>原因</th><th>操作人 / 时间</th><th></th></tr></thead><tbody>
<?php foreach($blocks as $block):$blockId=(int)$block['user_id'];?><tr><td><a href="?p=user&amp;id=<?=$blockId?>"><?=h(clubNumber($blockId))?></a></td><td><?=badge($block['account_status'])?></td><td><?=h($block['reason'])?></td><td><?=h($block['blocked_by_name']??'管理员')?> · <?=h(stamp($block['updated_at']))?></td><td><details><summary>恢复</summary><form method="post" class="compact-form"><?php csrfField()?><input type="hidden" name="action" value="push_unblock"><input type="hidden" name="user_id" value="<?=$blockId?>"><input name="reason" required minlength="2" maxlength="200" placeholder="恢复原因"><button>恢复推送</button></form></details></td></tr><?php endforeach?>
<?php if(!$blocks):?><tr><td colspan="5" class="empty">当前没有停发中的账号</td></tr><?php endif?>
</tbody></table></div></section>
