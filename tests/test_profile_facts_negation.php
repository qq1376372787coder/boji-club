<?php
declare(strict_types=1);
// P0-2 否定表回归：急性风险词的否定剥离必须覆盖完整词表。
// 纯函数用例，不需要数据库；与 test_build119_repair.php / test_build121_completion.php
// 中既有的 profileFactSafety 断言兼容。
require_once __DIR__.'/../account-server/public/profile-facts.php';

function verifyNeg(bool $value, string $name): void {
    if (!$value) throw new RuntimeException($name);
    echo "PASS {$name}\n";
}
function deniedSafety(string $limitations): array {
    return profileFactSafety(['facts'=>['limitations'=>['value'=>$limitations]]], []);
}
function draftSafety(string $limitations): array {
    return profileFactSafety(['facts'=>[]], ['fields'=>['limitations'=>['value'=>$limitations]]]);
}

// 1) 否定必须生效：修复前这些只有 8 个短语里的词会被剥离，其余（骨折/晕厥/高烧…）
//    即使写了「没有」也照常拦截。
$denied = [
    '没有骨折' => '没有骨折',
    '无晕厥' => '无晕厥',
    '否认高烧' => '否认高烧',
    '没有发热' => '没有发热',
    '不再有晕倒' => '不再有晕倒',
    '没心悸' => '没心悸',
    '未见眼前发黑' => '未见眼前发黑',
    '不发热' => '不发热',
    '没有胸痛' => '没有胸痛',
    '没有呼吸困难' => '没有呼吸困难',
    '没有胸闷' => '没有胸闷',
    '没有怀孕' => '没有怀孕',
    '没有胸部疼痛' => '没有胸部疼痛',
    '没有喘不上气' => '没有喘不上气',
    '状态正常，没有骨折也没有高烧' => '多项否定',
];
foreach ($denied as $text => $label) {
    verifyNeg(deniedSafety($text)['safety_blocked'] === false, "denied symptom is not acute: {$label}（{$text}）");
}

// 2) 阳性必须仍然拦截：剥离只删除「否定 + 词」的组合，绝不放走真阳性。
$acute = [
    '骨折' => '骨折',
    '晕厥' => '晕厥',
    '高烧' => '高烧',
    '发热' => '发热',
    '心悸' => '心悸',
    '心慌' => '心慌',
    '眼前发黑' => '眼前发黑',
    '剧痛' => '剧痛',
    '胸痛' => '胸痛',
    '呼吸困难' => '呼吸困难',
    '喘得很厉害，说不出整句话' => '呼吸急促',
    '没有胸痛，但骨折' => '否定只覆盖前半句',
    '训练时胸痛呼吸困难' => '既有用例',
    '以前骨折过' => '既往史不被否定词规则误判为安全',
];
foreach ($acute as $text => $label) {
    verifyNeg(deniedSafety($text)['safety_blocked'] === true, "acute symptom blocked: {$label}（{$text}）");
}

// 3) 草稿路径（draft.fields.limitations）与文档路径同样生效。
verifyNeg(draftSafety('没有骨折')['safety_blocked'] === false, 'draft denial is not acute');
verifyNeg(draftSafety('骨折')['safety_blocked'] === true, 'draft acute symptom blocked');

// 4) 特殊营养背景与既有语义不受否定表改动影响。
verifyNeg(profileFactSafety(['facts'=>['nutrition_context'=>['value'=>'孕期或哺乳期']]], [])['safety_blocked'] === true, 'special nutrition context still blocks');
verifyNeg(profileFactSafety(['facts'=>['limitations'=>['value'=>'没有胸痛，状态正常']]], [])['safety_blocked'] === false, 'legacy negated chest pain case still passes');
verifyNeg(profileFactSafety(['facts'=>['limitations'=>['value'=>'无胸痛']]], ['fields'=>['limitations'=>['value'=>'训练时胸痛呼吸困难']]])['safety_blocked'] === true, 'new unconfirmed acute draft still wins');

echo "P0-2 NEGATION TABLE CHECKS PASSED\n";
