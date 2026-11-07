<?php
declare(strict_types=1);

// Isolated policy test; no database or AI service is needed.

final class PreviewPDO extends PDO {
    public bool $member = false;
    public bool $hasProfile = true;
    public ?string $completedAt = null;
    public int $planJobs = 0;
    public function __construct() {}
    public function prepare(string $query, array $options = []): PDOStatement|false {
        return new PreviewStatement($this, $query);
    }
}

final class PreviewStatement extends PDOStatement {
    public function __construct(private PreviewPDO $db, private string $query) {}
    public function execute(?array $params = null): bool { return true; }
    public function fetch(int $mode = PDO::FETCH_DEFAULT, int $cursorOrientation = PDO::FETCH_ORI_NEXT, int $cursorOffset = 0): mixed {
        return $this->db->hasProfile ? ['completed_at' => $this->db->completedAt] : false;
    }
    public function fetchColumn(int $column = 0): mixed {
        if (str_contains($this->query, 'membership_entitlements')) return $this->db->member ? 1 : false;
        return $this->db->planJobs;
    }
}

$method = 'GET';
$path = '/policy-test';
require dirname(__DIR__) . '/account-server/public/weekly.php';

function expectPolicy(bool $actual, bool $expected, string $label): void {
    if ($actual !== $expected) throw new RuntimeException($label);
}

$db = new PreviewPDO();
$user = ['id' => 42];
$config = ['membership_enforcement' => true];
$oldPlan = ['kind' => 'generate_plan', 'created_at' => '2026-10-14 10:00:00'];

foreach (['generate_plan','parse_plan','food','report','coach','weekly_review'] as $kind) {
    foreach ([null, $oldPlan] as $existing) {
        expectPolicy(aiMayPostJob($db, $user, $config, $kind, $existing), false, 'unpaid job denied: '.$kind);
    }
}
$db->completedAt = '2026-10-14 11:00:00';
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', $oldPlan), false, 'legacy job retry does not bypass membership');
expectPolicy(aiMayPostJob($db, $user, ['membership_enforcement'=>false], 'report', null), false, 'retired enforcement flag does not bypass membership');
$db->member = true;
expectPolicy(aiMayPostJob($db, $user, $config, 'food', null), true, 'paid member allowed');
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', $oldPlan), true, 'paid member can recover an existing job');
echo "strict onboarding plan policy passed\n";
