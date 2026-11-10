<?php
declare(strict_types=1);
/** Exact affirmative commands only. All mutations still pass the existing domain router. */
function aiFastWeightValue(string $question,string $defaultUnit='kg'): ?float {
    $patterns=['/^(?:请|帮我|请帮我)?(?:记|记录|登记|保存)(?:一下)?(?:(?:今天|今日)(?:早上|早晨|上午|下午|晚上)?)?的?(体重)?\s*(\d{1,3}(?:\.\d{1,2})?)\s*(公斤|千克|kg|斤|磅|lb)?$/iu',
      '/^(?:(?:今天|今日)(?:早上|早晨|上午|下午|晚上)?)?(体重)\s*(\d{1,3}(?:\.\d{1,2})?)\s*(公斤|千克|kg|斤|磅|lb)?[，, ]*(?:请)?(?:记录|登记|保存)(?:一下)?$/iu'];
    foreach($patterns as $pattern)if(preg_match($pattern,$question,$m)){
        if(empty($m[1])&&empty($m[3]))return null;
        $unit=strtolower($m[3]??$defaultUnit);if($unit==='')$unit=$defaultUnit;
        $kg=(float)$m[2]*($unit==='斤'?.5:(in_array($unit,['磅','lb'],true)?.45359237:1));
        return $kg>=20&&$kg<=400?round($kg,1):null;
    }
    return null;
}
function aiFastIntent(array $request): ?array {
    $p=$request['payload']??[];
    if(($p['_fast_intent_enabled']??true)===false||($p['purpose']??'dialogue')!=='dialogue'||!empty($p['_references'])||!empty($p['images'])||!empty($p['deep_analysis']))return null;
    $text=preg_replace('/[。！!\s]+$/u','',trim((string)($p['question']??'')));
    $map=[
        '今天练什么'=>'training.get_today','今天训练安排'=>'training.get_today',
        '开始今天训练'=>'training.start_session','开始今天的训练'=>'training.start_session','继续刚才训练'=>'training.start_session','恢复训练'=>'training.start_session',
        '结束训练'=>'training.finish_session','训练结束了'=>'training.finish_session',
        '我的俱乐部进度'=>'club.get_progress',
    ];
    $kg=aiFastWeightValue($text,$p['action_preferences']['weight_unit']??'kg');
    if($kg!==null)$map[$text]='body.record_weight';
    if(!isset($map[$text]))return null;
    $cap=$map[$text];$allowed=array_column($p['capabilities']??[],'capability');
    if(!in_array($cap,$allowed,true))return null;
    $input=in_array($cap,['training.get_today','training.start_session','training.finish_session'],true)?['date'=>$request['date']]:new stdClass();
    if($cap==='body.record_weight')$input=['date'=>$request['date'],'kilograms'=>$kg];
    $answer=match($cap){
        'training.start_session'=>'我会先核对今天的安排和进行中的训练，已有场次会恢复原训练。请以下方业务回执为准，不会重复创建训练。',
        'training.finish_session'=>'我会核对这场训练的实际登记情况；还有未登记组时，会先请你确认保存范围，不会把计划值补成已完成。请查看下方操作结果。',
        'training.get_today'=>'我会从你已同步的当天计划读取训练安排。下方卡片会展示实际安排；计划内容不代表你已经完成了这些训练。',
        'body.record_weight'=>'我会按你明确提供的体重提交本次测量；开启快速记录时直接登记，否则先给你核对。请以下方业务回执为准，不会改动个人资料体重或营养目标。',
        default=>'我会核对你有权限查看的俱乐部进度，只读取已确认的数据，不会改动训练次数、积分或其他成员的记录。',
    };
    return ['kind'=>'coach','notes'=>[],'intent'=>['kind'=>str_starts_with($cap,'training.')&&$cap!=='training.get_today'?'change_proposal':'query','rules'=>4],
        'coach'=>['answer'=>$answer,'sources'=>[],'actions'=>[],'purpose'=>'dialogue','capability_calls'=>[['capability'=>$cap,'input'=>$input]]]];
}

function aiDirectIntentAllowed(string $cap,string $text): bool {
    $text=trim($text);
    if(preg_match('/不要|先别|别改|别开始|别记|不(?:要|想|用|需要)?(?:记录|保存|登记|开始|结束)|不需要|只是问|能不能|可不可以|能否|如果|假如|[？?]|吗/u',$text))return false;
    return match($cap){
        'training.start_session'=>preg_match('/(?:开始|恢复|继续).{0,8}训练/u',$text)===1,
        'training.finish_session'=>preg_match('/结束.{0,8}训练|训练(?:结束|完成)了/u',$text)===1,
        'training.log_set'=>preg_match('/记录|记一下|记下|登记|第.{1,5}组.{0,12}(?:做了|完成)/u',$text)===1,
        'body.record_weight'=>preg_match('/记录|记一下|记一笔|记下|登记|保存/u',$text)===1 || preg_match('/^(?:帮我|给我)?记\s*\d+(?:\.\d+)?\s*(?:公斤|千克|kg|斤|磅|lb)[。！!\s]*$/iu',$text)===1,
        default=>preg_match('/记录|记一下|记一笔|记下|登记|保存/u',$text)===1,
    };
}
