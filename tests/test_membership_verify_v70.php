<?php
declare(strict_types=1);
require dirname(__DIR__).'/account-server/public/revenuecat.php';
$checks=0;
function check70(bool $ok,string $label): void { global $checks; if(!$ok)throw new RuntimeException($label); $checks++; }
$config=require dirname(__DIR__).'/account-server/revenuecat-config.example.php';
$now=(int)floor(microtime(true)*1000);
$customer=['object'=>'customer','id'=>'boji-970001','project_id'=>$config['revenuecat_project_id']];
$ent=['object'=>'entitlement','id'=>$config['revenuecat_v2_entitlement_id'],'lookup_key'=>$config['revenuecat_entitlement_id'],'project_id'=>$config['revenuecat_project_id'],'state'=>'active'];
$active=[['object'=>'customer.active_entitlement','entitlement_id'=>$ent['id'],'expires_at'=>$now+86400000]];
$monthly=['object'=>'subscription','id'=>'sub-fixture-monthly','customer_id'=>$customer['id'],'product_id'=>'prod84eab5a54f',
    'environment'=>'sandbox','store'=>'app_store','starts_at'=>$now-10000,'current_period_ends_at'=>$now+86400000,
    'ends_at'=>$now+86400000,'gives_access'=>true,'pending_payment'=>false,'status'=>'active',
    'entitlements'=>['object'=>'list','items'=>[$ent],'next_page'=>null]];
$permanent=['object'=>'purchase','id'=>'purch-fixture-lifetime','customer_id'=>$customer['id'],'product_id'=>'prod53ea4e8e97',
    'environment'=>'sandbox','store'=>'app_store','purchased_at'=>$now-10000,'status'=>'owned',
    'entitlements'=>['object'=>'list','items'=>[$ent],'next_page'=>null]];
$decide=static fn($subs,$purchases,$entitlements=null,$who=null)=>revenueCatSnapshotPolicy($who??$customer,$subs,$purchases,$entitlements??$active,$config,970001,$now);
$d=$decide([$monthly],[]); check70($d['active']&&$d['product_id']==='yuefu','Monthly accepted');
$annual=$monthly;$annual['product_id']='prod5e2b6410d5';$annual['ends_at']=$now+365*86400000;
$d=$decide([$annual],[]);check70($d['active']&&$d['product_id']==='nianfu','Annual accepted');
$d=$decide([],[$permanent]);check70($d['active']&&$d['expires_at']==='9999-12-31 23:59:59','Lifetime accepted');
$d=$decide([$monthly],[$permanent]);check70($d['product_id']==='yongjiu','Lifetime wins over a shorter subscription');
$d=$decide([$monthly],[],[]);check70(!$d['active'],'Missing Pro entitlement does not grant access');
$d=$decide([],[]);check70(!$d['active'],'Promotional entitlement without an Apple purchase does not grant access');
foreach(['customer_id'=>'boji-970002','environment'=>'production','store'=>'test_store','product_id'=>'prod-unknown'] as $field=>$value) {
    $bad=$monthly;$bad[$field]=$value;check70(!$decide([$bad],[])['active'],'Reject wrong '.$field);
}
$bad=$monthly;$bad['gives_access']=false;check70(!$decide([$bad],[])['active'],'Expired or paused subscription has no access');
$bad=$monthly;$bad['gives_access']=false;$bad['pending_payment']=true;check70(!$decide([$bad],[])['active'],'New pending purchase does not grant access');
$bad=$monthly;$bad['starts_at']=$now+10000;check70(!$decide([$bad],[])['active'],'Future subscription cannot grant early access');
$bad=$monthly;$bad['ends_at']=$now-10000;$bad['current_period_ends_at']=$now-10000;$bad['pending_payment']=true;$bad['status']='in_grace_period';
$d=$decide([$bad],[]);check70($d['active']&&strtotime($d['expires_at'].' UTC')<=(int)floor($now/1000)+300,'Grace-period access uses a bounded renewable lease');
$bad=$permanent;$bad['status']='refunded';check70(!$decide([],[$bad])['active'],'Refunded lifetime cannot remain active');
$bad=$monthly;$bad['entitlements']['items'][0]['lookup_key']='another_pro';check70(!$decide([$bad],[])['active'],'Wrong entitlement lookup key rejected');
$bad=$monthly;$bad['entitlements']['items'][0]['state']='inactive';check70(!$decide([$bad],[])['active'],'Archived entitlement rejected');
$bad=$customer;$bad['id']='boji-970002';check70(!$decide([$monthly],[],null,$bad)['active'],'Transferred canonical account cannot unlock old account');
foreach(['false',null,1] as $value) {
    $bad=$monthly;$bad['gives_access']=$value;$threw=false;
    try{$decide([$bad],[]);}catch(UnexpectedValueException){$threw=true;}
    check70($threw,'Malformed gives_access is not trusted');
}
$bad=$customer;$bad['project_id']='other-project';$threw=false;
try{$decide([$monthly],[],null,$bad);}catch(UnexpectedValueException){$threw=true;}
check70($threw,'Wrong RC project rejected');
$bad=$active;$bad[0]['expires_at']=$now-1;check70(!$decide([$monthly],[],$bad)['active'],'Expired global entitlement rejected');
echo json_encode(['passed'=>$checks],JSON_THROW_ON_ERROR)."\n";
