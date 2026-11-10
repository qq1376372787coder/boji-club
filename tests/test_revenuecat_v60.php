<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/revenuecat.php';
$checks=[];
function rc60(bool $ok, string $label): void {
    global $checks; if (!$ok) throw new RuntimeException($label); $checks[]=$label;
}
$cfg=['revenuecat_environment'=>'SANDBOX','revenuecat_store'=>'TEST_STORE','revenuecat_app_id'=>'app_fixture',
    'revenuecat_product_ids'=>['monthly','six_month','lifetime'], 'revenuecat_lifetime_product_ids'=>['lifetime'],
    'revenuecat_entitlement_id'=>'薄肌俱乐部_pro'];
$now=(int)(microtime(true)*1000);
$event=['id'=>'rc60-purchase-01','type'=>'NON_RENEWING_PURCHASE','app_id'=>'app_fixture','app_user_id'=>'boji-960001',
    'environment'=>'SANDBOX','store'=>'TEST_STORE','product_id'=>'lifetime','entitlement_ids'=>['薄肌俱乐部_pro'],
    'original_transaction_id'=>'rc60-lifetime-tx','transaction_id'=>'rc60-lifetime-tx',
    'purchased_at_ms'=>$now,'event_timestamp_ms'=>$now,'expiration_at_ms'=>null];
$d=revenueCatDecision($event,$cfg);
rc60($d!==null && $d['status']==='active' && $d['expires']==='9999-12-31 23:59:59','Lifetime with null expiration grants permanent access');
$bad=$event;unset($bad['expiration_at_ms']);rc60(revenueCatDecision($bad,$cfg)===null,'Missing expiration is not silently interpreted as lifetime');
$bad=$event;$bad['expiration_at_ms']='nonsense';rc60(revenueCatDecision($bad,$cfg)===null,'Malformed expiration rejected');
foreach (['monthly','six_month'] as $product) {
    $sub=$event;$sub['product_id']=$product;$sub['type']='INITIAL_PURCHASE';
    rc60(revenueCatDecision($sub,$cfg)===null,$product.' without expiration rejected');
    $sub['expiration_at_ms']=$now+86400000;
    rc60(revenueCatDecision($sub,$cfg)['status']==='active',$product.' with expiration grants access');
}
foreach (['environment'=>'PRODUCTION','store'=>'APP_STORE','app_id'=>'other-app','product_id'=>'unapproved'] as $field=>$value) {
    $bad=$event;$bad[$field]=$value;rc60(revenueCatDecision($bad,$cfg)===null,'Reject wrong '.$field);
}
foreach ([null,[],['other_pro']] as $entitlements) {
    $bad=$event;$bad['entitlement_ids']=$entitlements;rc60(revenueCatDecision($bad,$cfg)===null,'Wrong/missing entitlement cannot grant membership');
}
$refund=$event;$refund['type']='CANCELLATION';$refund['cancel_reason']='CUSTOMER_SUPPORT';unset($refund['entitlement_ids']);
rc60(revenueCatDecision($refund,$cfg)['status']==='revoked','Lifetime refund revokes even after entitlement mapping removed');
$undo=$event;$undo['type']='REFUND_REVERSED';rc60(revenueCatDecision($undo,$cfg)['status']==='active','Refund reversal can reinstate lifetime');
$cancel=$event;$cancel['type']='CANCELLATION';$cancel['cancel_reason']='UNSUBSCRIBE';rc60(revenueCatDecision($cancel,$cfg)===null,'Cancellation is not an immediate loss of access');
$appleCfg=$cfg;$appleCfg['revenuecat_store']='APP_STORE';$appleCfg['revenuecat_product_ids']=['yuefu','nianfu','yongjiu'];$appleCfg['revenuecat_lifetime_product_ids']=['yongjiu'];
foreach (['yuefu','nianfu','yongjiu'] as $id) {
    $apple=$event;$apple['store']='APP_STORE';$apple['product_id']=$id;
    if($id!=='yongjiu'){$apple['type']='INITIAL_PURCHASE';$apple['expiration_at_ms']=$now+86400000;}
    rc60(revenueCatDecision($apple,$appleCfg)['status']==='active','Apple sandbox accepts configured '.$id);
    $apple['environment']='PRODUCTION';rc60(revenueCatDecision($apple,$appleCfg)===null,'TestFlight server rejects production '.$id);
}
$expired=$event;$expired['type']='EXPIRATION';rc60(revenueCatDecision($expired,$cfg)['status']==='expired','Expiration revokes access');
$grace=$event;$grace['type']='BILLING_ISSUE';$grace['product_id']='monthly';$grace['expiration_at_ms']=$now+1000;$grace['grace_period_expiration_at_ms']=$now+86400000;
rc60(revenueCatDecision($grace,$cfg)['expires']===revenueCatDate($grace['grace_period_expiration_at_ms']),'Billing grace period honored');
rc60(revenueCatMemberUserID('boji-960001')===960001,'Stable app user ID accepted');
foreach (['$RCAnonymousID:xxx','boji-0','boji-960001-other','+8617737516328'] as $value) rc60(revenueCatMemberUserID($value)===null,'Unsupported identity rejected');
$_SERVER['HTTP_AUTHORIZATION']='';rc60(!revenueCatWebhookAuthorized($cfg),'Missing Authorization rejected');
$secret=str_repeat('x',40);$auth=$cfg+['revenuecat_webhook_authorization'=>$secret];
$_SERVER['HTTP_AUTHORIZATION']='wrong';rc60(!revenueCatWebhookAuthorized($auth),'Wrong Authorization rejected');
$_SERVER['HTTP_AUTHORIZATION']=$secret;rc60(revenueCatWebhookAuthorized($auth),'Exact configured Authorization accepted');

// Integration checks use an explicitly isolated database created by the runner.
$dsn=getenv('BOJI_RC60_TEST_DSN');
if ($dsn) {
    if (!str_contains($dsn,'dbname=bojiclub_revenuecat_v60_fixture;')) throw new RuntimeException('Only isolated RC60 fixture database permitted');
    $db=new PDO($dsn,'root',getenv('MYSQL_PWD') ?: '',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
    $db->exec(file_get_contents(__DIR__.'/../account-server/schema.sql'));
    $db->exec("DELETE FROM users WHERE id IN(960001,960002);DELETE FROM revenuecat_events WHERE event_id LIKE 'rc60-%'");
    $db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES(960001,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(960002,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
    $member=static fn(int $id): array|false=>$db->query('SELECT * FROM membership_entitlements WHERE user_id='.$id)->fetch();
    processRevenueCatEvent($db,$cfg,$event);
    rc60($member(960001)['status']==='active' && $member(960001)['expires_at']==='9999-12-31 23:59:59','DB persists lifetime entitlement');
    rc60(!empty(processRevenueCatEvent($db,$cfg,$event)['duplicate']),'Duplicate purchase remains idempotent');
    $transfer=['id'=>'rc60-transfer-01','type'=>'TRANSFER','app_id'=>'app_fixture','transferred_from'=>['boji-960001'],'transferred_to'=>['boji-960002'],'event_timestamp_ms'=>$now+10];
    rc60(!empty(processRevenueCatEvent($db,$cfg,$transfer)['transferred']),'Transfer accepts optional missing store/environment');
    rc60($member(960001)['status']==='expired' && $member(960002)['status']==='active','Transfer changes both owners correctly');
    rc60(!empty(processRevenueCatEvent($db,$cfg,$transfer)['duplicate']),'Duplicate transfer idempotent');
    $wrong=$transfer;$wrong['id']='rc60-transfer-wrong-store';$wrong['store']='APP_STORE';$wrong['transferred_from']=['boji-960002'];$wrong['transferred_to']=['boji-960001'];
    rc60(!empty(processRevenueCatEvent($db,$cfg,$wrong)['ignored']),'Other store cannot transfer test membership');
    $refund['id']='rc60-refund-01';$refund['app_user_id']='boji-960002';$refund['event_timestamp_ms']=$now+20;
    processRevenueCatEvent($db,$cfg,$refund);rc60($member(960002)['status']==='revoked','DB refund revokes lifetime');
    $old=$event;$old['id']='rc60-old-purchase';$old['app_user_id']='boji-960002';
    rc60(!empty(processRevenueCatEvent($db,$cfg,$old)['stale']) && $member(960002)['status']==='revoked','Old notification cannot resurrect refunded lifetime');
    $undo['id']='rc60-refund-reversed';$undo['app_user_id']='boji-960002';$undo['event_timestamp_ms']=$now+30;
    processRevenueCatEvent($db,$cfg,$undo);rc60($member(960002)['status']==='active','DB refund reversal restores lifetime');
    $sub=$event;$sub['id']='rc60-monthly';$sub['app_user_id']='boji-960002';$sub['product_id']='monthly';$sub['type']='INITIAL_PURCHASE';$sub['original_transaction_id']='rc60-monthly-tx';$sub['expiration_at_ms']=$now+86400000;
    processRevenueCatEvent($db,$cfg,$sub);
    rc60($member(960002)['plan_code']==='lifetime','Lifetime takes priority over shorter active subscription');
    $refund['id']='rc60-refund-02';$refund['event_timestamp_ms']=$now+40;processRevenueCatEvent($db,$cfg,$refund);
    rc60($member(960002)['status']==='active' && $member(960002)['plan_code']==='monthly','Lifetime refund preserves a different paid subscription');
    $db->exec("INSERT INTO membership_admin_grants(user_id,status,starts_at,expires_at,updated_at) VALUES(960002,'active',UTC_TIMESTAMP(),'2040-01-01',UTC_TIMESTAMP())");
    $sub['id']='rc60-monthly-refund';$sub['type']='CANCELLATION';$sub['cancel_reason']='CUSTOMER_SUPPORT';$sub['event_timestamp_ms']=$now+50;processRevenueCatEvent($db,$cfg,$sub);
    rc60($member(960002)['source']==='admin','Refund preserves a separate administrator grant');
    $unknown=$event;$unknown['id']='rc60-unknown-user';$unknown['app_user_id']='boji-999999';rc60(!empty(processRevenueCatEvent($db,$cfg,$unknown)['ignored']),'Unknown account cannot receive paid membership');
    $db->exec('DELETE FROM users WHERE id IN(960001,960002)');
    rc60((int)$db->query('SELECT COUNT(*) FROM revenuecat_subscriptions')->fetchColumn()===0,'Account deletion removes purchase ownership');
}
echo json_encode(['passed'=>true,'checks'=>count($checks),'database_tested'=>(bool)$dsn,'cases'=>$checks],JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT),"\n";
