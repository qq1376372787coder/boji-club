<?php
declare(strict_types=1);
// Mirrors /me/ai/proposals dependency loading; commands.php is deliberately absent.
require __DIR__.'/php_test_bootstrap.php';
require __DIR__.'/../account-server/public/ai-proposals.php';
function fail(string $message,int $status=400):never{throw new RuntimeException($message,$status);}
$db=bojiTestDatabase('bojiclub_ai_conversations_test');
$db->exec("DELETE FROM users WHERE phone='13200000001'");
$db->exec("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13200000001','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())");$uid=(int)$db->lastInsertId();
try {
 $proposal=aiProposalCreate($db,$uid,'meal_draft',['date'=>'2026-10-24','meals'=>[['name'=>'鸡蛋','category'=>'早餐']]],[],null,null);
 if($proposal['status']!=='awaiting_confirmation')throw new RuntimeException('intake failed');
 if(function_exists('commandUUID'))throw new RuntimeException('test must not depend on command module');
 echo "Standalone proposal intake passed\n";
}finally{$db->prepare('DELETE FROM users WHERE id=?')->execute([$uid]);}
