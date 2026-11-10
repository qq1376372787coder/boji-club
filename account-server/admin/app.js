document.addEventListener('submit', event => {
  const form = event.target;
  if (!(form instanceof HTMLFormElement)) return;
  const message = event.submitter?.dataset.confirm || form.dataset.confirm;
  if (message && !window.confirm(message)) event.preventDefault();
});

function syncCatalogInventory(form) {
  const kind = form.querySelector('select[name="kind"]');
  const inventory = form.querySelector('input[name="default_inventory"]');
  if (!kind || !inventory) return;
  const physical = kind.value === 'physical';
  inventory.disabled = !physical; inventory.required = physical;
  if (physical && !inventory.value) inventory.value = '1';
}
document.querySelectorAll('form').forEach(syncCatalogInventory);
document.addEventListener('change', event => {
  if (event.target.matches('select[name="kind"]') && event.target.form) syncCatalogInventory(event.target.form);
});

function syncSeasonInventory(kind) {
  const match = kind.name.match(/^reward_type\[(\d+)\]$/);
  if (!match || !kind.form) return;
  const physical = kind.value === 'physical';
  const inventory = kind.form.querySelector(`input[name="reward_inventory[${match[1]}]"]`);
  if (inventory) {
    inventory.disabled = kind.disabled || !physical;
    inventory.required = !kind.disabled && physical;
    if (physical && !inventory.value) inventory.value = '1';
  }
  kind.form.querySelectorAll(`[data-reward-physical="${match[1]}"]`).forEach(label => {
    label.hidden = !physical;
  });
}

document.querySelectorAll('select[name^="reward_type["]').forEach(syncSeasonInventory);
document.addEventListener('change', event => {
  if (event.target.matches('select[name^="reward_type["]')) syncSeasonInventory(event.target);
});

document.addEventListener('click', event => {
  const addButton = event.target.closest('[data-add-task]');
  if (addButton) {
    const form = addButton.closest('form');
    const builder = form && form.querySelector('[data-task-builder]');
    const source = builder && builder.querySelector('[data-task-row]');
    if (!builder || !source) return;
    const row = source.cloneNode(true);
    row.querySelectorAll('input, textarea, select').forEach(control => {
      if (control.tagName === 'SELECT') control.selectedIndex = 0;
      else control.value = '';
      control.disabled = false;
    });
    const target = row.querySelector('input[name="task_target[]"]');
    if (target) target.value = '3';
    builder.appendChild(row);
    return;
  }

  const removeButton = event.target.closest('[data-remove-task]');
  if (removeButton) {
    const row = removeButton.closest('[data-task-row]');
    const builder = row && row.closest('[data-task-builder]');
    if (row && builder && builder.querySelectorAll('[data-task-row]').length > 1) row.remove();
  }
});

// Lightweight authenticated snapshots; never reload forms or overlap requests.
const aiLivePanel = document.querySelector('[data-ai-live]');
if (aiLivePanel) {
  const status = aiLivePanel.querySelector('[data-live-status]');
  let liveTimer;
  let busy = false;
  async function refreshAILive() {
    if (busy || document.hidden) return;
    busy = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch('?p=ai_live', {credentials: 'same-origin', cache: 'no-store', signal: controller.signal});
      if (response.status === 401) {
        clearInterval(liveTimer);
        status.textContent = '登录已过期，请刷新并重新登录。';
        return;
      }
      if (!response.ok) throw new Error('stats unavailable');
      const value = await response.json();
      const nodes = aiLivePanel.querySelectorAll('[data-ai-count]');
      if (Array.from(nodes).some(node => !Number.isSafeInteger(value[node.dataset.aiCount]) || value[node.dataset.aiCount] < 0)) throw new Error('invalid statistics');
      nodes.forEach(node => { node.textContent = value[node.dataset.aiCount].toLocaleString('zh-CN'); });
      const limits = value.capacity_settings;
      if (limits && Number.isSafeInteger(limits.daily_limit) && Number.isSafeInteger(limits.pending_limit)) {
        aiLivePanel.querySelector('[data-live-limits]').textContent = `全服务每日成功上限：${limits.daily_limit === 0 ? '不限制' : limits.daily_limit} · 未结束容量：${limits.pending_limit === 0 ? '不限制' : limits.pending_limit}`;
      }
      if (limits && Number.isSafeInteger(limits.account_daily_limit)) {
        aiLivePanel.querySelector('[data-live-account-limit]').textContent = `每账号每日成功上限：${limits.account_daily_limit === 0 ? '不限制' : limits.account_daily_limit} 次 / 人`;
      }
      status.textContent = '已更新 ' + new Intl.DateTimeFormat('zh-CN', {timeZone:'Asia/Shanghai', hour:'2-digit', minute:'2-digit', second:'2-digit'}).format(new Date(value.sampled_at * 1000));
      const runtime = value.runtime;
      if (runtime && Number.isSafeInteger(runtime.configured_workers) && Number.isSafeInteger(runtime.effective_workers)) {
        aiLivePanel.querySelector('[data-live-workers]').textContent = `并发设置：${runtime.configured_workers} · 当前资源允许：${runtime.effective_workers} · 最久排队：${value.oldest_queue_seconds} 秒`;
        const resources = runtime.resources || {};
        const mib = x => Number.isFinite(x) && x >= 0 ? (x / 1048576).toFixed(1) + 'MiB' : '未读取';
        aiLivePanel.querySelector('[data-live-resources]').textContent = `AI 内存含缓存：${mib(resources.memory_current)} / ${mib(resources.memory_limit)} · 调度计量：${mib(resources.memory_guard_bytes)} · 可回收缓存：${mib(resources.reclaimable_file_cache)} · 服务器可用 / 总内存：${mib(resources.host_available)} / ${mib(resources.host_total)} · CPU：${resources.cpu_count ?? '未读取'} 核 · PHP 最大进程：${resources.php_max_children ?? '未读取'} · 资源保护：${runtime.pause_reason ? '暂缓取新任务' : '正常'}`;
      }
      aiLivePanel.querySelector('[data-live-alerts]').textContent = Array.isArray(value.alerts) ? value.alerts.filter(x => typeof x === 'string').join('；') : '';
    } catch (_) { status.textContent = '更新失败，保留上次数据；稍后自动重试。'; }
    finally { clearTimeout(timeout); busy = false; }
  }
  aiLivePanel.querySelector('[data-live-refresh]').addEventListener('click', refreshAILive);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshAILive(); });
  liveTimer = setInterval(refreshAILive, 15000);
}
