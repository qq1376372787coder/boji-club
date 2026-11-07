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
<?php if($pagePanel==='ai-live-cap'):?><section class="card" data-ai-live>
    <div class="section-head"><div><h2>当前 AI 处理情况</h2><p class="muted">每 15 秒更新一次，今天按北京时间计算。</p></div><button type="button" data-live-refresh>立即刷新</button></div>
    <div class="ai-live-grid">
        <?php foreach(array_intersect_key($countLabels,array_flip(['running','queued','today_succeeded','today_failed'])) as $key=>$label): ?><div class="ai-live-cell"><small><?=h($label)?></small><strong data-ai-count="<?=h($key)?>"><?=safeNumber($live[$key]??0)?></strong></div><?php endforeach ?>
    </div>
<p class="muted" data-live-status role="status">每 15 秒更新</p><div class="ai-capacity-alert" data-live-alerts role="status"></div><details><summary>资源与统计详情</summary>    <p class="muted" data-live-limits>全体用户每天可完成的 AI 分析次数：<?=$dailyLimit===0?'不限制':safeNumber($dailyLimit)?> · 未结束容量：<?=$pendingLimit===0?'不限制':safeNumber($pendingLimit)?></p>
    <p data-live-account-limit>每人每天可完成的 AI 分析次数：<?=$accountDailyLimit===0?'不限制':safeNumber($accountDailyLimit)?> 次 / 人 · 每人最多可同时提交多少个任务：<?=$accountPendingLimit===0?'不限制':safeNumber($accountPendingLimit)?></p>
    <p data-live-workers>并发设置：<?=$workerLimit?> · 当前资源允许：<?=isset($runtime['effective_workers'])?safeNumber($runtime['effective_workers']):'待刷新'?> · 最久排队：<?=safeNumber($live['oldest_queue_seconds']??0)?> 秒</p>
    <p class="muted" data-live-resources>刷新后显示 AI 内存、服务器可用内存和资源保护状态。</p>


    <div class="ai-live-grid"><?php foreach(array_diff_key($countLabels,array_flip(['running','queued','today_succeeded','today_failed'])) as $key=>$label):?><div class="ai-live-cell"><small><?=h($label)?></small><strong data-ai-count="<?=h($key)?>"><?=safeNumber($live[$key]??0)?></strong></div><?php endforeach?></div>
    <p class="muted">成功任务计入每日额度，失败与重试不重复扣减。统计按北京时间计算。</p>
</details></section>
<?php endif ?><?php if($pagePanel==='ai-capacity'):?><section class="card">
    <h2>AI 次数与排队设置</h2>
    <p class="muted">保存后，新任务约 1 秒内使用新设置。前四项填 0 表示不限；同时处理数为 1—32。</p>
    <form method="post" data-confirm="确认保存 AI AI 次数与排队设置？新设置会立即生效。">
        <input type="hidden" name="action" value="ai_capacity"><?php csrfField()?>
        <div class="profile-grid">
            <label>每人每天可完成的 AI 分析次数<input type="number" name="account_daily_limit" min="0" max="2147483647" step="1" value="<?=$accountDailyLimit?>" required><small>聊天、计划和饮食分析共用；失败重试不重复计次。</small></label>
            <label>全体用户每天可完成的 AI 分析次数<input type="number" name="daily_limit" min="0" max="2147483647" step="1" value="<?=$dailyLimit?>" required><small>控制所有用户合计的每日用量。</small></label>
            <label>全体用户最多可等待多少个任务<input type="number" name="pending_limit" min="0" max="2147483647" step="1" value="<?=$pendingLimit?>" required><small>包含等待中、处理中和重试中的任务。</small></label>
            <label>每人最多可同时提交多少个任务<input type="number" name="account_pending_limit" min="0" max="2147483647" step="1" value="<?=$accountPendingLimit?>" required><small>避免一位用户占满队列，默认 8。</small></label>
            <label>服务器同时处理多少个 AI 任务<input type="number" name="worker_limit" min="1" max="32" step="1" value="<?=$workerLimit?>" required><small>数值越大越占内存；降低后不会取消已有任务。</small></label>
        </div>
        <label>操作原因<textarea name="reason" required minlength="2" maxlength="200" placeholder="例如：内测容量调整"></textarea></label>
        <button>保存AI 次数与排队设置</button>
    </form>
    <details><summary>资源保护与告警规则</summary>    <p class="muted">资源保护：按每任务预留 24MiB 估算，以不含可回收干净文件缓存的内存计量，在服务上限的 85% 内调度；服务器可用内存低于 128MiB 暂缓。当前机器的稳妥并发须以压力测试为准，32 是代码保护上限，不是已验收吞吐承诺。</p>
    <p class="muted">告警在此页每 15 秒更新：排队最久超过 2 分钟、近 15 分钟至少 5 次供应商尝试且失败占比达到 20%、触发资源保护。暂未接入短信或邮箱告警。</p>
    <p class="muted">每日额度按北京时间零点恢复；降低额度不会取消已有任务。成功统计与排队容量、实际并发是独立设置；供应商可能仍有自己的流量限制或费用。</p>
</details></section>
<?php endif ?>