<?php
declare(strict_types=1);
/** FIX-008 terminal failed rows are not due until reset. */
require __DIR__.'/../php_test_bootstrap.php';
$db = bojiTestDatabase(getenv('BOJI_TEST_DB') ?: 'bojiclub_automation_test');
$uid = 920000;
$db->exec("DELETE FROM club_automation WHERE user_id BETWEEN $uid AND ".($uid+4));
$db->exec("DELETE FROM users WHERE id BETWEEN $uid AND ".($uid+4));
for ($i=0;$i<4;$i++) $db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES(".($uid+$i).",'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$rows = [
  [$uid,   'failed: test', 6, 0],
  [$uid+1, 'retry_pending', 3, 0],
  [$uid+2, 'failed: test', 0, 0],
  [$uid+3, 'retry_pending', 3, 1],
];
$insert = $db->prepare("INSERT INTO club_automation(user_id,enabled,preferences_json,coverage_json,next_run,last_status,retry_count,updated_at,paused) VALUES(?,1,'{}','{}',DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 MINUTE),?,?,UTC_TIMESTAMP(),?)");
foreach ($rows as $row) $insert->execute($row);
$sql = "SELECT user_id FROM club_automation WHERE enabled=1 AND paused=0 AND next_run<=UTC_TIMESTAMP() AND (COALESCE(last_status,'') NOT LIKE 'failed%' OR retry_count < 6) ORDER BY next_run,user_id";
$due = array_map('intval', $db->query($sql)->fetchAll(PDO::FETCH_COLUMN));
$expected = [$uid+1, $uid+2];
if ($due !== $expected) throw new RuntimeException('terminal due selection mismatch: '.json_encode($due));
echo 'AUTOMATION_TERMINAL_OK due='.implode(',', $due)."\n";
$db->exec("DELETE FROM club_automation WHERE user_id BETWEEN $uid AND ".($uid+4));
$db->exec("DELETE FROM users WHERE id BETWEEN $uid AND ".($uid+4));
