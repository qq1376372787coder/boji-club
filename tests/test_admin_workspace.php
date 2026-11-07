<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/app-config.php';
require __DIR__.'/../account-server/admin/config-input.php';
require __DIR__.'/../account-server/admin/workspace.php';
function verifyWorkspace(bool $ok,string $message):void{if(!$ok)throw new RuntimeException($message);}
$current=appConfigDefaults();
$current['minimum_build']=137;$current['latest_build']=139;$current['ai_native_home']=true;
$current['onboarding_content']['welcome_title']='欢迎来到薄肌俱乐部';
$current['announcement']=['enabled'=>true,'title'=>'线上公告','body'=>'请保留其他栏目'];
$next=appConfigDraftMerge($current,adminConfigSectionChanges(['config_section'=>'features','ai_enabled'=>'1'],$current));
verifyWorkspace($next['minimum_build']===137&&$next['latest_build']===139,'feature save overwrote version controls');
verifyWorkspace($next['announcement']===$current['announcement'],'feature save overwrote announcement');
verifyWorkspace($next['ai_native_home']===true,'feature save overwrote unexposed home flag');
$next=appConfigDraftMerge($current,adminConfigSectionChanges(['config_section'=>'onboarding-welcome','onboarding_welcome_title'=>'新的欢迎','onboarding_welcome_body'=>'很高兴见到你'],$current));
verifyWorkspace($next['onboarding_content']['task_labels']===$current['onboarding_content']['task_labels'],'welcome overwrote quick actions');
verifyWorkspace($next['onboarding_content']['tips']===$current['onboarding_content']['tips'],'welcome overwrote tips');
verifyWorkspace($next['onboarding_content_version']===$current['onboarding_content_version']+1,'content version did not advance');
$next=appConfigDraftMerge($current,adminConfigSectionChanges(['config_section'=>'versions','minimum_build'=>'138','latest_build'=>'140'],$current));
verifyWorkspace($next['ai_enabled']===$current['ai_enabled']&&$next['onboarding_content']===$current['onboarding_content'],'version save overwrote unrelated fields');
try{adminConfigSectionChanges(['config_section'=>'unknown'],$current);throw new LogicException('unknown section accepted');}catch(RuntimeException $expected){}
try{appConfigDraftMerge($current,adminConfigSectionChanges(['config_section'=>'versions','minimum_build'=>'200','latest_build'=>'140'],$current));throw new LogicException('invalid version accepted');}catch(RuntimeException $expected){}
$_GET=['p'=>'ai','days'=>'7','kind'=>'food','page'=>'3','tab'=>'ai-task-log'];$_POST=[];
verifyWorkspace(adminSelectedPanel('ai')==='ai-task-log','server section routing changed');
parse_str(parse_url(adminUrl(['page'=>4]),PHP_URL_QUERY),$url);
verifyWorkspace($url['days']==='7'&&$url['kind']==='food'&&$url['page']==='4','pagination lost filters');
$_POST=['ui_section'=>'ai-capacity'];verifyWorkspace(adminSelectedPanel('ai')==='ai-capacity','POST error lost active section');
$_POST=[];$_GET=['p'=>'ai','tab'=>'untrusted'];verifyWorkspace(adminSelectedPanel('ai')==='ai-live-cap','unknown section did not fall back safely');
verifyWorkspace(adminMemberId('NO. 010001')===1&&adminMemberId('10001')===10001,'member number confused with internal ID');
echo "PASS admin workspace scoped configuration and routing\n";
