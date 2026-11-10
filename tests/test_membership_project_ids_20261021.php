<?php
declare(strict_types=1);
require dirname(__DIR__).'/account-server/public/revenuecat.php';
$config=require dirname(__DIR__).'/account-server/revenuecat-config.example.php';
$checks=0;
function projectCheck(bool $ok,string $label): void { global $checks; if(!$ok)throw new RuntimeException($label); $checks++; }
$short=$config['revenuecat_project_id'];$canonical='proj'.$short;
projectCheck(revenueCatProjectIDsMatch($canonical,$short),'Canonical API v2 ID matches legacy configuration');
projectCheck(revenueCatProjectIDsMatch($short,$canonical),'Legacy response remains compatible with canonical configuration');
projectCheck(!revenueCatProjectIDsMatch('proj00000000',$short),'Different project is rejected');
projectCheck(!revenueCatProjectIDsMatch('projproj'.$short,$short),'Repeated prefix is rejected');
projectCheck(!revenueCatProjectIDsMatch(null,$short),'Missing project is rejected');
projectCheck(!revenueCatProjectIDsMatch('',''),'Empty project is rejected');
$now=(int)floor(microtime(true)*1000);$uid=970001;
$customer=['object'=>'customer','id'=>'boji-'.$uid,'project_id'=>$canonical];
$ent=['id'=>$config['revenuecat_v2_entitlement_id'],'lookup_key'=>$config['revenuecat_entitlement_id'],'project_id'=>$canonical,'state'=>'active'];
$active=[['object'=>'customer.active_entitlement','entitlement_id'=>$ent['id'],'expires_at'=>null]];
$purchase=['object'=>'purchase','id'=>'purch-fixture-canonical','customer_id'=>$customer['id'],'product_id'=>'prod53ea4e8e97',
    'store'=>'app_store','environment'=>'sandbox','status'=>'owned','purchased_at'=>$now-10000,
    'entitlements'=>['object'=>'list','items'=>[$ent],'next_page'=>null]];
$decide=static fn($who,$row,$cfg=null)=>revenueCatSnapshotPolicy($who,[],[$row],$active,$cfg??$config,$uid,$now);
$result=$decide($customer,$purchase);
projectCheck($result['active']&&$result['product_id']==='yongjiu'&&$result['expires_at']==='9999-12-31 23:59:59','Real API v2 project shape accepts verified owned lifetime purchase');
$bad=$customer;$bad['project_id']='proj00000000';$threw=false;
try{$decide($bad,$purchase);}catch(UnexpectedValueException){$threw=true;}
projectCheck($threw,'Wrong customer project still throws');
$bad=$purchase;$bad['entitlements']['items'][0]['project_id']='proj00000000';
projectCheck(!$decide($customer,$bad)['active'],'Wrong entitlement project still rejected');
$bad=$purchase;$bad['environment']='production';
projectCheck(!$decide($customer,$bad)['active'],'Wrong environment still rejected');
$bad=$purchase;$bad['status']='refunded';
projectCheck(!$decide($customer,$bad)['active'],'Refund still removes access');
$bad=$purchase;$bad['customer_id']='boji-970002';
projectCheck(!$decide($customer,$bad)['active'],'Different purchaser cannot obtain access');
$canonicalConfig=$config;$canonicalConfig['revenuecat_project_id']=$canonical;
projectCheck($decide($customer,$purchase,$canonicalConfig)['active'],'Canonical configuration also works');
echo json_encode(['passed'=>$checks],JSON_THROW_ON_ERROR)."\n";
