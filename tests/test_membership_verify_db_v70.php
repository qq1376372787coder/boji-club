<?php
declare(strict_types=1);
require dirname(__DIR__).'/account-server/public/revenuecat.php';
require __DIR__.'/php_test_bootstrap.php';
function lockActiveUser(PDO $db,int $id): void {
    $q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$id]);
    if($q->fetchColumn()!=='active')throw new RuntimeException('user_unavailable');
}
function verifyDB70(bool $ok,string $label): void {global $count;if(!$ok)throw new RuntimeException($label);$count++;}
$dsn=getenv('BOJI_V70_TEST_DSN');
if(!$dsn || !str_contains($dsn,'dbname=boji_membership_v70_test')) throw new RuntimeException('An isolated test database is required');
$db=new PDO($dsn,getenv('BOJI_V70_TEST_USER')?:'root',getenv('BOJI_V70_TEST_PASSWORD')?:'',[
    PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
bojiTestSchema($db, dirname(__DIR__).'/account-server');
$uid=970001;$count=0;$config=require dirname(__DIR__).'/account-server/revenuecat-config.example.php';
$user=['id'=>$uid];$calls=0;
$active=['active'=>true,'product_id'=>'yongjiu','starts_at'=>gmdate('Y-m-d H:i:s'),'expires_at'=>'9999-12-31 23:59:59','purchase_id'=>'purch-test'];
$inactive=['active'=>false,'product_id'=>'','starts_at'=>null,'expires_at'=>null,'purchase_id'=>null];
$fetch=static function()use(&$calls,$active){$calls++;return $active;};
$member=static function()use($db,$uid){$q=$db->prepare('SELECT * FROM membership_entitlements WHERE user_id=?');$q->execute([$uid]);return $q->fetch();};
$db->exec("DELETE FROM users WHERE id IN(970001,970002);INSERT INTO users(id,status,created_at,updated_at) VALUES(970001,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(970002,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
try {
    verifyDB70(revenueCatVerifyMembership($db,$user,$config,true,$fetch)==='verified','Initial verification completes');
    verifyDB70($member()['status']==='active'&&$member()['plan_code']==='yongjiu','Server opens verified lifetime membership');
    revenueCatVerifyMembership($db,$user,$config,true,$fetch);
    verifyDB70($calls===1,'Duplicate verification uses recent result');
    $db->exec('UPDATE revenuecat_member_checks SET verified_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)');
    try{revenueCatVerifyMembership($db,$user,$config,true,static function(){throw new RevenueCatVerificationError('rc_transport');});}catch(RevenueCatVerificationError){}
    verifyDB70($member()['status']==='active','Transport failure preserves already verified membership');
    verifyDB70($db->query('SELECT verified_status FROM revenuecat_member_checks')->fetchColumn()==='active','Failure never overwrites the successful snapshot');
    verifyDB70(revenueCatVerifyMembership($db,$user,$config,true,$fetch)==='pending','Upstream retry cooldown does not create concurrent calls');
    $db->exec('UPDATE revenuecat_member_checks SET next_attempt_at=NULL');
    revenueCatVerifyMembership($db,$user,$config,true,static fn()=>$inactive);
    verifyDB70($member()['status']==='expired','Complete inactive snapshot revokes lifetime access');
    $db->exec("UPDATE revenuecat_member_checks SET verified_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE);INSERT INTO membership_admin_grants(user_id,status,starts_at,expires_at,updated_at) VALUES(970001,'active',UTC_TIMESTAMP(),'2040-01-01',UTC_TIMESTAMP())");
    revenueCatVerifyMembership($db,$user,$config,true,static fn()=>$inactive);
    verifyDB70($member()['source']==='admin'&&$member()['status']==='active','Operator grant is preserved separately');
    $db->exec('DELETE FROM membership_admin_grants; UPDATE revenuecat_member_checks SET verified_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)');
    $eventTime=(int)floor(microtime(true)*1000)+1000;
    revenueCatVerifyMembership($db,$user,$config,true,static function()use($db,$uid,$eventTime,$inactive){
        $db->prepare("INSERT INTO revenuecat_subscriptions(original_transaction_id,user_id,product_id,status,starts_at,expires_at,event_timestamp_ms,last_transaction_id) VALUES('race-webhook',?,'nianfu','active',UTC_TIMESTAMP(),'2039-01-01',?,'race-webhook')")->execute([$uid,$eventTime]);
        return $inactive;
    });
    verifyDB70($member()['status']==='active'&&$member()['plan_code']==='nianfu','Newer concurrent webhook wins over older REST observation');
    $db->exec("DELETE FROM revenuecat_subscriptions;UPDATE revenuecat_member_checks SET verified_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)");
    revenueCatVerifyMembership($db,$user,$config,true,$fetch);
    $db->beginTransaction();lockActiveUser($db,$uid);revenueCatInvalidateSnapshot($db,$uid,(int)floor(microtime(true)*1000));recomputeMembership($db,$uid);$db->commit();
    verifyDB70($member()['status']==='expired','Verified transfer invalidates source snapshot');
    $db->exec("UPDATE revenuecat_member_checks SET attempt_token='other-check',attempt_started_at=UTC_TIMESTAMP()");
    verifyDB70(revenueCatVerifyMembership($db,$user,$config,true,$fetch)==='pending','Concurrent check is coalesced');
    $transferTime=(int)floor(microtime(true)*1000);
    $db->prepare("INSERT INTO revenuecat_member_checks(user_id,observed_at_ms,verified_at,verified_status,product_id,starts_at,expires_at,purchase_id) VALUES(970002,?,UTC_TIMESTAMP(),'active','yongjiu',UTC_TIMESTAMP(),'9999-12-31 23:59:59','purch-transfer')")->execute([$transferTime+100]);
    $transferConfig=$config;unset($transferConfig['revenuecat_api_v2_key_file']);
    $transfer=['id'=>'v70-snapshot-transfer','type'=>'TRANSFER','app_id'=>$config['revenuecat_app_id'],'environment'=>'SANDBOX','store'=>'APP_STORE',
        'transferred_from'=>['boji-970001'],'transferred_to'=>['boji-970002'],'event_timestamp_ms'=>$transferTime];
    verifyDB70(!empty(processRevenueCatTransfer($db,$transferConfig,$transfer)['transferred']),'Snapshot-only restore accepts a newer authoritative destination snapshot');
    verifyDB70($member()['status']==='expired'&&$db->query('SELECT status FROM membership_entitlements WHERE user_id=970002')->fetchColumn()==='active','Snapshot-only transfer gives access only to the new owner');
    $db->exec('DELETE FROM users WHERE id=970001');
    verifyDB70(!(int)$db->query('SELECT COUNT(*) FROM revenuecat_member_checks WHERE user_id=970001')->fetchColumn(),'Account deletion removes verification state');
    echo json_encode(['passed'=>$count],JSON_THROW_ON_ERROR)."\n";
} finally {
    if($db->inTransaction())$db->rollBack();
    $db->exec('DELETE FROM users WHERE id IN(970001,970002)');
    $db->exec("DELETE FROM revenuecat_events WHERE event_id='v70-snapshot-transfer'");
}
