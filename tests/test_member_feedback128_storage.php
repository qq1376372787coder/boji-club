<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/member-feedback.php';
require __DIR__.'/../account-server/public/account-deletion.php';
require __DIR__.'/php_test_bootstrap.php';
$base=new PDO(getenv('BOJI_TEST_DSN_BASE'),getenv('BOJI_TEST_DB_USER')?:'root',getenv('BOJI_TEST_DB_PASSWORD')?:'');
$base->exec('DROP DATABASE IF EXISTS boji_feedback128_test');$base->exec('CREATE DATABASE boji_feedback128_test');
$db=bojiTestDatabase('boji_feedback128_test');bojiTestSchema($db,__DIR__.'/../account-server');
$db->exec(file_get_contents(__DIR__.'/../account-server/migrations/20261026-member-feedback128.sql'));
$db->exec("INSERT INTO users(id,status,created_at,updated_at) VALUES(103,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");
// Uses the checkout-local media root so the real account-erasure function is tested.
if($db->query('SELECT DATABASE()')->fetchColumn()!=='boji_feedback128_test')throw new RuntimeException('isolated fixture database only');
function check128(bool $ok,string $label):void{if(!$ok)throw new RuntimeException($label);echo "PASS $label\n";}
$owner=103;$jpg=__DIR__.'/food-illustration-fixture.jpg';$one=fbUUID128();
fbUpload128($db,$owner,$one,'image/jpeg',hash_file('sha256',$jpg),$jpg);
fbQuery128($db,'UPDATE member_feedback_attachments SET created_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 2 DAY) WHERE id=?',[$one]);
$db->beginTransaction();fbLock128($db,$owner);fbPrune128($db,$owner);$db->commit();
check128(!fbQuery128($db,'SELECT 1 FROM member_feedback_attachments WHERE id=?',[$one])->fetchColumn(),'stale pending upload removed');check128(!is_file(fbRoot128($owner).'/'.$one.'.jpg'),'stale pending file removed');
$two=fbUUID128();fbUpload128($db,$owner,$two,'image/jpeg',hash_file('sha256',$jpg),$jpg);
$ticket=fbUUID128();$message=fbWrite128($db,$owner,$ticket,['new'=>true,'client_id'=>$ticket,'text'=>'隐私导出和注销合成用例','attachments'=>[$two]]);
$export=feedbackExport128($db,$owner);check128(count($export)===1,'export only fixture owner');check128(count($export[0]['messages'])===1,'export includes submitted text');check128(count($export[0]['messages'][0]['attachments'])===1,'export includes media metadata');check128(!str_contains(json_encode($export),'storage_name')&&!str_contains(json_encode($export),'request_hash'),'export omits internal paths and hashes');
$attachment=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=?',[$two])->fetch();$path=fbPath128($attachment);
fbQuery128($db,'DELETE FROM users WHERE id=?',[$owner]);
check128(!fbQuery128($db,'SELECT 1 FROM member_feedback_tickets WHERE id=?',[$ticket])->fetchColumn(),'account deletion cascades tickets');check128(!fbQuery128($db,'SELECT 1 FROM member_feedback_messages WHERE ticket_id=?',[$ticket])->fetchColumn(),'account deletion cascades messages');check128(!fbQuery128($db,'SELECT 1 FROM member_feedback_attachments WHERE id=?',[$two])->fetchColumn(),'account deletion cascades attachment rows');
deletionRemoveMedia($owner);check128(!is_file($path),'existing account erasure removes feedback media');
echo "10 CHECKS PASSED\n";
