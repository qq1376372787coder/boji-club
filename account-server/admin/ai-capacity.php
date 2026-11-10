<?php
$live=is_array($ai['live']??null)?$ai['live']:[];
$limits=is_array($ai['capacity_settings']??null)?$ai['capacity_settings']:[];
$dailyLimit=(int)($limits['daily_limit']??0);
$pendingLimit=(int)($limits['pending_limit']??800);
$workerLimit=(int)($limits['worker_limit']??3);
$accountDailyLimit=(int)($limits['account_daily_limit']??0);
$accountPendingLimit=(int)($limits['account_pending_limit']??8);
$runtime=is_array($live['runtime']??null)?$live['runtime']:[];
$countLabels=['running'=>'正在处理','queued'=>'排队中','retrying'=>'等待重试','pending'=>'未结束总量','today_received'=>'今日新任务','today_processed'=>'今日已处理','today_succeeded'=>'今日成功','today_failed'=>'今日最终失败','today_failure_events'=>'今日处理失败尝试','today_failed_attempts'=>'今日接口失败尝试','today_quota_successes'=>'今日首次成功'];
?>
<section class="card" data-ai-live>
    <div class="section-head"><div><h2>AI 实时任务</h2><p class="muted">每 15 秒更新一次，今天按北京时间计算。</p></div><button type="button" data-live-refresh>立即刷新</button></div>
    <div class="ai-live-grid">
        <?php foreach($countLabels as $key=>$label): ?><div class="ai-live-cell"><small><?=h($label)?></small><strong data-ai-count="<?=h($key)?>"><?=safeNumber($live[$key]??0)?></strong></div><?php endforeach ?>
    </div>
    <p class="muted" data-live-limits>全服务每日成功上限：<?=$dailyLimit===0?'不限制':safeNumber($dailyLimit)?> · 未结束容量：<?=$pendingLimit===0?'不限制':safeNumber($pendingLimit)?></p>
    <p data-live-account-limit>每账号每日成功上限：<?=$accountDailyLimit===0?'不限制':safeNumber($accountDailyLimit)?> 次 / 人 · 单账号未结束任务上限：<?=$accountPendingLimit===0?'不限制':safeNumber($accountPendingLimit)?></p>
    <p data-live-workers>并发设置：<?=$workerLimit?> · 当前资源允许：<?=isset($runtime['effective_workers'])?safeNumber($runtime['effective_workers']):'待刷新'?> · 最久排队：<?=safeNumber($live['oldest_queue_seconds']??0)?> 秒</p>
    <p class="muted" data-live-resources>刷新后显示 AI 内存、服务器可用内存和资源保护状态。</p>
    <div class="ai-capacity-alert" data-live-alerts role="status"><?php foreach(($live['alerts']??[]) as $alert):?><p><?=h($alert)?></p><?php endforeach?></div>
    <p class="muted" data-live-status role="status">页面加载时的数据，可立即刷新核对。</p>
    <p class="muted">今日已处理按当天得到最终成功或失败结果的任务计数，同一任务当天重试不会重复累计；恢复成功后更新成功/失败分类。排队和等待自动重试不算已处理。今日处理失败尝试包含中断、过期与自动重试失败，恢复成功后仍保留；今日接口失败尝试还包含切换供应商之前的失败。它们不扣用户额度。首次成功计次和处理失败事件保留 30 天，接口尝试沿原规则保留 90 天；注销清除账号关联及任务私有数据。</p>
</section>
<section class="card">
    <h2>容量设置</h2>
    <p class="muted">保存后约 1 秒内应用，重启仍保留。每账号、全服务每日上限和总容量填 0 表示不限制；并发须为 1—32，不能填 0。降低并发时已有任务继续完成，后续取任务使用新值。</p>
    <form method="post" data-confirm="确认保存 AI 容量设置？新设置会立即生效。">
        <input type="hidden" name="action" value="ai_capacity"><?php csrfField()?>
        <div class="profile-grid">
            <label>每账号每日成功上限<input type="number" name="account_daily_limit" min="0" max="2147483647" step="1" value="<?=$accountDailyLimit?>" required><small>所有分析类型共用；填 0 不限。首次成功计一次，失败和重复重试不计。</small></label>
            <label>全服务每日成功上限<input type="number" name="daily_limit" min="0" max="2147483647" step="1" value="<?=$dailyLimit?>" required><small>全服务成功任务共用；填 0 不限。失败不扣额度。有限额时，处理中暂预留名额，最终失败后释放。</small></label>
            <label>未结束任务总容量<input type="number" name="pending_limit" min="0" max="2147483647" step="1" value="<?=$pendingLimit?>" required><small>排队＋处理中＋自动重试，不是实际并发数。填 0 不限制。</small></label>
            <label>单账号未结束任务上限<input type="number" name="account_pending_limit" min="0" max="2147483647" step="1" value="<?=$accountPendingLimit?>" required><small>防止一个账号占满全服务队列；填 0 不限制。默认 8。</small></label>
            <label>同时处理的 AI 任务数<input type="number" name="worker_limit" min="1" max="32" step="1" value="<?=$workerLimit?>" required><small>设置 1—32；内存不足会暂缓取新任务，不取消已有任务。</small></label>
        </div>
        <label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：内测容量调整"></textarea></label>
        <button>保存容量设置</button>
    </form>
    <p class="muted">资源保护：按每任务预留 24MiB 估算，以不含可回收干净文件缓存的内存计量，在服务上限的 85% 内调度；服务器可用内存低于 128MiB 暂缓。当前机器的稳妥并发须以压力测试为准，32 是代码保护上限，不是已验收吞吐承诺。</p>
    <p class="muted">告警在此页每 15 秒更新：排队最久超过 2 分钟、近 15 分钟至少 5 次供应商尝试且失败占比达到 20%、触发资源保护。暂未接入短信或邮箱告警。</p>
    <p class="muted">每日额度按北京时间零点恢复；降低额度不会取消已有任务。成功统计与排队容量、实际并发是独立设置；供应商可能仍有自己的流量限制或费用。</p>
</section>
