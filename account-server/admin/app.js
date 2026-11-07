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
const aiLivePanel = typeof document.querySelector === 'function' ? document.querySelector('[data-ai-live]') : null;
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

// Progressive sections: a single default panel; without JS every form stays visible.
function initializeAdminTabs() {
  if (typeof document.querySelectorAll !== 'function') return;
  document.querySelectorAll('[data-tab-group]').forEach(group => {
    const buttons = Array.from(group.querySelectorAll('[data-tab-target]'));
    const scope = group.dataset.tabGroup;
    const panes = Array.from(document.querySelectorAll('[data-tab-pane]')).filter(p => p.dataset.tabScope === scope);
    if (!buttons.length || !panes.length) return;
    const params = new URLSearchParams(window.location.search);
    const key = 'boji.admin.tab.' + scope + '.' + (params.get('id') || 'page');
    const find = name => buttons.find(b => b.dataset.tabTarget === name);
    const select = (button, remember = true) => {
      if (!button) return;
      const target = button.dataset.tabTarget;
      buttons.forEach(b => {
        const selected = b === button;
        b.classList.toggle('is-active', selected);
        b.setAttribute('aria-selected', selected ? 'true' : 'false');
        b.tabIndex = selected ? 0 : -1;
      });
      panes.forEach(p => { p.hidden = p.dataset.tabPane !== target; });
      if (remember) {
        try { sessionStorage.setItem(key, target); } catch (_) {}
        try { const url = new URL(window.location.href); url.searchParams.set('tab', target); window.history.replaceState(null, '', url); } catch (_) {}
      }
    };
    group._selectAdminPanel = name => select(find(name));
    buttons.forEach((button, index) => {
      const pane = panes.find(p => p.dataset.tabPane === button.dataset.tabTarget);
      button.id = 'tab-' + scope + '-' + index;
      if (pane) { pane.id = 'pane-' + scope + '-' + index; pane.setAttribute('role', 'tabpanel'); pane.setAttribute('aria-labelledby', button.id); button.setAttribute('aria-controls', pane.id); }
      button.addEventListener('click', () => select(button));
      button.addEventListener('keydown', event => {
        const current = buttons.indexOf(button);
        const next = event.key === 'ArrowRight' ? (current + 1) % buttons.length : event.key === 'ArrowLeft' ? (current - 1 + buttons.length) % buttons.length : event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : -1;
        if (next >= 0) { event.preventDefault(); select(buttons[next]); buttons[next].focus(); }
      });
    });
    let saved;
    try { saved = sessionStorage.getItem(key); } catch (_) {}
    const route = scope === 'user-detail' && params.has('date') ? 'daily-records'
      : scope === 'club-season' && params.get('new') === '1' ? 'season-create'
      : scope === 'ai-center' && (params.has('audit') || params.has('kind') || params.has('status') || params.has('page')) ? 'ai-task-log' : null;
    let hashNode;
    try { hashNode = window.location.hash && document.getElementById(decodeURIComponent(window.location.hash.slice(1))); } catch (_) {}
    const hashPane = hashNode && hashNode.closest('[data-tab-pane]');
    select(find(params.get('tab')) || find(route) || find(hashPane && hashPane.dataset.tabPane) || find(saved) || buttons[0], false);
  });
}
initializeAdminTabs();
document.addEventListener('invalid', event => {
  const pane = event.target && typeof event.target.closest === 'function' ? event.target.closest('[data-tab-pane]') : null;
  if (!pane || typeof document.querySelectorAll !== 'function') return;
  document.querySelectorAll('[data-tab-group]').forEach(group => {
    if (group.dataset.tabGroup === pane.dataset.tabScope && group._selectAdminPanel) group._selectAdminPanel(pane.dataset.tabPane);
  });
}, true);

// Task-based workspace. Native dialogs provide focus trapping and Escape support.
(() => {
  if (!document.body || !document.body.classList.contains('admin-workspace')) return;
  const editorLabels = {
    membership_adjust:'调整会员', member_tags:'编辑标签', member_note:'新增备注', status:'修改账号状态', delete_user:'删除账号', deletion_retry:'重试注销',
    club_season_create:'新建活动', club_season_update:'编辑活动资料', club_task_create:'添加任务', club_task_update:'编辑任务', club_reward_update:'编辑奖励', club_announcement_create:'发布动态',
    reward_catalog_create:'添加奖励', reward_catalog_update:'编辑奖励', notification_template_create:'新建模板', notification_template_update:'编辑模板',
    ai_router_update:'调整模型分配', ai_provider:'配置模型接口', push_block:'暂停账号推送', push_unblock:'恢复账号推送', admin_create:'新增管理员', admin_update:'修改权限', admin_password:'重置密码'
  };
  const skipEditors = new Set(['login','logout','password','config_save_draft','config_publish','config_rollback','feedback_reply','feedback_status','ai_capacity','push_budget_update','storage_capacity']);
  let serial=0;
  const setHidden=(form,name,value)=>{
    let input=form.querySelector(`input[name="${name}"]`);
    if(!input){input=document.createElement('input');input.type='hidden';input.name=name;form.appendChild(input);}
    input.value=value;
  };
  const formSnapshot=form=>JSON.stringify(Array.from(new FormData(form),([key,value])=>[key,value instanceof File?[value.name,value.size,value.name?value.lastModified:0]:value]));
  const snapshot=root=>Array.from(root.querySelectorAll('form')).map(formSnapshot).join('|');
  const openDialog=(dialog,trigger)=>{
    dialog._returnFocus=trigger;dialog._initialValues=snapshot(dialog);
    dialog.showModal();
  };
  const closeDialog=dialog=>{
    const now=snapshot(dialog);
    if(dialog._initialValues && now!==dialog._initialValues && !window.confirm('还有未保存的修改，关闭并放弃这些修改？'))return;
    dialog.close();if(dialog._returnFocus?.isConnected)dialog._returnFocus.focus();
  };
  function prepare(root=document){
    root.querySelectorAll('form[method="post"]').forEach(form=>{
      if(form.dataset.workspaceReady)return;form.dataset.workspaceReady='1';
      setHidden(form,'ui_section',document.body.dataset.section||'');
      if(form.closest('.is-readonly'))return;
      const action=form.querySelector('[name="action"]')?.value;
      if(!action||skipEditors.has(action)||form.hasAttribute('data-inline-editor')||form.closest('details,dialog'))return;
      const fields=form.querySelectorAll('input:not([type="hidden"]),textarea,select');
      if(fields.length<2&&!form.querySelector('textarea'))return;
      const details=document.createElement('details');details.className='editor-disclosure';
      const identity=['id','user_id','season_id','operation'].map(k=>form.querySelector(`[name="${k}"]`)?.value||'').join('-');
      details.dataset.editor=action+'-'+identity+'-'+serial++;
      const summary=document.createElement('summary');summary.textContent=editorLabels[action]||form.querySelector('button')?.textContent.trim()||'编辑';
      form.before(details);details.appendChild(summary);details.appendChild(form);
    });
    root.querySelectorAll('details').forEach(details=>{
      if(details.dataset.dialogReady||!details.querySelector('form')||details.closest('dialog'))return;
      if(details.closest('.is-readonly')){details.hidden=true;return;}
      details.dataset.dialogReady='1';
      const summary=details.querySelector(':scope > summary');if(!summary)return;
      const dialog=document.createElement('dialog');dialog.className='editor-dialog';
      dialog.dataset.editorId=details.dataset.editor||'editor-'+serial++;
      const trigger=document.createElement('button');trigger.type='button';trigger.className='secondary editor-trigger';trigger.textContent=summary.textContent.trim();
      trigger.setAttribute('aria-haspopup','dialog');
      const contents=document.createElement('div');contents.className='editor-content';
      Array.from(details.childNodes).filter(n=>n!==summary).forEach(n=>contents.appendChild(n));
      if(!contents.querySelector('.editor-header')){
        const header=document.createElement('header');header.className='editor-header';const heading=document.createElement('h2');
        heading.textContent=summary.textContent.trim();const close=document.createElement('button');close.type='button';close.className='icon-close';close.dataset.closeEditor='';close.textContent='×';close.setAttribute('aria-label','关闭');header.append(heading,close);contents.prepend(header);
      }
      dialog.appendChild(contents);details.before(trigger);details.after(dialog);details.hidden=true;
      dialog.querySelectorAll('form').forEach(form=>setHidden(form,'ui_dialog',dialog.dataset.editorId));
      trigger.addEventListener('click',()=>openDialog(dialog,trigger));
      dialog.addEventListener('cancel',event=>{event.preventDefault();closeDialog(dialog);});
      syncCatalogInventory(dialog.querySelector('form')||document.createElement('form'));
      dialog.querySelectorAll('select[name^="reward_type["]').forEach(syncSeasonInventory);
    });
  }
  prepare();
  const conversation=document.querySelector('.ticket-conversation');
  if(conversation&&!new URLSearchParams(window.location.search).has('before'))conversation.scrollTop=conversation.scrollHeight;
  if(document.querySelector('.ticket-header')&&window.matchMedia('(max-width:760px)').matches)document.querySelector('.ticket-detail').scrollIntoView({block:'start'});
  function restoreFields(root,values){
    root.querySelectorAll('input,textarea,select').forEach(field=>{
      if(['hidden','password','file','submit'].includes(field.type)||!field.name||/password|api_key|csrf|token/i.test(field.name))return;
      const value=values[field.name];
      if(field.type==='checkbox'||field.type==='radio'){
        const prefix=field.name.endsWith('[]')?field.name.slice(0,-2)+'[':null;
        field.checked=prefix?Object.entries(values).some(([k,v])=>k.startsWith(prefix)&&v===field.value):value===field.value;
      }else if(value!==undefined)field.value=value;
    });
  }
  const retry=JSON.parse(document.body.dataset.retryValues||'{}');
  const reopen=document.body.dataset.reopenEditor;
  if(!reopen&&retry.action)document.querySelectorAll('form').forEach(form=>{
    if(form.querySelector('[name="action"]')?.value===retry.action&&(!retry.config_section||form.querySelector('[name="config_section"]')?.value===retry.config_section))restoreFields(form,retry);
  });
  if(reopen){const dialog=Array.from(document.querySelectorAll('dialog[data-editor-id]')).find(d=>d.dataset.editorId===reopen);if(dialog){restoreFields(dialog,retry);openDialog(dialog,null);const notice=document.querySelector('[data-result-notice]');if(notice)dialog.querySelector('.editor-header').after(notice.cloneNode(true));}}
  const panel=document.querySelector('[data-member-panel]'),content=document.querySelector('[data-drawer-content]');
  let controller=null,requestVersion=0,drawerChanged=false;
  async function loadDrawer(value,options={}){
    const url=new URL(value,window.location.href);if(url.origin!==window.location.origin||url.pathname!=='/admin/')return;
    controller?.abort();controller=new AbortController();const generation=++requestVersion;
    panel.setAttribute('aria-busy','true');
    if(!options.method)content.innerHTML='<p class="drawer-loading" role="status">正在加载成员资料…</p>';
    try{
      const response=await fetch(url,{...options,credentials:'same-origin',cache:'no-store',signal:controller.signal});
      const text=await response.text();if(generation!==requestVersion)return;
      if(!response.ok)throw new Error(response.status===403?'没有这项操作权限。':'暂时无法加载，请重试。');
      const doc=new DOMParser().parseFromString(text,'text/html');const body=doc.querySelector('[data-workspace-content]');
      if(!body)throw new Error('登录已过期，请刷新页面重新登录。');
      content.replaceChildren(...Array.from(body.childNodes));
      panel.dataset.url=response.url||url.href;document.querySelector('[data-drawer-full]').href=panel.dataset.url;
      const section=doc.body.dataset.section||'';
      const retryValues=JSON.parse(doc.body.dataset.retryValues||'{}');
      if(options.method&&Object.keys(retryValues).length){const action=options.body.get('action');content.querySelectorAll('form').forEach(form=>{if(form.querySelector('[name="action"]')?.value===action)restoreFields(form,retryValues);});}
      content.querySelectorAll('form[method="post"]').forEach(f=>{f.setAttribute('action',panel.dataset.url);setHidden(f,'ui_section',section);});
      // Native member editors stay in this drawer, rather than creating nested modals.
      content.querySelectorAll('details[data-editor]').forEach(d=>d.classList.add('drawer-inline-editor'));
      content._initialValues=snapshot(content);panel.scrollTop=0;
      if(options.method){drawerChanged=true;const notice=content.querySelector('[data-result-notice]');notice?.scrollIntoView({block:'nearest'});}
    }catch(error){if(error.name==='AbortError')return;const notice=document.createElement('p');notice.className='notice is-error';notice.setAttribute('role','alert');notice.textContent=error.message;if(options.method)content.prepend(notice);else content.replaceChildren(notice);}
    finally{if(generation===requestVersion)panel.removeAttribute('aria-busy');}
  }
  const mayLeaveDrawer=()=>!content?._initialValues||snapshot(content)===content._initialValues||window.confirm('还有未保存的修改，放弃并离开？');
  panel?.addEventListener('cancel',event=>{if(!mayLeaveDrawer())event.preventDefault();});
  panel?.addEventListener('close',()=>{controller?.abort();requestVersion++;if(drawerChanged)window.location.reload();});
  document.addEventListener('click',event=>{
    if(!(event.target instanceof Element))return;
    const close=event.target.closest('[data-close-editor]');if(close){const dialog=close.closest('dialog');if(dialog===panel){if(mayLeaveDrawer())panel.close();}else if(dialog)closeDialog(dialog);return;}
    const member=event.target.closest('a[data-member-drawer]');
    if(member&&!event.metaKey&&!event.ctrlKey){event.preventDefault();drawerChanged=false;panel.showModal();loadDrawer(member.href);return;}
    const tab=event.target.closest('[data-member-panel] a[data-workspace-tab]');if(tab){event.preventDefault();if(mayLeaveDrawer())loadDrawer(tab.href);}
    const menu=event.target.closest('[data-mobile-nav]');if(menu){const expanded=menu.getAttribute('aria-expanded')!=='true';menu.setAttribute('aria-expanded',String(expanded));document.body.classList.toggle('navigation-open',expanded);}
  });
  document.addEventListener('submit',event=>{
    const form=event.target;if(!form.closest('[data-member-panel]')||form.method.toLowerCase()!=='post'||event.defaultPrevented)return;
    event.preventDefault();if(form.dataset.submitting)return;
    form.dataset.submitting='1';const button=event.submitter;if(button)button.disabled=true;
    loadDrawer(form.getAttribute('action')||panel.dataset.url,{method:'POST',body:new FormData(form)}).finally(()=>{delete form.dataset.submitting;if(button?.isConnected)button.disabled=false;});
  });
  document.addEventListener('submit',event=>{
    const form=event.target;if(event.defaultPrevented||form.method.toLowerCase()!=='post'||form.closest('[data-member-panel]'))return;
    if(form.dataset.submitting){event.preventDefault();return;}
    form.dataset.submitting='1';
    setTimeout(()=>{if(form.isConnected)form.querySelectorAll('button[type="submit"],button:not([type])').forEach(button=>button.disabled=true);},0);
  });
  window.addEventListener('pageshow',()=>document.querySelectorAll('form[data-submitting]').forEach(form=>{delete form.dataset.submitting;form.querySelectorAll('button:disabled').forEach(button=>button.disabled=false);}));
  document.addEventListener('invalid',event=>{
    let details=event.target.closest('details');while(details){details.open=true;details=details.parentElement.closest('details');}
  },true);
})();
