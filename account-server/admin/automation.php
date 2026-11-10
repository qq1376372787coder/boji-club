<?php
// 自动化任务页：club_automation 账号调度、有界重试与今日统计。所有写操作经 bootstrap.php 审计。
$nowBj=new DateTimeImmutable('now',new DateTimeZone('Asia/Shanghai'));
$todayKey=$nowBj->format('Y-m-d');
$dayStartUtc=$nowBj->setTime(0,0)->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d H:i:s');
$runStats=query("SELECT COUNT(*) total,COALESCE(SUM(tasks_submitted),0) tasks,COALESCE(SUM(vendor_attempts),0) attempts,COALESCE(SUM(outcome IN ('submitted','checked','needs_record_check')),0) ok,COALESCE(SUM(outcome='failed'),0) failed,COALESCE(SUM(outcome='skipped'),0) cancelled,COALESCE(SUM(outcome='retry_pending'),0) retrying,COALESCE(SUM(outcome='running'),0) running FROM club_automation_runs WHERE started_at>=?",[$dayStartUtc])->fetch();
$counts=query("SELECT COALESCE(SUM(enabled=1 AND paused=0 AND next_run>UTC_TIMESTAMP()),0) queued,COALESCE(SUM(enabled=1 AND paused=0 AND next_run<=UTC_TIMESTAMP()),0) due,COALESCE(SUM(paused=1),0) paused,COALESCE(SUM(enabled=0),0) disabled,COALESCE(SUM(last_status LIKE 'failed%'),0) failed,COALESCE(SUM((retry_count>0 OR last_status='retry_pending') AND last_status NOT LIKE 'failed%'),0) retrying FROM club_automation")->fetch();
$rows=query('SELECT a.*,u.status account_status,(SELECT MAX(r.finished_at) FROM club_automation_runs r WHERE r.user_id=a.user_id) last_run FROM club_automation a JOIN users u ON u.id=a.user_id ORDER BY a.next_run LIMIT 200')->fetchAll();
$runs=query('SELECT r.*,u.status account_status FROM club_automation_runs r JOIN users u ON u.id=r.user_id ORDER BY r.id DESC LIMIT 40')->fetchAll();
$retryLimit=max(1,min(20,(int)($config['automation_max_retries']??6)));
$statusLabels=['submitted'=>'已提交','checked'=>'已检查','needs_record_check'=>'待核对记录','retry_pending'=>'重试中','failed'=>'失败','skipped'=>'跳过','running'=>'处理中'];
?>
<section class="hero"><div><span class="eyebrow">CLUB AUTOMATION</span><h2>让自动跟进可暂停、可恢复、有边界。</h2><p>每个账号的调度状态、有界重试与执行记录都在这里；重试不会记成用户使用次数。</p></div><span class="hero-mark">A</span></section>
<section class="card"><div class="section-head"><div><h2>今日统计</h2><p class="muted">「今日」按后台统计时区北京时间（Asia/Shanghai）计算，与 AI 每日额度口径一致。今日始于 <?=h($todayKey)?> 00:00（北京）。</p></div></div>
<div class="metrics"><?php foreach([['业务任务（唯一）',safeNumber($runStats['tasks']??0),'成功按唯一业务任务计数；同一任务的修复重提不重复累计'],['供应商尝试',safeNumber($runStats['attempts']??0),'含自动重试的提交尝试，不计为用户使用次数，也不扣 AI 额度'],['成功批次',safeNumber($runStats['ok']??0),'今日完成的处理批次（提交/已检查/待核对）'],['重试中',safeNumber($runStats['retrying']??0),'失败退避或时间盒未跑完，稍后自动继续']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<div class="metrics"><?php foreach([['失败批次',safeNumber($runStats['failed']??0),'连续失败达到 '.$retryLimit.' 次后进入终态 failed'],['取消 / 跳过',safeNumber($runStats['cancelled']??0),'未启用、无数据、会员过期或配置变更等跳过'],['处理中',safeNumber($runStats['running']??0),'当前正在执行的批次；超过 10 分钟自动记为中断'],['今日批次',safeNumber($runStats['total']??0),'今日已开始的处理批次总数']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<p class="muted">业务任务按唯一 client_job 计数，供应商尝试是实际提交次数（含修复重提）；两者分开统计，避免把重试次数记成用户使用次数。</p>
</section>
<section class="card"><div class="section-head"><h2>调度概览</h2><span class="muted">排队 / 处理中 / 重试 / 失败</span></div>
<div class="metrics"><?php foreach([['排队中',safeNumber($counts['queued']??0),'已启用且等待 next_run 到点'],['到点待跑',safeNumber($counts['due']??0),'next_run 已到，等待调度器领取'],['重试中',safeNumber($counts['retrying']??0),'失败退避中，未达上限'],['失败（终态）',safeNumber($counts['failed']??0),'重试已达上限，等待配置变更或手动重跑']] as [$label,$value,$hint]):?><article><span class="muted"><?=$label?></span><b><?=$value?></b><small><?=$hint?></small></article><?php endforeach?></div>
<p class="muted">另有后台暂停 <?=safeNumber($counts['paused']??0)?> 个 · 用户未启用 <?=safeNumber($counts['disabled']??0)?> 个。同一配置版本内最多尝试 <?=$retryLimit?> 次（含首次），仍失败则进入终态 failed 并在 last_status 写明错误摘要；用户再次保存配置或后台“手动重跑”会清零重试计数。</p>
</section>
<section class="card"><div class="section-head"><h2>账号调度列表</h2><span class="muted">按 next_run 排序 · 最多 200 个</span></div>
<div class="table-wrap"><table><thead><tr><th>成员</th><th>revision / 启用</th><th>next_run</th><th>last_status</th><th>重试</th><th>最近执行</th><th>应执行但跳过的原因</th><th>操作</th></tr></thead><tbody>
<?php foreach($rows as $row):
 $skipReason='—';
 if((int)$row['paused']===1)$skipReason='管理后台暂停'.(($row['paused_reason']??'')!==''?'：'.h($row['paused_reason']):'');
 elseif((int)$row['enabled']===0)$skipReason='未启用（用户未开启自动跟进）';
 elseif(str_starts_with((string)$row['last_status'],'failed'))$skipReason='重试已达上限，进入终态；待配置变更或手动重跑';
 elseif($row['last_status']==='membership_required')$skipReason='会员已过期，已跳过';
 elseif($row['last_status']==='no_data')$skipReason='无数据（近 35 天无训练/饮食记录）';
 elseif($row['last_status']==='account_inactive')$skipReason='账号已停用';
 $rowId=(int)$row['user_id'];
?><tr><td><strong><?=h(clubNumber($rowId))?></strong><small><?=badge($row['account_status'])?></small></td>
<td><?=safeNumber($row['revision'])?> · <?=$row['enabled']?'启用':'停用'?><?=$row['paused']?' · 暂停中':''?></td>
<td><?=h(stamp($row['next_run']))?></td>
<td><?=h((string)($row['last_status']??'—'))?></td>
<td><?=safeNumber($row['retry_count'])?> / <?=$retryLimit?></td>
<td><?=h(stamp($row['last_run']))?></td>
<td><?=$skipReason?></td>
<td><details><summary>操作</summary><form method="post" class="compact-form"><?php csrfField()?><input type="hidden" name="user_id" value="<?=$rowId?>">
<select name="action"><option value="automation_pause">暂停调度</option><option value="automation_resume">恢复调度</option><option value="automation_rerun">手动重跑（清零重试）</option></select>
<input name="reason" required minlength="2" maxlength="200" placeholder="操作原因（写入操作记录）">
<button>执行</button></form>
<a href="?p=user&amp;id=<?=$rowId?>">成员档案 ↗</a></details></td></tr>
<?php endforeach?>
<?php if(!$rows):?><tr><td colspan="8" class="empty">暂无自动跟进配置</td></tr><?php endif?>
</tbody></table></div></section>
<section class="card"><div class="section-head"><div><h2>最近执行记录</h2><p class="muted">保留 30 天。业务任务与供应商尝试分列，重试不算用户使用次数。</p></div></div>
<div class="table-wrap"><table><thead><tr><th>开始时间</th><th>成员</th><th>结果</th><th>业务任务</th><th>供应商尝试</th><th>错误摘要</th></tr></thead><tbody>
<?php foreach($runs as $run):?><tr><td><?=h(stamp($run['started_at']))?></td><td><a href="?p=user&amp;id=<?=(int)$run['user_id']?>"><?=h(clubNumber((int)$run['user_id']))?></a></td><td><?=h($statusLabels[$run['outcome']]??$run['outcome'])?></td><td><?=safeNumber($run['tasks_submitted'])?></td><td><?=safeNumber($run['vendor_attempts'])?></td><td><?=h((string)($run['error_summary']??'')?:'—')?></td></tr><?php endforeach?>
<?php if(!$runs):?><tr><td colspan="6" class="empty">今日暂无执行记录</td></tr><?php endif?>
</tbody></table></div></section>
