<?php
declare(strict_types=1);
// Run only against an isolated repair-test database.
require __DIR__.'/../account-server/public/apple-auth.php';
require __DIR__.'/../account-server/public/revenuecat.php';
require __DIR__.'/php_test_bootstrap.php';
$testDatabase = getenv('BOJI_TEST_DB') ?: 'bojiclub_repair_v2_test';
if (!str_ends_with($testDatabase, '_test') && !str_ends_with($testDatabase, '_test_20261004')) throw new RuntimeException('Use an isolated *_test database.');
$db = bojiTestDatabase($testDatabase);
$checks = 0;
function check(bool $condition, string $label): void { global $checks; if (!$condition) throw new RuntimeException($label); $checks++; echo "PASS $label\n"; }
function b64(string $value): string { return rtrim(strtr(base64_encode($value),'+/','-_'),'='); }
$private = openssl_pkey_new(['private_key_bits'=>2048,'private_key_type'=>OPENSSL_KEYTYPE_RSA]);
$details = openssl_pkey_get_details($private);
$key = ['kty'=>'RSA','alg'=>'RS256','use'=>'sig','kid'=>'fixture','n'=>b64($details['rsa']['n']),'e'=>b64($details['rsa']['e'])];
$now = time(); $nonce = str_repeat('a',64);
$claims = ['iss'=>'https://appleid.apple.com','aud'=>'com.bojiclub.app.dev','iat'=>$now,'exp'=>$now+300,'nonce'=>$nonce,'sub'=>'test-subject'];
function signedToken(array $claims, string $alg='RS256'): string { global $private; $data=b64(json_encode(['alg'=>$alg,'kid'=>'fixture'])).'.'.b64(json_encode($claims)); openssl_sign($data,$sig,$private,OPENSSL_ALGO_SHA256); return $data.'.'.b64($sig); }
check(verifyAppleIdentity(signedToken($claims),$nonce,['com.bojiclub.app.dev'],[$key])==='test-subject','Apple RSA identity accepted');
foreach (['aud'=>'wrong-client','nonce'=>str_repeat('b',64),'exp'=>$now-1,'iat'=>$now+100,'iss'=>'https://example.invalid','sub'=>''] as $field=>$value) {
    $bad=$claims; $bad[$field]=$value; $rejected=false;
    try { verifyAppleIdentity(signedToken($bad),$nonce,['com.bojiclub.app.dev'],[$key]); } catch(Throwable) { $rejected=true; }
    check($rejected,'Apple rejects '.$field);
}
$bad=signedToken($claims,'ES256'); $rejected=false;
try { verifyAppleIdentity($bad,$nonce,['com.bojiclub.app.dev'],[$key]); } catch(Throwable) { $rejected=true; }
check($rejected,'Apple rejects algorithm substitution');
$bad=signedToken($claims); $parts=explode('.',$bad);$parts[1]=b64(json_encode($claims+['extra'=>'tampered']));$rejected=false;
try { verifyAppleIdentity(implode('.',$parts),$nonce,['com.bojiclub.app.dev'],[$key]); } catch(Throwable) { $rejected=true; }
check($rejected,'Apple rejects tampered signature');
$db->exec("DELETE FROM users WHERE id=900001; INSERT INTO users(id,status,created_at,updated_at) VALUES(900001,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$config=['revenuecat_environment'=>'PRODUCTION','revenuecat_app_id'=>'app_fixture'];
$time=(int)(microtime(true)*1000); $expiry=$time+86400000*365;
$event=['id'=>'fixture-initial','type'=>'INITIAL_PURCHASE','app_user_id'=>'boji-900001','app_id'=>'app_fixture','environment'=>'PRODUCTION','product_id'=>'bojiclub_halfyear_2990','original_transaction_id'=>'sub-fixture-a','transaction_id'=>'tx-fixture-a','purchased_at_ms'=>$time,'expiration_at_ms'=>$expiry,'event_timestamp_ms'=>$time];
$db->exec("DELETE FROM revenuecat_events WHERE event_id LIKE 'fixture-%'");
function member(): array { global $db;return $db->query('SELECT * FROM membership_entitlements WHERE user_id=900001')->fetch(); }
processRevenueCatEvent($db,$config,$event);check(member()['status']==='active' && member()['last_transaction_id']==='tx-fixture-a','Purchase grants access and stores transaction');
check(!empty(processRevenueCatEvent($db,$config,$event)['duplicate']),'Duplicate webhook is idempotent');
$renew=$event; $renew['id']='fixture-renewal';$renew['type']='RENEWAL';$renew['event_timestamp_ms']=$time+100;$renew['expiration_at_ms']=$expiry+86400000;$renew['transaction_id']='tx-fixture-renew'; processRevenueCatEvent($db,$config,$renew);
$old=$event;$old['id']='fixture-old-expiration';$old['type']='EXPIRATION';$old['event_timestamp_ms']=$time+50;check(!empty(processRevenueCatEvent($db,$config,$old)['stale']) && member()['status']==='active','Old expiration cannot revoke newer renewal');
$cancel=$renew;$cancel['id']='fixture-unsubscribe';$cancel['type']='CANCELLATION';$cancel['cancel_reason']='UNSUBSCRIBE';$cancel['event_timestamp_ms']=$time+200;processRevenueCatEvent($db,$config,$cancel);check(member()['status']==='active','Normal cancellation retains paid access');
$refund=$cancel;$refund['id']='fixture-refund';$refund['cancel_reason']='CUSTOMER_SUPPORT';processRevenueCatEvent($db,$config,$refund);check(member()['status']==='revoked','Customer support refund revokes access');
$other=$renew;$other['id']='fixture-other-sub';$other['original_transaction_id']='sub-fixture-b';$other['transaction_id']='tx-fixture-b';$other['product_id']='bojiclub_yearly_4290';processRevenueCatEvent($db,$config,$other);check(member()['status']==='active','Different active subscription survives refund');
$refund['id']='fixture-refund-again';$refund['event_timestamp_ms']=$time+300;processRevenueCatEvent($db,$config,$refund);check(member()['status']==='active','Old product refund does not revoke other active product');
$tie=$other;$tie['id']='fixture-same-time-refund';$tie['type']='CANCELLATION';$tie['cancel_reason']='CUSTOMER_SUPPORT';processRevenueCatEvent($db,$config,$tie);check(member()['status']==='revoked','Refund wins over purchase at equal timestamp');
$tie=$other;$tie['id']='fixture-same-time-reactivation';check(!empty(processRevenueCatEvent($db,$config,$tie)['stale']) && member()['status']==='revoked','Equal timestamp purchase cannot undo refund');
$other['id']='fixture-new-period';$other['event_timestamp_ms']=$time+350;processRevenueCatEvent($db,$config,$other);
$sandbox=$renew;$sandbox['id']='fixture-sandbox';$sandbox['environment']='SANDBOX';$sandbox['event_timestamp_ms']=$time+400;check(!empty(processRevenueCatEvent($db,$config,$sandbox)['ignored']),'Production ignores sandbox');
$wrong=$renew;$wrong['id']='fixture-other-app';$wrong['app_id']='wrong';check(!empty(processRevenueCatEvent($db,$config,$wrong)['ignored']),'Webhook ignores other app');
$db->exec("INSERT INTO membership_admin_grants(user_id,status,starts_at,expires_at,updated_at) VALUES(900001,'active',UTC_TIMESTAMP(),'2040-01-01',UTC_TIMESTAMP())");$other['id']='fixture-gift-protection';$other['event_timestamp_ms']=$time+500;processRevenueCatEvent($db,$config,$other);check(member()['source']==='admin','Later administrator grant is preserved');
$db->exec('DELETE FROM users WHERE id=900001');check((int)$db->query('SELECT COUNT(*) FROM revenuecat_subscriptions WHERE user_id=900001')->fetchColumn()===0,'Subscription data cascades on account deletion');
echo "ACCOUNT_REGRESSION_OK checks=$checks\n";
