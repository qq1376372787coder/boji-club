<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/media-quota.php';
$config=require $argv[1];
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
// This connection-local table shadows user_media. Every fixture write below
// targets the temporary table; production rows are neither selected nor changed.
$db->exec('CREATE TEMPORARY TABLE user_media(user_id BIGINT NOT NULL,media_id VARCHAR(40),byte_size BIGINT NOT NULL,updated_at DATETIME NOT NULL)');
$db->exec('CREATE TEMPORARY TABLE storage_settings(setting_key VARCHAR(60) NOT NULL PRIMARY KEY,setting_value BIGINT UNSIGNED NOT NULL)');
$db->exec('CREATE TEMPORARY TABLE media_upload_events(id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,user_id BIGINT NOT NULL,uploaded_at DATETIME NOT NULL)');
try {
    $db->exec("INSERT INTO storage_settings VALUES('media_file_limit',1),('media_uploads_per_minute',120),('media_storage_limit_bytes',0)");
    $db->exec("INSERT INTO user_media VALUES(1,'a.jpg',200,DATE_SUB(UTC_TIMESTAMP(),INTERVAL 2 MINUTE))");
    if(checkMediaQuota($db,1,'b.jpg',100,[] )['status']!==413)throw new RuntimeException('file-count query');
    if(checkMediaQuota($db,1,'a.jpg',100,[])!==null)throw new RuntimeException('replacement query');
    $db->exec("UPDATE storage_settings SET setting_value=0 WHERE setting_key='media_file_limit'");
    $db->exec("UPDATE storage_settings SET setting_value=10 WHERE setting_key='media_uploads_per_minute'");
    for($i=0;$i<11;$i++)$db->exec("INSERT INTO user_media VALUES(2,'t{$i}.jpg',100,UTC_TIMESTAMP())");
    for($i=0;$i<10;$i++)$db->exec("INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(2,UTC_TIMESTAMP())");
    if(checkMediaQuota($db,2,'new.jpg',100,[])['status']!==429)throw new RuntimeException('rate query');
    if(checkMediaQuota($db,3,'new.jpg',100,[])!==null)throw new RuntimeException('empty account aggregate');
    echo 'PASS 4 media quota SQL cases against a connection-local temporary table'.PHP_EOL;
} finally { $db->exec('DROP TEMPORARY TABLE user_media');$db->exec('DROP TEMPORARY TABLE storage_settings');$db->exec('DROP TEMPORARY TABLE media_upload_events'); }
