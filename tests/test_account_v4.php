<?php
declare(strict_types=1);
$root=dirname(__DIR__);
require $root.'/tests/php_test_bootstrap.php';
$testDatabase=getenv('BOJI_TEST_DB')?:'bojiclub_repair_v4_test_20261002';
if(!str_ends_with($testDatabase,'_test_20261002')) throw new RuntimeException('Isolated v4 test DB required');
require $root.'/account-server/public/account-deletion.php';
$db=bojiTestDatabase($testDatabase);
$config=['dsn'=>'test','db_user'=>'test','db_password'=>'test','otp_secret'=>'test-only-otp-secret-0123456789abcdef'];
function checkV4(bool $ok,string $name): void {if(!$ok)throw new RuntimeException($name);echo 'PASS '.$name."\n";}
function fail(string $message,int $code=400): never {throw new RuntimeException('Unexpected rejection');}
$id=900065;$subject='v4-synthetic-apple-subject';$hash=hash('sha256','v4-deletion-token');
$db->exec('DELETE FROM account_deletions WHERE user_id=900065');$db->prepare('DELETE FROM account_deletions WHERE token_hash=?')->execute([$hash]);$db->exec('DELETE FROM users WHERE id=900065');
$db->prepare("INSERT INTO users(id,apple_subject,status,created_at,updated_at) VALUES(?,?,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$id,$subject]);
checkV4(recoveredAppleDeletionStatus($db,$config,$id,$subject)===['accepted'=>false],'Original active Apple account can clear stale local pending marker');
enqueueAccountDeletion($db,['id'=>$id,'token_hash'=>$hash],$config);
checkV4(recoveredAppleDeletionStatus($db,$config,$id,$subject)['accepted']===true,'Apple identity recovers queued deletion after session loss');
$db->prepare('UPDATE account_deletions SET created_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 31 DAY),updated_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 31 DAY) WHERE token_hash=?')->execute([$hash]);
checkV4(recoveredAppleDeletionStatus($db,$config,$id,$subject)['accepted']===true,'Long-running deletion retains recovery evidence until cleanup completes');
checkV4(recoveredAppleDeletionStatus($db,$config,$id,'another-subject')===null,'Another Apple identity cannot recover this deletion');
$db->exec("UPDATE account_deletions SET user_id=NULL,status='completed',updated_at=UTC_TIMESTAMP() WHERE user_id=900065");
checkV4(recoveredAppleDeletionStatus($db,$config,$id,$subject)['deleted']===true,'Completed deletion can be confirmed without recreating a user');
$db->prepare('UPDATE account_deletions SET updated_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 31 DAY) WHERE token_hash=?')->execute([$hash]);
checkV4(recoveredAppleDeletionStatus($db,$config,$id,$subject)===null,'Recovery evidence expires after 30 days');
echo "ACCOUNT_V4_OK checks=6\n";
