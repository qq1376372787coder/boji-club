<?php
declare(strict_types=1);

/** Scoped editors must never turn absent controls into false/empty settings. */
function adminConfigSectionChanges(array $post,array $current): array {
    $section=(string)($post['config_section']??'');$out=[];
    $integer=static function(string $key,int $min,int $max)use($post):int{
        $value=filter_var($post[$key]??null,FILTER_VALIDATE_INT);
        if($value===false||$value<$min||$value>$max)throw new RuntimeException('请检查数字范围后再保存。');
        return $value;
    };
    switch($section){
        case 'features':
            foreach(['ai_enabled','club_enabled','action_system_enabled','ai_context_references_v1','ai_fast_intent_v1','ai_router_v3','ai_streaming_v2','training_commands','direct_records'] as $key)$out[$key]=isset($post[$key]);
            break;
        case 'versions':
            $out['minimum_build']=$integer('minimum_build',0,1000000);$out['latest_build']=$integer('latest_build',0,1000000);break;
        case 'announcement':
            $out['announcement']=['enabled'=>isset($post['announcement_enabled']),'title'=>(string)($post['announcement_title']??''),'body'=>(string)($post['announcement_body']??'')];break;
        case 'onboarding':
            $out=['onboarding_v2_enabled'=>isset($post['onboarding_v2_enabled']),'contextual_tips_enabled'=>isset($post['contextual_tips_enabled']),'onboarding_assist_daily_limit'=>$integer('onboarding_assist_daily_limit',1,100)];break;
        case 'onboarding-welcome':
        case 'onboarding-actions':
        case 'onboarding-tips':
            $content=$current['onboarding_content'];
            if($section==='onboarding-welcome'){
                $content['welcome_title']=(string)($post['onboarding_welcome_title']??'');$content['welcome_body']=(string)($post['onboarding_welcome_body']??'');
            }elseif($section==='onboarding-actions'){
                foreach(['plan_create','plan_import','meal_log','workout_log','explore'] as $key)$content['task_labels'][$key]=(string)($post['onboarding_task_'.$key]??'');
            }else{
                if(!is_array($post['onboarding_tips']??null))throw new RuntimeException('提示内容不完整，请重新打开。');
                $content['tips']=$post['onboarding_tips'];
            }
            $out=['onboarding_content'=>$content,'onboarding_content_version'=>(int)$current['onboarding_content_version']+1];break;
        default:throw new RuntimeException('配置栏目已变化，请刷新页面。');
    }
    return $out;
}
