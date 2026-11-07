<?php
$titles=['feedback'=>'用户反馈','overview'=>'工作台','users'=>'成员管理','user'=>'成员详情','subscriptions'=>'订阅与权益核对','alerts'=>'异常提醒','club'=>'活动管理','badges'=>'徽章','gifts'=>'礼品','shipping'=>'发货','notifications'=>'通知文案','ai'=>'Club AI','automation'=>'自动跟进','push'=>'推送设置','storage'=>'图片空间','system'=>'服务状态','audit'=>'操作记录','config'=>'App 配置','admins'=>'管理员','settings'=>'账号安全','login'=>'管理员登录'];
if(!isset($titles[$page])){http_response_code(404);exit('页面不存在');}
if($admin)requireAdminPage($page);
$activeModule=adminModuleFor($page);
$pageGroup=adminModules()[$activeModule][0];
$pagePanel=adminSelectedPanel($page);
$writeProbe=['feedback'=>'feedback_reply','club'=>'club_season_create','badges'=>'reward_catalog_create','gifts'=>'reward_catalog_create','shipping'=>'club_claim_status','notifications'=>'notification_template_create','ai'=>'ai_capacity','automation'=>'automation_pause','push'=>'push_budget_update','storage'=>'storage_capacity','users'=>'member_note','user'=>'member_note'];
$pageReadOnly=isset($writeProbe[$page])&&!adminCanWriteAction($writeProbe[$page]);
$pageDescriptions=['subscriptions'=>'查订单来源，核对会员是否正确生效。','alerts'=>'查看服务异常、恢复情况和邮件发送结果。','overview'=>'今天要处理的事，都在这里。','users'=>'查找成员，查看记录或调整会员。','user'=>'查看资料、训练与饮食，处理会员和账号问题。','club'=>'创建活动，设置参与条件与奖励。','badges'=>'维护活动中可获得的徽章。','gifts'=>'维护实物礼品和默认库存。','shipping'=>'处理申领，填写物流并跟进送达。','feedback'=>'查看问题、照片与视频，直接回复用户。','ai'=>'查看运行情况，调整模型和使用额度。','automation'=>'查看自动跟进，处理暂停或失败的任务。','push'=>'控制发送频率，管理暂停接收的账号。','notifications'=>'编辑通知文案，查看发送结果。','config'=>'修改 App 功能、引导和公告，核对后发布。','storage'=>'查看图片空间，调整上传上限。','system'=>'检查服务和备份是否正常。','audit'=>'查看谁在什么时候进行了什么操作。','admins'=>'按工作职责分配后台权限。','settings'=>'管理当前管理员的登录密码。'];
function adminNavIcon(string $key): string {
    $paths=['overview'=>'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z','members'=>'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M18 8a4 4 0 0 1 0 8 M22 21v-2a4 4 0 0 0-3-3 M13 7a4 4 0 1 1-8 0a4 4 0 1 1 8 0','ai'=>'M12 3v3 M12 18v3 M3 12h3 M18 12h3 M8 8h8v8H8z','club'=>'M4 8h16v13H4z M3 4h18v4H3z M12 4v17 M12 4C7-2 3 3 8 4 M12 4c5-6 9-1 4 0','feedback'=>'M21 15a3 3 0 0 1-3 3H8l-5 3V6a3 3 0 0 1 3-3h12a3 3 0 0 1 3 3z M7 8h10 M7 12h6','messages'=>'M4 4h16v16H4z M4 5l8 7 8-7','system'=>'M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6'];
    return '<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="'.$paths[$key].'"/></svg>';
}
