<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/revenuecat.php';
require __DIR__.'/../account-server/admin/statistics.php';
require __DIR__.'/php_test_bootstrap.php';
$db=bojiTestDatabase(getenv('BOJI_TEST_DB') ?: 'bojiclub_repair_v17_test_20261004');
function verify17(bool $ok, string $label): void { if (!$ok) throw new RuntimeException($label); echo "PASS $label\n"; }
$db->exec("DELETE FROM users WHERE id IN(917001,917002); INSERT INTO users(id,status,created_at,updated_at) VALUES(917001,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),(917002,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$now = (int)(microtime(true)*1000);
$purchase=['id'=>'v17-fixture-purchase','type'=>'INITIAL_PURCHASE','app_user_id'=>'boji-917001','app_id'=>'app_fixture','environment'=>'PRODUCTION','product_id'=>'bojiclub_yearly_4290','original_transaction_id'=>'v17-fixture-tx','transaction_id'=>'v17-fixture-tx','purchased_at_ms'=>$now,'expiration_at_ms'=>$now+86400000,'event_timestamp_ms'=>$now];
$config=['revenuecat_app_id'=>'app_fixture','revenuecat_environment'=>'PRODUCTION'];
processRevenueCatEvent($db,$config,$purchase);
$transfer=['id'=>'v17-fixture-transfer','type'=>'TRANSFER','app_id'=>'app_fixture','transferred_from'=>['boji-917001'],'transferred_to'=>['boji-917002'],'event_timestamp_ms'=>$now+1];
verify17(!empty(processRevenueCatEvent($db,$config,$transfer)['transferred']),'Transfer without optional environment is accepted');
verify17((int)$db->query("SELECT user_id FROM revenuecat_subscriptions WHERE original_transaction_id='v17-fixture-tx'")->fetchColumn()===917002,'Verified purchase changes owner');
verify17($db->query('SELECT status FROM membership_entitlements WHERE user_id=917001')->fetchColumn()==='expired','Old owner loses paid access');
verify17(!empty(processRevenueCatEvent($db,$config,$transfer)['duplicate']),'Duplicate transfer remains idempotent');
$transfer['id']='v17-fixture-sandbox';$transfer['environment']='SANDBOX';$transfer['transferred_from']=['boji-917002'];$transfer['transferred_to']=['boji-917001'];
verify17(!empty(processRevenueCatEvent($db,$config,$transfer)['ignored']),'Explicit sandbox cannot move production purchase');
$transfer['id']='v17-fixture-other-app';unset($transfer['environment']);$transfer['app_id']='other_app';
verify17(!empty(processRevenueCatEvent($db,$config,$transfer)['ignored']),'Other application cannot move purchase');
$before=overviewActivity($db,['2026-10-02','2026-10-03']);
$days=['2026-10-02'=>['meals'=>[[],[]],'exercises'=>[['sets'=>[['completed'=>true],['completed'=>false]]],['sets'=>[['completed'=>true]]]]],'2026-01-01'=>['meals'=>array_fill(0,200,[]),'exercises'=>[['sets'=>[['completed'=>true]]]]]];
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([917001,json_encode(['days'=>$days],JSON_THROW_ON_ERROR)]);
$stats=overviewActivity($db,['2026-10-02','2026-10-03']);
verify17($stats['sets']===$before['sets']+2 && $stats['meals']===$before['meals']+2 && $stats['active']===$before['active']+1 && $stats['activity']['2026-10-02']===$before['activity']['2026-10-02']+1,'Seven-day projection preserves counts and excludes older history');
$db->exec('DELETE FROM users WHERE id=917002');
$restore=['id'=>'v17-fixture-deleted-restore','type'=>'TRANSFER','app_id'=>'app_fixture','transferred_from'=>['boji-917002'],'transferred_to'=>['boji-917001'],'event_timestamp_ms'=>$now+2];
$blocked=false;try { processRevenueCatEvent($db,$config,$restore); } catch(RuntimeException) { $blocked=true; }
verify17($blocked,'Deleted purchase source is reported for reconciliation instead of silently acknowledged');
verify17(!(int)$db->query("SELECT COUNT(*) FROM revenuecat_events WHERE event_id='v17-fixture-deleted-restore'")->fetchColumn(),'Unresolved restore retains webhook retry');
$db->exec("DELETE FROM users WHERE id IN(917001,917002); DELETE FROM revenuecat_events WHERE event_id LIKE 'v17-fixture-%'");
echo "V17_PHP_REGRESSION_PASS\n";
