<?php
try{$router=aiAdmin('/v1/admin/ai/router');}catch(Throwable){$router=null;}
if($router): $labels=['chat'=>'普通聊天','reference'=>'引用记录','proposal'=>'纠错与提案','complex'=>'计划与周复盘','vision'=>'图片理解']; ?>
<section class="card"><h2>按任务分配模型</h2>
<p class="muted">比例为首选服务分配；授权、图片能力、熔断优先。足够样本后会根据延迟和失败率小幅调整。一次请求不同时双发。</p>
<form method="post"><?php csrfField()?><input type="hidden" name="action" value="ai_router_update">
<label class="switch"><input type="checkbox" name="enabled" <?=($router['controls']['enabled']??true)?'checked':''?>> 启用任务路由（关闭时按回退优先级）</label>
<div class="three-col"><?php foreach($labels as $key=>$label): $v=$router['controls']['weights'][$key]??$router['default_weights_deepseek'][$key];?>
<label><?=h($label)?> · DeepSeek %<input type="number" name="weight_<?=h($key)?>" min="10" max="90" value="<?=h((string)round($v*100))?>" required></label>
<?php endforeach?></div>
<label>当前管理员密码<input type="password" name="current_password" autocomplete="current-password" required></label>
<label>操作原因<input name="reason" minlength="2" maxlength="200" required></label><button type="submit">保存路由</button></form>
<div class="table-wrap"><table><thead><tr><th>任务/服务</th><th>样本</th><th>失败</th><th>首正文P95</th><th>完成P95</th></tr></thead><tbody>
<?php foreach($router['samples_24h'] as $key=>$stat):?><tr><td><?=h($key)?></td><td><?=h((string)$stat['n'])?></td><td><?=h((string)$stat['failures'])?></td><td><?=isset($stat['ttft_p95_ms'])?h((string)$stat['ttft_p95_ms']).'ms':'—'?></td><td><?=h((string)$stat['latency_p95_ms'])?>ms</td></tr><?php endforeach?>
</tbody></table></div><p class="muted">只有实际模型正文计入首字；心跳和推理不计入。未配置价格时不显示估算费用。</p></section>
<?php endif?>
