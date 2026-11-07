<?php
declare(strict_types=1);

/** Presentation routing only; permissions and every write remain in bootstrap. */
function adminModules(): array {
    return [
        'overview'=>['工作台','overview'=> '今日概况'],
        'members'=>['成员管理','users'=>'成员列表','user'=>'成员详情','subscriptions'=>'订阅核对'],
        'ai'=>['Club AI','ai'=>'运行与模型'],
        'club'=>['活动与奖励','club'=>'活动','badges'=>'徽章','gifts'=>'礼品','shipping'=>'发货'],
        'feedback'=>['用户反馈','feedback'=>'反馈工单'],
        'messages'=>['消息与跟进','automation'=>'自动跟进','push'=>'推送设置','notifications'=>'通知文案'],
        'system'=>['系统设置','config'=>'App 配置','storage'=>'图片空间','system'=>'服务状态','alerts'=>'异常提醒','audit'=>'操作记录','admins'=>'管理员','settings'=>'账号安全'],
    ];
}
function adminModuleFor(string $page): string {
    foreach(adminModules() as $key=>$items)if(isset($items[$page]))return $key;
    return 'overview';
}
function adminPanelOptions(string $page): array {
    return match($page) {
        'user'=>['profile-vip'=>'资料与会员','ops-follow'=>'标签与备注','daily-records'=>'训练与饮食','account-sec'=>'账号管理'],
        'club'=>['season-list'=>'活动列表','season-edit'=>'编辑活动','season-create'=>'新建活动','season-claims'=>'申领与动态'],
        'ai'=>['ai-live-cap'=>'运行概况','ai-capacity'=>'使用额度','ai-router-prov'=>'模型配置','ai-task-log'=>'调用记录','ai-runs-trace'=>'问题排查'],
        'config'=>['features'=>'功能开关','onboarding'=>'新用户引导','announcement'=>'App 公告','versions'=>'版本更新','history'=>'发布记录'],
        'automation'=>['members'=>'成员跟进','history'=>'执行记录','statistics'=>'统计'],
        'push'=>['budget'=>'发送频率','blocks'=>'停发名单','statistics'=>'发送统计'],
        'notifications'=>['templates'=>'消息模板','receipts'=>'发送记录','plans'=>'定时计划'],
        'storage'=>['usage'=>'空间用量','limits'=>'上传设置'],
        'system'=>['health'=>'服务检查','backup'=>'备份状态'],
        'admins'=>['accounts'=>'管理员列表','roles'=>'角色说明'],
        default=>[],
    };
}
function adminSelectedPanel(string $page): string {
    $options=adminPanelOptions($page);if(!$options)return '';
    $value=(string)($_POST['ui_section']??$_GET['tab']??'');
    if(isset($options[$value]))return $value;
    if($page==='user'&&isset($_GET['date']))return 'daily-records';
    if($page==='club'&&isset($_GET['new']))return 'season-create';
    if($page==='club'&&!empty($_GET['season']))return 'season-edit';
    if($page==='ai'&&array_intersect(['audit','kind','status','page','trace'],array_keys($_GET)))return isset($_GET['trace'])?'ai-runs-trace':'ai-task-log';
    return (string)array_key_first($options);
}
function adminUrl(array $changes=[], bool $retain=true): string {
    $values=$retain?array_intersect_key($_GET,array_flip(['p','id','season','date','q','status','kind','page','tag','ticket','tab','days','trace','audit','before','operation','plan','environment','event_page','member','state'])):[];
    foreach($changes as $key=>$value){if($value===null)unset($values[$key]);else $values[$key]=$value;}
    return '/admin/?'.http_build_query($values);
}
function adminSectionNav(string $page, string $active): void {
    $items=adminPanelOptions($page);if(!$items)return;
    echo '<nav class="workspace-tabs" aria-label="页面栏目">';
    foreach($items as $key=>$label){
        if($page==='club'&&$key==='season-edit'&&empty($_GET['season']))continue;
        $url=adminUrl(['tab'=>$key,'page'=>null,'new'=>null]);
        echo '<a data-workspace-tab href="'.h($url).'"'.($key===$active?' class="selected" aria-current="page"':'').'>'.h($label).'</a>';
    }
    echo '</nav>';
}
function adminEditorStart(string $id,string $title,string $button='编辑',string $class=''): void {
    echo '<details class="editor-disclosure '.h($class).'" data-editor="'.h($id).'"><summary>'.h($button).'</summary><div data-editor-body><header class="editor-header"><h2>'.h($title).'</h2><button type="button" class="icon-close" data-close-editor aria-label="关闭">×</button></header>';
}
function adminEditorEnd(): void { echo '</div></details>'; }
function adminPageCount(int $page,bool $more): void {
    echo '<nav class="pagination" aria-label="翻页">';
    if($page>1)echo '<a href="'.h(adminUrl(['page'=>$page-1])).'">上一页</a>';
    echo '<span>第 '.$page.' 页</span>';
    if($more)echo '<a href="'.h(adminUrl(['page'=>$page+1])).'">下一页</a>';
    echo '</nav>';
}

/** Only visible, non-secret fields may be restored after a rejected edit. */
function adminRetryValues(): array {
    $out=[];
    $flatten=function(array $values,string $prefix='')use(&$flatten,&$out):void{
        foreach($values as $key=>$value){
            $name=$prefix===''?(string)$key:$prefix.'['.$key.']';
            if(preg_match('/password|api_key|csrf|token/i',$name))continue;
            if(is_array($value))$flatten($value,$name);
            elseif(is_string($value)&&strlen($value)<=10000)$out[$name]=$value;
        }
    };
    $flatten($_POST);return $out;
}

function adminMemberId(mixed $raw): int {
    if(is_string($raw)&&preg_match('/^NO[.\s#-]*([0-9]{5,16})$/iD',trim($raw),$match)){
        $number=filter_var(ltrim($match[1],'0'),FILTER_VALIDATE_INT);
        if($number===false||$number<=10000)throw new RuntimeException('成员编号不正确。');
        return $number-10000;
    }
    $id=filter_var($raw,FILTER_VALIDATE_INT);
    if($id===false||$id<1)throw new RuntimeException('请填写成员编号，例如 NO. 010001，或成员详情中的账号 ID。');
    return $id;
}
