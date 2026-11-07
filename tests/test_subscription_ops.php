<?php
declare(strict_types=1);
require dirname(__DIR__).'/account-server/admin/subscriptions.php';
require dirname(__DIR__).'/account-server/public/revenuecat.php';
require dirname(__DIR__).'/account-server/subscription-ops-migration.php';
require __DIR__.'/php_test_bootstrap.php';

function adminRoles(): array { return ['operator'=>['scopes'=>['users_sensitive']], 'support'=>['scopes'=>['users_support']], 'readonly'=>['scopes'=>['self']], 'super_admin'=>['scopes'=>['*']]]; }
function adminRole(): string { return $GLOBALS['admin']['role'] ?? 'readonly'; }
function h(mixed $value): string { return htmlspecialchars((string)$value,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8'); }
function safeNumber(mixed $value): string { return number_format((float)$value,0); }
function clubNumber(int $id): string { return 'NO. '.str_pad((string)(10000+$id),6,'0',STR_PAD_LEFT); }
function lockActiveUser(PDO $db, int $id): void {
    $q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$id]);
    if($q->fetchColumn()!=='active')throw new RuntimeException('user_unavailable');
}
function subscriptionTest(bool $condition, string $label): void {
    if (!$condition) throw new RuntimeException($label);
    $GLOBALS['subscriptionAssertions']++;
}
$subscriptionAssertions=0;
$admin=['role'=>'operator'];
subscriptionTest(subscriptionOpsAllowed(), 'Operator can view sensitive orders');
$admin=['role'=>'support'];
subscriptionTest(!subscriptionOpsAllowed(), 'Support cannot view sensitive order details');
try { subscriptionOpsRequireAccess(); throw new LogicException('Permission gate did not reject'); }
catch (RuntimeException $error) { subscriptionTest(str_contains($error->getMessage(),'无权'), 'Permission gate rejects before data reads'); }
$admin=['role'=>'readonly'];subscriptionTest(!subscriptionOpsAllowed(),'Readonly role cannot inspect order IDs');
$admin=['role'=>'super_admin'];subscriptionTest(subscriptionOpsAllowed(),'Super administrator can inspect');
$now=strtotime('2026-10-28 12:00:00 UTC');
$order=['status'=>'active','product_id'=>'annual','expires_at'=>'2027-10-28 12:00:00','starts_at'=>'2026-10-28 12:00:00','event_timestamp_ms'=>$now*1000,'last_transaction_id'=>'tx-one'];
$actual=$order+['source'=>'apple','plan_code'=>'annual'];
subscriptionTest(subscriptionOpsCompare([$order],null,null,$actual,$now)['consistent'],'Matching paid access is consistent');
subscriptionTest(!subscriptionOpsCompare([$order],null,null,null,$now)['consistent'],'Paid access missing entitlement is detected');
subscriptionTest(!subscriptionOpsCompare([],null,null,$actual,$now)['consistent'],'Unbacked active entitlement is detected');
$inactive=['observed_at_ms'=>$now*1000+1,'verified_status'=>'inactive','product_id'=>'','starts_at'=>null,'expires_at'=>null,'purchase_id'=>null];
subscriptionTest(!subscriptionOpsCompare([$order],$inactive,null,$actual,$now)['expected_active'],'New inactive verification supersedes old order');
$inactive['observed_at_ms']=$now*1000-1;
subscriptionTest(subscriptionOpsCompare([$order],$inactive,null,$actual,$now)['expected_active'],'Older verification cannot supersede new webhook');
$inactive['observed_at_ms']=$now*1000+1;
$gift=['status'=>'active','starts_at'=>'2026-10-28 12:00:00','expires_at'=>'2028-01-01 00:00:00'];
$giftActual=$gift+['source'=>'admin','plan_code'=>'gift','last_transaction_id'=>null];
subscriptionTest(subscriptionOpsCompare([$order],$inactive,$gift,$giftActual,$now)['consistent'],'Separate operator gift preserves access after inactive paid snapshot');
$revoked=$order;$revoked['status']='revoked';
subscriptionTest(str_contains(subscriptionOpsStatus($revoked,$now),'退款需另查'),'Revocation does not falsely confirm refund');
subscriptionTest(subscriptionOpsEventLabel('CANCELLATION')!==subscriptionOpsEventLabel('EXPIRATION'),'Cancellation and expiration are distinct');
subscriptionTest(subscriptionOpsDate('9999-12-31 23:59:59')==='长期有效','Lifetime sentinel is human readable');
subscriptionTest(subscriptionOpsEnvironment([])['record_environment']==='unknown','Historical environment stays unknown');
subscriptionTest(subscriptionOpsEnvironment(['revenuecat_environment'=>'SANDBOX'])['configured']==='SANDBOX','Sandbox server configuration is explicit');
$query=subscriptionOpsListQuery(['q'=>"x%' OR 1=1 --",'page'=>-1,'environment'=>'PRODUCTION']);
subscriptionTest(!str_contains($query['sql'],'OR 1=1 --')&&$query['page']===1,'Search is parameterized and pagination bounded');
subscriptionTest(str_contains($query['params'][1],'!%'),'LIKE wildcard is literal operator input');
$evidence=revenueCatEventEvidence(['environment'=>'SANDBOX','price'=>0,'currency'=>'CNY','cancel_reason'=>null,'app_user_id'=>'sensitive','authorization'=>'secret']);
subscriptionTest($evidence['price']===0&&!array_key_exists('app_user_id',$evidence)&&!array_key_exists('authorization',$evidence),'Evidence preserves actual zero and omits unrelated personal fields');
subscriptionTest(!array_key_exists('price_in_purchased_currency',$evidence),'Missing amounts are not manufactured');
subscriptionTest(subscriptionOpsMoneyLabel(null)==='金额未留存','Unknown money is explicit');
subscriptionTest(str_contains(subscriptionOpsMoneyLabel(json_encode($evidence)),'price=0'),'Actual zero amount is not dropped');

if (!getenv('BOJI_TEST_DSN_BASE')) {
    echo json_encode(['passed'=>$subscriptionAssertions,'database'=>'not run; set BOJI_TEST_DSN_BASE to an isolated local test MySQL'],JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR)."\n";
    exit;
}
$base=(string)getenv('BOJI_TEST_DSN_BASE');
if (preg_match('/(?:^|;)dbname=/i',$base)) throw new RuntimeException('Use a base DSN without a database');
$bootstrap=new PDO($base,getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$bootstrap->exec('CREATE DATABASE IF NOT EXISTS boji_subscription_ops_test CHARACTER SET utf8mb4');
$db=bojiTestDatabase('boji_subscription_ops_test');
bojiTestSchema($db,dirname(__DIR__).'/account-server');
subscriptionOpsMigrate($db);subscriptionOpsMigrate($db);
$ids=range(981001,981027);$marks=implode(',',array_fill(0,count($ids),'?'));
$db->prepare('DELETE FROM users WHERE id IN ('.$marks.')')->execute($ids);
$db->exec("DELETE FROM revenuecat_events WHERE event_id LIKE 'subops-test-%'");
$config=['revenuecat_product_ids'=>['annual'],'revenuecat_environment'=>'PRODUCTION','revenuecat_entitlement_id'=>'pro',
    'revenuecat_app_id'=>'app-test','revenuecat_store'=>'APP_STORE','revenuecat_project_id'=>'proj_test',
    'revenuecat_v2_entitlement_id'=>'ent_test','revenuecat_v2_products'=>[],'revenuecat_api_v2_key_file'=>'not-read-with-injected-provider'];
$admin=['role'=>'operator'];$liveNow=time();$eventMS=$liveNow*1000;
$event=['id'=>'subops-test-purchase','type'=>'INITIAL_PURCHASE','app_user_id'=>'boji-981001','environment'=>'PRODUCTION',
    'app_id'=>'app-test','store'=>'APP_STORE','product_id'=>'annual','event_timestamp_ms'=>$eventMS,
    'original_transaction_id'=>'subops-original','transaction_id'=>'subops-tx','purchased_at_ms'=>$eventMS,
    'expiration_at_ms'=>($liveNow+86400)*1000,'entitlement_ids'=>['pro'],'currency'=>'CNY','price'=>42.9,'price_in_purchased_currency'=>299];
try {
    $insert=$db->prepare("INSERT INTO users(id,status,created_at,updated_at) VALUES(?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
    foreach($ids as $id)$insert->execute([$id]);
    processRevenueCatEvent($db,$config,$event);
    $member=subscriptionOpsDetail($db,981001,1,$liveNow);
    subscriptionTest($member['check']['consistent']&&$member['actual']['status']==='active','Paid webhook still grants normal access');
    subscriptionTest($member['events'][0]['environment']==='PRODUCTION','Authenticated event environment is retained');
    subscriptionTest(str_contains($member['events'][0]['money_label'],'299'),'Actual purchased currency field retained separately');
    processRevenueCatEvent($db,$config,$event);
    subscriptionTest((int)$db->query("SELECT COUNT(*) FROM revenuecat_event_facts WHERE event_id='subops-test-purchase'")->fetchColumn()===1,'Retry is deduplicated by event ID');
    $cancel=$event;$cancel['id']='subops-test-cancel';$cancel['type']='CANCELLATION';$cancel['cancel_reason']='UNSUBSCRIBE';$cancel['event_timestamp_ms']++;
    unset($cancel['price'],$cancel['price_in_purchased_currency'],$cancel['currency']);
    processRevenueCatEvent($db,$config,$cancel);
    subscriptionTest(subscriptionOpsDetail($db,981001)['actual']['status']==='active','Normal cancellation does not remove already paid access');
    $facts=$db->query("SELECT * FROM revenuecat_event_facts WHERE event_id='subops-test-cancel'")->fetch();
    subscriptionTest($facts['cancel_reason']==='UNSUBSCRIBE'&&$facts['processing_result']==='ignored','Cancellation reason retained without changing policy');
    subscriptionTest(subscriptionOpsMoneyLabel($facts['evidence_json'])==='金额未留存','Cancellation does not borrow previous purchase amount');
    $sandbox=$event;$sandbox['id']='subops-test-sandbox';$sandbox['environment']='SANDBOX';$sandbox['event_timestamp_ms']+=2;
    processRevenueCatEvent($db,$config,$sandbox);
    subscriptionTest($db->query("SELECT processing_result FROM revenuecat_event_facts WHERE event_id='subops-test-sandbox'")->fetchColumn()==='ignored','Wrong environment is recorded but not applied');
    subscriptionTest(subscriptionOpsDetail($db,981001)['actual']['status']==='active','Ignored sandbox event does not change entitlement');
    subscriptionTest(subscriptionOpsList($db,['environment'=>'SANDBOX'])['total']===1,'Sandbox evidence is separately searchable');
    $transfer=['id'=>'subops-test-transfer-ignored','type'=>'TRANSFER','environment'=>'SANDBOX','app_id'=>'app-test','store'=>'APP_STORE'];
    subscriptionTest(!empty(processRevenueCatEvent($db,$config,$transfer)['ignored']),'Ignored transfer preserves existing decision');
    subscriptionTest(subscriptionOpsUnlinkedEvents($db)['total']===1,'Ignored transfer is visible in unlinked evidence queue');
    subscriptionTest($db->query("SELECT environment FROM revenuecat_event_facts WHERE event_id='subops-test-transfer-ignored'")->fetchColumn()==='SANDBOX','Ignored transfer keeps actual environment');
    $refund=$cancel;$refund['id']='subops-test-revoke';$refund['cancel_reason']='CUSTOMER_SUPPORT';$refund['event_timestamp_ms']+=3;
    processRevenueCatEvent($db,$config,$refund);
    $member=subscriptionOpsDetail($db,981001);
    subscriptionTest($member['actual']['status']==='revoked'&&!$member['check']['actual_active'],'Support revocation has unchanged existing outcome');
    subscriptionTest(subscriptionOpsList($db,['status'=>'revoked'])['total']===1,'Revoked subscription is searchable');
    $stale=$event;$stale['id']='subops-test-stale';$stale['event_timestamp_ms']--;
    processRevenueCatEvent($db,$config,$stale);
    subscriptionTest($db->query("SELECT processing_result FROM revenuecat_event_facts WHERE event_id='subops-test-stale'")->fetchColumn()==='stale','Old events retain evidence but cannot revive access');
    $db->exec("INSERT INTO revenuecat_events(event_id,event_type,user_id,app_user_id,product_id,payload_hash,received_at) VALUES('subops-test-legacy','CANCELLATION',981001,'boji-981001','annual',REPEAT('0',64),UTC_TIMESTAMP())");
    subscriptionOpsMigrate($db);
    subscriptionTest(!$db->query("SELECT 1 FROM revenuecat_event_facts WHERE event_id='subops-test-legacy'")->fetchColumn(),'Migration never guesses historical facts');
    subscriptionTest(subscriptionOpsList($db,['environment'=>'unknown'])['total']===1,'Legacy environment is explicitly searchable as unknown');
    $db->prepare("UPDATE membership_entitlements SET status='active',expires_at=? WHERE user_id=981001")->execute([gmdate('Y-m-d H:i:s',$liveNow+86400)]);
    subscriptionTest(!subscriptionOpsDetail($db,981001)['check']['consistent'],'Real DB access inconsistent with revoked order is detected');
    $snapshot=['active'=>true,'product_id'=>'annual','starts_at'=>gmdate('Y-m-d H:i:s',$liveNow),'expires_at'=>gmdate('Y-m-d H:i:s',$liveNow+172800),'purchase_id'=>'injected-test-purchase'];
    revenueCatVerifyMembership($db,['id'=>981001],$config,true,static fn()=>$snapshot);
    $member=subscriptionOpsDetail($db,981001);
    subscriptionTest($member['snapshot_facts']['source']==='injected_provider'&&$member['snapshot_facts']['environment_scope']==='PRODUCTION','Injected provider is never mislabeled official API verification');
    subscriptionTest($member['check']['consistent'],'Local comparison follows newer verified snapshot without changing entitlement selection');
    $prior=$member['snapshot_facts'];
    $db->exec('UPDATE revenuecat_member_checks SET verified_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE) WHERE user_id=981001');
    try { revenueCatVerifyMembership($db,['id'=>981001],$config,true,static function(){throw new RevenueCatVerificationError('rc_transport');}); }
    catch(RevenueCatVerificationError){}
    subscriptionTest(subscriptionOpsDetail($db,981001)['snapshot_facts']===$prior,'Failed verification cannot manufacture new provenance');
    $insertEntitlement=$db->prepare("INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,created_at,updated_at) VALUES(?,'active','admin','gift',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),UTC_TIMESTAMP(),UTC_TIMESTAMP())");
    foreach(array_slice($ids,1) as $id)$insertEntitlement->execute([$id]);
    $first=subscriptionOpsList($db,['q'=>'','page'=>1]);$second=subscriptionOpsList($db,['q'=>'','page'=>2]);
    subscriptionTest($first['total']===27&&count($first['rows'])===25&&count($second['rows'])===2,'Real SQL pagination returns bounded distinct pages');
    subscriptionTest(!array_intersect(array_column($first['rows'],'id'),array_column($second['rows'],'id')),'Pagination does not repeat members');
    subscriptionTest(subscriptionOpsList($db,['q'=>'NO. 991001'])['total']===1,'Formatted member number resolves exact account');
    subscriptionTest(subscriptionOpsList($db,['q'=>"' OR 1=1 --"])['total']===0,'SQL injection input matches no fixture');
    $before=(int)$db->query('SELECT COUNT(*) FROM membership_adjustments')->fetchColumn();
    subscriptionOpsDetail($db,981001);subscriptionOpsList($db,[]);
    subscriptionTest((int)$db->query('SELECT COUNT(*) FROM membership_adjustments')->fetchColumn()===$before,'Read-only operations create no membership adjustments');
    $db->exec("UPDATE revenuecat_events SET product_id='<img src=x onerror=1>' WHERE event_id='subops-test-legacy'");
    $_GET=['p'=>'subscriptions','user_id'=>'981001'];
    set_error_handler(static function(int $severity,string $message,string $file,int $line): never { throw new ErrorException($message,0,$severity,$file,$line); });
    try { ob_start(); require dirname(__DIR__).'/account-server/admin/subscriptions-view.php'; $html=ob_get_clean(); }
    finally { restore_error_handler(); }
    subscriptionTest(str_contains($html,'&lt;img src=x onerror=1&gt;')&&!str_contains($html,'<img src=x onerror=1>'),'View escapes event supplied content');
    subscriptionTest(str_contains($html,'待关联回调')&&str_contains($html,'回调原始字段，非收入/退款确认'),'Rendered view exposes provenance limits and unlinked queue');
    $admin=['role'=>'support'];
    ob_start();require dirname(__DIR__).'/account-server/admin/subscriptions-view.php';$denied=ob_get_clean();
    subscriptionTest(!str_contains($denied,'subops-original')&&str_contains($denied,'需要成员敏感信息权限'),'Unauthorized render does not leak transaction details');
    echo json_encode(['passed'=>$subscriptionAssertions,'database'=>'boji_subscription_ops_test','external_requests'=>0],JSON_THROW_ON_ERROR)."\n";
} finally {
    if($db->inTransaction())$db->rollBack();
    $db->prepare('DELETE FROM users WHERE id IN ('.$marks.')')->execute($ids);
    $db->exec("DELETE FROM revenuecat_events WHERE event_id LIKE 'subops-test-%'");
}
