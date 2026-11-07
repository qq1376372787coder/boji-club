<?php
try{$router=aiAdmin('/v1/admin/ai/router');}catch(Throwable){$router=null;}
if($router): $labels=['chat'=>'普通聊天','reference'=>'引用记录','proposal'=>'纠错与提案','complex'=>'计划与周复盘','vision'=>'图片理解']; ?>
<section class="card"><h2>按任务分配模型</h2>
<p class="muted">优先选择的服务出错时，自动切换备用服务。</p><div class="table-wrap"><table><thead><tr><th>任务类型</th><th>DeepSeek</th><th>MiniMax</th></tr></thead><tbody><?php foreach($labels as $key=>$label):$share=(int)round(($router['controls']['weights'][$key]??$router['default_weights_deepseek'][$key])*100);?><tr><td><?=h($label)?></td><td><?=$share?>%</td><td><?=100-$share?>%</td></tr><?php endforeach?></tbody></table></div>
<details><summary>调整模型分配</summary><form method="post"><?php csrfField()?><input type="hidden" name="action" value="ai_router_update">
<label class="switch"><input type="checkbox" name="enabled" <?=($router['controls']['enabled']??true)?'checked':''?>> 按任务分配模型（关闭后按接口顺序尝试）</label>
<div class="three-col"><?php foreach($labels as $key=>$label): $v=$router['controls']['weights'][$key]??$router['default_weights_deepseek'][$key];?>
<label><?=h($label)?> · DeepSeek %<input type="number" name="weight_<?=h($key)?>" min="10" max="90" value="<?=h((string)round($v*100))?>" required></label>
<?php endforeach?></div>
<label>当前管理员密码<input type="password" name="current_password" autocomplete="current-password" required></label>
<label>操作原因<input name="reason" minlength="2" maxlength="200" required></label><button type="submit">保存模型分配</button></form></details>
<details class="advanced-settings"><summary>近 24 小时的速度与失败情况</summary><div class="table-wrap"><table><thead><tr><th>任务/服务</th><th>请求次数</th><th>失败</th><th>首字耗时（95%）</th><th>完成耗时（95%）</th></tr></thead><tbody>
<?php foreach($router['samples_24h'] as $key=>$stat):?><tr><td><?=h($key)?></td><td><?=h((string)$stat['n'])?></td><td><?=h((string)$stat['failures'])?></td><td><?=isset($stat['ttft_p95_ms'])?h(number_format($stat['ttft_p95_ms']/1000,2)).' 秒':'—'?></td><td><?=h(number_format(($stat['latency_p95_ms']??0)/1000,2))?> 秒</td></tr><?php endforeach?>
</tbody></table></div><p class="muted">“95% 耗时”表示大多数请求在这个时间内完成；金额以服务商账单为准。</p></details></section>
<?php else:?><p class="notice is-error" role="alert">模型分配暂时无法读取，请稍后重试。</p><?php endif?>
