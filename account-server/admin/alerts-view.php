<?php
require_once __DIR__.'/alerts.php';
$alerts = operationsAlertsStatus();
$events = array_values(array_filter($alerts['events'] ?? [], 'is_array'));
$active = array_values(array_filter($events, fn($e)=>($e['status'] ?? '') === 'active'));
$recovered = array_values(array_filter($events, fn($e)=>($e['status'] ?? '') === 'recovered'));
$fresh = false;
try { $age = time()-(new DateTimeImmutable((string)($alerts['checked_at'] ?? 'invalid')))->getTimestamp(); $fresh = $age >= -300 && $age < 900; } catch (Throwable) {}
$mode = (string)($alerts['mode'] ?? 'dashboard_only');
?>
<section class="card"><div class="section-head"><div><h2>服务异常提醒</h2><p class="muted">自动检查失败率、备份、磁盘与定时任务；同一故障合并记录，恢复后保留处理轨迹。</p></div><span class="badge <?=!$fresh || $active ? 'pending' : 'active'?>"><?=!$fresh ? '采集状态待核对' : ($active ? count($active).' 项待处理' : '本次检查未发现异常')?></span></div>
<?php if (!$alerts): ?><p class="notice" role="status">尚未收到告警采集结果。需要先启用服务器告警定时任务；这里暂时不能确认服务是否正常。</p>
<?php elseif (!$fresh): ?><p class="notice is-error" role="alert">告警采集已超过 15 分钟未更新或时间异常。以下为最后收到的记录，请检查告警采集任务。</p><?php endif ?>
<?php if ($mode === 'external_enabled'): ?><p class="notice">已启用<?=in_array('smtp', $alerts['channels'] ?? [], true) ? '邮件' : ''?><?=in_array('smtp', $alerts['channels'] ?? [], true) && in_array('webhook', $alerts['channels'] ?? [], true) ? '和' : ''?><?=in_array('webhook', $alerts['channels'] ?? [], true) ? '企业机器人' : ''?>通知。“渠道已接收”表示邮件服务器或机器人接口接受请求，实际收到仍需核对。</p>
<?php else: ?><p class="notice">当前仅在后台显示，尚未开启邮件或企业机器人通知。外部通知需先由服务器管理员配置接收渠道。</p><?php endif ?>
<?php if (($alerts['unknown_count'] ?? 0) > 0): ?><p class="notice">有 <?=(int)$alerts['unknown_count']?> 项检查暂时无法统计。数据缺失不会被当作故障恢复。</p><?php endif ?>
<p class="muted">最近采集：<?=h(operationsAlertTime($alerts['checked_at'] ?? null))?>（北京时间）</p>
</section>
<section class="card"><h2>待处理异常</h2>
<?php if (!$active): ?><p class="empty"><?=$fresh ? '本次检查没有待处理异常。' : '暂时无法确认，请先检查采集状态。'?></p><?php else: ?>
<div class="table-wrap"><table><thead><tr><th>异常</th><th>情况说明</th><th>首次发现</th><th>最近确认</th><th>通知状态</th></tr></thead><tbody>
<?php foreach ($active as $event): ?><tr><td><strong><?=h($event['title'] ?? '服务异常')?></strong><br><span class="badge pending"><?=($event['severity'] ?? '') === 'critical' ? '优先处理' : '需要留意'?></span></td><td><?=h($event['detail'] ?? '')?></td><td><?=h(operationsAlertTime($event['opened_at'] ?? null))?></td><td><?=h(operationsAlertTime($event['last_seen_at'] ?? null))?></td><td><?=h(operationsAlertDelivery($event, $mode))?></td></tr><?php endforeach ?>
</tbody></table></div><?php endif ?></section>
<section class="card"><details><summary>已恢复记录</summary><p class="muted">恢复以新一次成功检查为准。同一故障持续时最多每 6 小时再次通知，失败通知默认每 15 分钟重试；阈值可由服务器配置调整。</p>
<?php if (!$recovered): ?><p class="empty">暂无恢复记录。</p><?php else: ?><div class="table-wrap"><table><thead><tr><th>异常</th><th>发现时间</th><th>恢复时间</th><th>恢复通知</th></tr></thead><tbody>
<?php foreach (array_slice($recovered, 0, 50) as $event): ?><tr><td><?=h($event['title'] ?? '服务异常')?></td><td><?=h(operationsAlertTime($event['opened_at'] ?? null))?></td><td><?=h(operationsAlertTime($event['recovered_at'] ?? null))?></td><td><?=h(operationsAlertDelivery($event, $mode))?></td></tr><?php endforeach ?>
</tbody></table></div><?php endif ?></details></section>
