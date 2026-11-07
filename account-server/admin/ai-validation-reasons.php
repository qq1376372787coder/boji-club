<?php
// Included only in the authenticated AI dashboard. Counts refer to provider attempts.
$validationLabels=[
    'plan_dates'=>'训练日期越界或重复','plan_weekdays'=>'训练星期不符合选择','plan_frequency'=>'训练堂数不符合要求',
    'plan_catalog'=>'动作不在可用动作库','plan_equipment'=>'动作需要未填写的器械','plan_timed_sets'=>'计时动作缺少秒数',
    'plan_language'=>'训练提醒含未整理的英文或字段','report_detail'=>'分析不够详细',
    'report_unsupported_claim'=>'分析给出了没有证据的结论','report_meal_completion'=>'误读饮食已记完状态',
    'report_invented_survey'=>'日报引用了不存在的问卷','report_nutrition_reference'=>'缺少个人营养参考却判断达标',
    'report_food_provenance'=>'错误声称食物营养数据全部实测','report_volume'=>'周训练量计算不一致',
    'report_scope'=>'训练复盘越界评价饮食','report_general_guidance'=>'不适用的具体营养处方',
    'food_energy'=>'食物热量与营养数字明显不一致','food_mass'=>'营养质量超过食物份量','food_dates'=>'识别到了未来餐食',
    'food_metadata'=>'食物单位或估算来源不符合格式','translation_numbers'=>'翻译改变了训练数字','translation_units'=>'翻译改变了单位',
    'schema_missing_field'=>'结果缺少必要字段','schema_text'=>'文字为空或超过长度','schema_number'=>'数字格式错误',
    'schema_bounds'=>'数字超过允许范围','schema_list'=>'列表数量或格式不符','schema_invalid'=>'其他结果格式错误',
    'response_truncated'=>'供应商返回中断或被截断','response_shape'=>'供应商返回类型不正确',
    'response_json'=>'供应商没有返回完整 JSON','response_duplicate_keys'=>'结果重复定义同一字段',
];
if(!empty($ai['validation_reasons'])): ?>
<section class="card"><h2>内容校验未通过的具体原因</h2><p class="muted">自本次更新开始记录；每一项是一次模型尝试，不代表一位用户的任务最终失败。备用服务成功后，任务仍可正常完成。</p>
<?php foreach($ai['validation_reasons'] as $row): ?><div class="stat-line"><span><?=h($validationLabels[$row['code']]??$row['code'])?></span><strong><?=safeNumber($row['count'])?></strong></div><?php endforeach ?>
</section>
<?php endif;
