<?php
declare(strict_types=1);
/**
 * AI Operations Center — durable runs, trace, outbox backlog and usage.
 * Read-only. Health content is never selected here; only identifiers, status,
 * counts and timings. Missing tables (pre-migration) degrade to a notice.
 */
$trace = strtolower(trim((string)($_GET['trace'] ?? '')));
if (!preg_match('/^[0-9a-f]{32}$/D', $trace)) $trace = '';
$opsError = null;
$runCounts = [];
$oldestRunning = null;
$outbox = ['pending' => 0, 'processing' => 0, 'dead_letter' => 0, 'oldest_pending_at' => null];
$usage = ['calls' => 0, 'avg_ms' => null, 'max_ms' => null, 'prompt' => 0, 'completion' => 0];
$recentRuns = [];
$traceRows = ['runs' => [], 'proposals' => [], 'commands' => [], 'actions' => [], 'messages' => [], 'outbox' => []];
try {
    foreach ($db->query("SELECT status,COUNT(*) AS n FROM ai_runs WHERE created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY) GROUP BY status")->fetchAll() as $row) {
        $runCounts[(string)$row['status']] = (int)$row['n'];
    }
    $oldestRunning = $db->query("SELECT MIN(created_at) FROM ai_runs WHERE status='running'")->fetchColumn() ?: null;
    $outboxRow = $db->query("SELECT
        SUM(status='pending') AS pending, SUM(status='processing') AS processing,
        SUM(status='dead_letter') AS dead_letter, MIN(CASE WHEN status='pending' THEN created_at END) AS oldest_pending_at
        FROM domain_outbox")->fetch() ?: [];
    $outbox = [
        'pending' => (int)($outboxRow['pending'] ?? 0),
        'processing' => (int)($outboxRow['processing'] ?? 0),
        'dead_letter' => (int)($outboxRow['dead_letter'] ?? 0),
        'oldest_pending_at' => $outboxRow['oldest_pending_at'] ?? null,
    ];
    $usageRow = $db->query("SELECT COUNT(*) AS calls,AVG(latency_ms) AS avg_ms,MAX(latency_ms) AS max_ms,
        SUM(COALESCE(prompt_tokens,0)) AS prompt,SUM(COALESCE(completion_tokens,0)) AS completion
        FROM ai_usage_ledger WHERE created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 7 DAY)")->fetch() ?: [];
    $usage = [
        'calls' => (int)($usageRow['calls'] ?? 0),
        'avg_ms' => $usageRow['avg_ms'] === null ? null : (int)round((float)$usageRow['avg_ms']),
        'max_ms' => $usageRow['max_ms'] === null ? null : (int)$usageRow['max_ms'],
        'prompt' => (int)($usageRow['prompt'] ?? 0),
        'completion' => (int)($usageRow['completion'] ?? 0),
    ];
    $recentRuns = $db->query("SELECT id,trace_id,status,attempts,error_code,created_at,updated_at
        FROM ai_runs ORDER BY created_at DESC LIMIT 15")->fetchAll();
    if ($trace !== '') {
        $runQuery = $db->prepare('SELECT id,user_id,trace_id,status,attempts,error_code,created_at,updated_at FROM ai_runs WHERE trace_id=? ORDER BY created_at DESC LIMIT 10');
        $runQuery->execute([$trace]); $traceRows['runs'] = $runQuery->fetchAll();
        $proposalQuery = $db->prepare('SELECT proposal_id,user_id,kind,status,created_at,updated_at FROM ai_action_proposals WHERE trace_id=? ORDER BY created_at DESC LIMIT 10');
        $proposalQuery->execute([$trace]); $traceRows['proposals'] = $proposalQuery->fetchAll();
        $commandQuery = $db->prepare('SELECT operation_id,user_id,command_type,status,created_at FROM data_operations WHERE trace_id=? ORDER BY created_at DESC LIMIT 10');
        $commandQuery->execute([$trace]); $traceRows['commands'] = $commandQuery->fetchAll();
        $actionQuery = $db->prepare('SELECT call_id,user_id,message_id,capability,status,created_at FROM ai_action_calls WHERE trace_id=? ORDER BY created_at DESC LIMIT 20');
        $actionQuery->execute([$trace]); $traceRows['actions'] = $actionQuery->fetchAll();
        $messageQuery = $db->prepare('SELECT message_id,user_id,status,created_at FROM ai_action_messages WHERE trace_id=? ORDER BY created_at DESC LIMIT 10');
        $messageQuery->execute([$trace]); $traceRows['messages'] = $messageQuery->fetchAll();
        $outboxQuery = $db->prepare('SELECT event_id,user_id,event_type,aggregate_type,status,created_at FROM domain_outbox WHERE trace_id=? ORDER BY created_at DESC LIMIT 20');
        $outboxQuery->execute([$trace]); $traceRows['outbox'] = $outboxQuery->fetchAll();
    }
} catch (Throwable $error) {
    $opsError = '运维指标暂不可用：请确认已执行 20261025-ai-runs.sql 迁移。';
}
?>
<section class="card">
  <div class="section-head">
    <div><h2>AI Run 与事件回溯</h2><p class="muted">Run 是持久实体；SSE 仅传输进度。此表不含对话内容与健康数值。</p></div>
    <span class="badge <?=$opsError ? 'disabled' : 'active'?>"><?=$opsError ? '待迁移' : '运行中'?></span>
  </div>
  <?php if ($opsError): ?><p class="empty"><?=h($opsError)?></p><?php else: ?>
  <div class="metrics">
    <?php foreach ([
        ['排队', $runCounts['queued'] ?? 0, '等待 worker 领取'],
        ['运行中', $runCounts['running'] ?? 0, '有租约或等待重试'],
        ['完成', $runCounts['completed'] ?? 0, '近 30 天'],
        ['失败', $runCounts['failed'] ?? 0, '近 30 天'],
    ] as [$label, $value, $hint]): ?>
      <article><span class="muted"><?=h($label)?></span><b><?=safeNumber($value)?></b><small><?=h($hint)?></small></article>
    <?php endforeach ?>
  </div>
  <div class="two-col">
    <section class="card">
      <h3>Outbox 积压</h3>
      <div class="stat-line"><span>待处理</span><strong><?=safeNumber($outbox['pending'])?></strong></div>
      <div class="stat-line"><span>处理中</span><strong><?=safeNumber($outbox['processing'])?></strong></div>
      <div class="stat-line"><span>死信</span><strong><?=safeNumber($outbox['dead_letter'])?></strong></div>
      <div class="stat-line"><span>最老待处理</span><strong><?=h($outbox['oldest_pending_at'] ? stamp($outbox['oldest_pending_at']) : '—')?></strong></div>
      <p class="muted">最老运行中 Run：<?=h($oldestRunning ? stamp($oldestRunning) : '—')?>。死信需人工核对后按幂等恢复，不能直接重放任意 SQL。</p>
    </section>
    <section class="card">
      <h3>近 7 天用量</h3>
      <div class="stat-line"><span>模型请求</span><strong><?=safeNumber($usage['calls'])?></strong></div>
      <div class="stat-line"><span>平均 / 最大耗时</span><strong><?=h(($usage['avg_ms'] ?? '—') . ' / ' . ($usage['max_ms'] ?? '—'))?> ms</strong></div>
      <div class="stat-line"><span>输入 / 输出令牌</span><strong><?=safeNumber($usage['prompt']) . ' / ' . safeNumber($usage['completion'])?></strong></div>
      <p class="muted">金额以供应商账单为准；不在此估算价格，避免因价格变动产生错误数据。</p>
    </section>
  </div>
  <form class="filters" method="get">
    <input type="hidden" name="p" value="ai">
    <input name="trace" placeholder="输入 32 位 trace_id 关联 Run / 提案 / 命令" value="<?=h($trace)?>" maxlength="32">
    <button>追踪</button>
  </form>
  <?php if ($trace !== ''): ?>
    <h3>trace <?=h($trace)?></h3>
    <div class="table-wrap"><table><thead><tr><th>类型</th><th>标识</th><th>成员</th><th>状态</th><th>时间</th></tr></thead><tbody>
      <?php foreach ($traceRows['runs'] as $row): ?><tr><td>Run</td><td><code><?=h($row['id'])?></code></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php foreach ($traceRows['proposals'] as $row): ?><tr><td>提案</td><td><code><?=h($row['proposal_id'])?></code><small><?=h($row['kind'])?></small></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php foreach ($traceRows['commands'] as $row): ?><tr><td>命令</td><td><code><?=h($row['operation_id'])?></code><small><?=h($row['command_type'])?></small></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php foreach ($traceRows['actions'] as $row): ?><tr><td>行动</td><td><code><?=h($row['call_id'])?></code><small><?=h($row['capability'])?></small></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php foreach ($traceRows['messages'] as $row): ?><tr><td>消息</td><td><code><?=h($row['message_id'])?></code></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php foreach ($traceRows['outbox'] as $row): ?><tr><td>Outbox</td><td><code><?=h($row['event_id'])?></code><small><?=h($row['event_type'])?></small></td><td><?=h(clubNumber((int)$row['user_id']))?></td><td><?=h($row['status'])?></td><td><?=h(stamp($row['created_at']))?></td></tr><?php endforeach ?>
      <?php if (!$traceRows['runs'] && !$traceRows['proposals'] && !$traceRows['commands'] && !$traceRows['actions'] && !$traceRows['messages'] && !$traceRows['outbox']): ?><tr><td colspan="5" class="empty">该 trace 没有记录</td></tr><?php endif ?>
    </tbody></table></div>
  <?php endif ?>
  <div class="table-wrap"><table><thead><tr><th>创建</th><th>状态</th><th>尝试</th><th>错误码</th><th>trace</th></tr></thead><tbody>
    <?php foreach ($recentRuns as $row): ?><tr><td><?=h(stamp($row['created_at']))?></td><td><?=h($row['status'])?></td><td><?=safeNumber($row['attempts'])?></td><td><?=h($row['error_code'] ?: '—')?></td><td><a href="?p=ai&amp;trace=<?=h($row['trace_id'])?>"><code><?=h(substr((string)$row['trace_id'],0,12))?>…</code></a></td></tr><?php endforeach ?>
    <?php if (!$recentRuns): ?><tr><td colspan="5" class="empty">暂无 Run（可能尚未开启流式对话）</td></tr><?php endif ?>
  </tbody></table></div>
  <?php endif ?>
</section>
