<?php
declare(strict_types=1);

// Pure policy fixtures. No production or test database is touched.
function onboardingConfig(PDO $db): array { return ['enabled'=>true]; }
function onboardingAssistReserve(PDO $db, int $userID, string $id): array {
    $db->reservations++;
    if ($db->reservations > $db->limit) throw new RuntimeException('quota', 429);
    return ['session'=>['id'=>$id]];
}
final class NaturalPDO135 extends PDO {
    public bool $member=false; public bool $session=true; public bool $completed=false;
    public int $reservations=0; public int $limit=2;
    public function __construct() {}
    public function prepare(string $sql, array $options=[]): PDOStatement|false { return new NaturalStatement135($this,$sql); }
}
final class NaturalStatement135 extends PDOStatement {
    public function __construct(private NaturalPDO135 $db, private string $sql) {}
    public function execute(?array $params=null): bool { return true; }
    public function fetchColumn(int $column=0): mixed {
        if (str_contains($this->sql,'membership_entitlements')) return $this->db->member ? 1 : false;
        if (str_contains($this->sql,'LEFT JOIN onboarding')) return $this->db->session && !$this->db->completed ? 'synthetic-session' : false;
        if (str_contains($this->sql,'user_onboarding_heads')) return $this->db->session ? 1 : false;
        return false;
    }
}
require __DIR__.'/../account-server/public/ai-entitlements.php';
require __DIR__.'/../account-server/public/ai-memory.php';
function check135(bool $condition,string $message):void { if (!$condition) throw new RuntimeException($message); }
$db=new NaturalPDO135();$config=['membership_enforcement'=>true];$user=['id'=>42];
check135(aiMayPostJob($db,$user,$config,'coach',null,'dialogue'),'new user may chat with active onboarding');
aiReserveNaturalOnboarding($db,42,$config,'dialogue');aiReserveNaturalOnboarding($db,42,$config,'dialogue');
try { aiReserveNaturalOnboarding($db,42,$config,'dialogue');throw new RuntimeException('quota missing'); }
catch (RuntimeException $e) { check135($e->getCode()===429,'daily allowance enforced'); }
$db->reservations=0;$db->member=true;aiReserveNaturalOnboarding($db,42,$config,'dialogue');
check135($db->reservations===0,'members do not consume welcome allowance');
$db->member=false;$db->completed=true;
check135(!aiMayPostJob($db,$user,$config,'coach',null,'dialogue'),'completed nonmember does not get onboarding allowance');
$db->completed=false;$db->session=false;
check135(!aiMayPostJob($db,$user,$config,'coach',null,'dialogue'),'no active onboarding does not receive allowance');
$doc=['revision'=>4,'facts'=>['goal'=>['value'=>'减脂'],'days_per_week'=>['value'=>3]]];
$goal=['origin'=>'extracted','content'=>'当前目标：增肌','evidence_json'=>'["profile/goal"]'];
check135(aiMemoryReconcileProfileRow135($goal,$doc)['content']==='当前目标：减脂','latest confirmed goal wins');
$goal['evidence_json']='["profile/limitations"]';
check135(aiMemoryReconcileProfileRow135($goal,$doc)===null,'cleared facts do not return from stale memory');
$goal['origin']='user';check135(aiMemoryReconcileProfileRow135($goal,$doc)['content']==='当前目标：增肌','explicit user memories are preserved');
$legacy=['revision'=>0,'facts'=>[]];$goal['origin']='extracted';
check135(aiMemoryReconcileProfileRow135($goal,$legacy)['content']==='当前目标：增肌','legacy rows retain their existing behavior');
echo "BUILD135_POLICY_MEMORY_PASS 9\n";
