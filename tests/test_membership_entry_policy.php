<?php
declare(strict_types=1);
// Pure fixtures: no DSN, database connection, payment call or real account.
require __DIR__.'/../account-server/public/revenuecat.php';
require __DIR__.'/../account-server/public/ai-entitlements.php';
$checks=0;
function entryCheck(bool $condition, string $label): void {
    global $checks;
    if (!$condition) throw new RuntimeException($label);
    $checks++;
}
function fail(string $message, int $status=400, ?string $errorCode=null): never {
    $GLOBALS['entryErrorCode']=$errorCode;
    throw new RuntimeException($message,$status);
}
final class EntryPDO extends PDO {
    public array $activeUsers=[41=>true,42=>false,43=>false];
    public array $checked=[];
    public function __construct() {}
    public function prepare(string $sql, array $options=[]): PDOStatement|false { return new EntryStatement($this); }
}
final class EntryStatement extends PDOStatement {
    private int $owner=0;
    public function __construct(private EntryPDO $db) {}
    public function execute(?array $params=null): bool { $this->owner=(int)$params[0];$this->db->checked[]=$this->owner;return true; }
    public function fetchColumn(int $column=0): mixed { return ($this->db->activeUsers[$this->owner]??false)?1:false; }
}
$id='00f975d1-a20a-40ae-97c2-51dce60e5647';
$setup=[['GET','/me'],['DELETE','/me'],['GET','/me/deletion'],['GET','/me/export'],
 ['POST','/me/membership/verify'],['GET','/me/profile-facts'],['POST','/me/profile-facts/preview'],
 ['POST','/me/profile-facts/confirm'],['GET',"/me/profile-facts/proposals/$id"],
 ['GET','/me/onboarding/v2'],['POST','/me/onboarding/v2/sessions'],
 ['PATCH',"/me/onboarding/v2/sessions/$id/draft"],['POST',"/me/onboarding/v2/sessions/$id/complete"],
 ['POST','/me/ai/consent'],['PUT','/me/push-device'],['POST','/me/feedback'],['GET','/me/media/owned-image']];
foreach($setup as [$method,$path])entryCheck(!membershipRouteRequiresAccess($method,$path),'account route must remain available: '.$path);
$business=[['GET','/me/tasks'],['GET','/me/ai/tasks'],['GET','/me/state'],['PUT','/me/state'],
 ['GET','/me/sync'],['POST','/me/sync/read'],['PUT','/me/sync'],['POST','/me/commands'],
 ['GET','/club/current'],['GET','/club/collection'],['GET','/club/history'],
 ['POST',"/me/onboarding/v2/sessions/$id/plan-adopted"],['GET',"/me/ai/runs/$id/events"],
 ['GET',"/me/ai/jobs/$id"],['POST',"/me/ai/jobs/$id"],['POST',"/me/ai/conversations/conversation123/runs"],
 ['POST',"/me/ai/proposals/$id/confirm"],['GET','/me/ai/memory'],['POST','/me/automation'],
 ['POST',"/me/weekly/jobs/$id"],['POST','/me/future-business-route'],['PUT','/me/profile-facts']];
foreach($business as [$method,$path])entryCheck(membershipRouteRequiresAccess($method,$path),'business route must require membership: '.$path);
entryCheck(!membershipRouteRequiresAccess('POST','/webhooks/revenuecat'),'webhook stays independently authenticated');
entryCheck(!membershipRouteRequiresAccess('POST','/auth/apple/verify'),'login stays independently authenticated');
$db=new EntryPDO();
foreach([false,true] as $oldSwitch)foreach(['coach','generate_plan','parse_plan','food','report','weekly_review'] as $kind)foreach([null,'onboarding_assist','dialogue'] as $purpose) {
 entryCheck(!aiMayPostJob($db,['id'=>42],['membership_enforcement'=>$oldSwitch],$kind,['kind'=>$kind],$purpose),'unpaid purpose/kind cannot bypass');
 entryCheck(aiMayPostJob($db,['id'=>41],['membership_enforcement'=>$oldSwitch],$kind,null,$purpose),'verified member is allowed');
}
entryCheck(membershipEnforced(['membership_enforcement'=>false]),'old global switch is retired');
requireActiveMembership($db,['id'=>41],[]);
try { requireActiveMembership($db,['id'=>42],['membership_enforcement'=>false]);throw new RuntimeException('gate did not reject'); }
catch(RuntimeException $e) { entryCheck($e->getCode()===403,'HTTP gate rejects with 403');entryCheck(($GLOBALS['entryErrorCode']??null)==='membership_required','HTTP denial has machine-readable membership code'); }
entryCheck(!membershipHasActiveEntitlement($db,43),'another inactive account cannot inherit entitlement');
require __DIR__.'/../account-server/public/action-jobs.php';
try { actionQueuePlan($db,['id'=>42],[],'synthetic-action');throw new RuntimeException('plan action bypass'); }
catch(RuntimeException $e) { entryCheck($e->getCode()===403,'direct plan action requires membership even outside HTTP routing'); }
echo "MEMBERSHIP_ENTRY_POLICY_PASS $checks\n";
