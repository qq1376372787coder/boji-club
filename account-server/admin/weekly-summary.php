<?php $weekly=listValue($day['weeklyReview']??[]);$weeklyResult=listValue($weekly['result']??[]);if($weeklyResult): ?>
<section class="card"><h2>每周身体复盘摘要</h2><p class="muted">截至 <?=h($weekly['date']??'')?> 的七天 · 身体照片不进入管理后台</p>
<?php foreach(['summary'=>'本周小结','training'=>'训练执行','nutrition'=>'饮食反馈','recovery'=>'恢复与感受','appearance'=>'外观观察及局限','reason'=>'下周建议依据'] as $key=>$label):if(!empty($weeklyResult[$key])):?>
<h3><?=h($label)?></h3><p class="prose"><?=h($weeklyResult[$key])?></p>
<?php endif;endforeach ?><p><?=!empty($weekly['applied'])?'成员已确认应用所选调整':'训练调整尚未应用或无需调整'?></p></section>
<?php endif ?>
