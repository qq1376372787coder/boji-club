<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli') exit(1);
require __DIR__.'/public/account-deletion.php';
$config=require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
$lock=fopen(sys_get_temp_dir().'/bojiclub-account-deletions.lock','c');
if(!$lock || !flock($lock,LOCK_EX|LOCK_NB)) exit(0);
$q=$db->query("SELECT * FROM account_deletions WHERE status IN ('queued','retrying') AND next_attempt<=UTC_TIMESTAMP() ORDER BY next_attempt,created_at LIMIT 20");
foreach($q->fetchAll() as $row) processAccountDeletion($db,$config,$row);
$db->exec("DELETE FROM account_deletions WHERE status='completed' AND updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY)");
$db->exec("DELETE FROM cloud_uploads WHERE updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY)");
// Keep the durable upload receipt long enough for crash recovery; a 1h window
// could delete the only proof of an already-committed media version.
$db->exec("DELETE FROM media_upload_events WHERE uploaded_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 7 DAY) LIMIT 1000");
require_once __DIR__.'/public/apple-tokens.php';
appleRefreshStoredTokens($db,$config);
require_once __DIR__.'/public/media-cleanup.php';
processMediaCleanup($db);
flock($lock,LOCK_UN);
