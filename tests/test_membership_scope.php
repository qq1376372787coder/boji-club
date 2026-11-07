<?php
declare(strict_types=1);
require __DIR__ . '/php_test_bootstrap.php';
$db = bojiTestDatabase('bojiclub_it');
$db->exec("DELETE FROM membership_entitlements WHERE last_transaction_id='scope-test-tx'");
$db->exec("DELETE FROM users WHERE phone IN ('19900000001','19900000002')");
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('19900000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP()),('19900000002','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$ids = $db->query("SELECT id FROM users WHERE phone IN ('19900000001','19900000002') ORDER BY id")->fetchAll(PDO::FETCH_COLUMN);
if (count($ids) !== 2) { fwrite(STDERR, "FAIL: test users\n"); exit(1); }
$insert = $db->prepare("INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,last_transaction_id,created_at,updated_at) VALUES(?,'active','apple','annual',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 30 DAY),'scope-test-tx',UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status=VALUES(status),source=VALUES(source),plan_code=VALUES(plan_code),starts_at=VALUES(starts_at),expires_at=VALUES(expires_at),last_transaction_id=VALUES(last_transaction_id),updated_at=UTC_TIMESTAMP()");
$insert->execute([(int)$ids[0]]);
$insert->execute([(int)$ids[1]]);
$rows = $db->prepare("SELECT user_id FROM membership_entitlements WHERE last_transaction_id='scope-test-tx' ORDER BY user_id");
$rows->execute();
$owners = $rows->fetchAll(PDO::FETCH_COLUMN);
if (count($owners) !== 2 || (int)$owners[0] !== (int)$ids[0] || (int)$owners[1] !== (int)$ids[1]) {
    fwrite(STDERR, "FAIL: a transaction id overwrote another account's entitlement\n");
    exit(1);
}
$db->exec("DELETE FROM membership_entitlements WHERE last_transaction_id='scope-test-tx'");
$db->exec("DELETE FROM users WHERE phone IN ('19900000001','19900000002')");
echo "membership transaction scoping passed\n";
