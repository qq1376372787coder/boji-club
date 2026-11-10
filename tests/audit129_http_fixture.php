<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require __DIR__.'/php_test_bootstrap.php';$db=bojiTestDatabase('boji_audit129_test');
if($db->query('SELECT DATABASE()')->fetchColumn()!=='boji_audit129_test')throw new RuntimeException('isolation guard');
$root=dirname(__DIR__);$cfg=['dsn'=>getenv('BOJI_TEST_DSN_BASE').';dbname=boji_audit129_test;charset=utf8mb4','db_user'=>'root','db_password'=>'',
    'otp_secret'=>str_repeat('fixture-',6),'ai_proxy_token'=>str_repeat('fixture-',6),'ai_proxy_base_url'=>'http://127.0.0.1:18130'];
if(file_exists($root.'/account-server/config.php'))throw new RuntimeException('refuse overwriting config');
file_put_contents($root.'/account-server/config.php',"<?php return ".var_export($cfg,true).";\n");chmod($root.'/account-server/config.php',0600);
foreach(['super_admin','operator','support','readonly','content'] as $role)$db->prepare("INSERT INTO admin_accounts(username,password_hash,role,status,created_at) VALUES(?,?,?,'active',UTC_TIMESTAMP())")->execute(['fixture-'.$role,password_hash('fixture-password129',PASSWORD_DEFAULT),$role]);
$db->exec(file_get_contents($root.'/account-server/migrations/20261026-member-feedback128.sql'));
@mkdir($root.'/account-server/media/101',0700,true);@mkdir($root.'/account-server/admin-media',0700,true);
$media='12900000-0000-4000-8000-000000000070.jpg';$im=imagecreatetruecolor(20,20);imagejpeg($im,$root.'/account-server/media/101/'.$media);imagedestroy($im);
copy($root.'/account-server/media/101/'.$media,$root.'/account-server/admin-media/fixture129.jpg');
$db->prepare("INSERT INTO user_media(user_id,media_id,byte_size,content_type,created_at,updated_at) VALUES(101,?,?,'image/jpeg',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$media,filesize($root.'/account-server/media/101/'.$media)]);
$db->exec("INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,created_at,updated_at) VALUES(129,'audit129','Fixture','','','2020-01-01','2020-01-31','2020-01-01',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
$db->exec("INSERT INTO club_tasks(id,season_id,title,metric,target,created_at) VALUES(129,129,'Fixture','training_days',1,UTC_TIMESTAMP())");
$db->exec("INSERT INTO club_rewards(id,season_id,task_id,title,reward_type,image_path,created_at) VALUES(129,129,129,'Fixture','badge','fixture129.jpg',UTC_TIMESTAMP())");
foreach([129=>'badge',130=>'physical'] as $id=>$kind)$db->prepare("INSERT INTO club_reward_catalog(id,kind,name,image_path,created_at,updated_at) VALUES(?,?,'Fixture','fixture129.jpg',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$id,$kind]);
echo "HTTP_FIXTURE_READY\n";
