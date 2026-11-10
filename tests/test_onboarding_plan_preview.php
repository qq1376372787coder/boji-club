<?php
declare(strict_types=1);

// Isolated policy test; no database or AI service is needed.
function membershipEnforced(array $config): bool { return $config['membership_enforcement'] ?? true; }

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

expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', null), true, 'initial plan');
expectPolicy(aiMayPostJob($db, $user, $config, 'parse_plan', null), true, 'initial import');
expectPolicy(aiMayPostJob($db, $user, $config, 'food', null), false, 'food remains paid');
expectPolicy(aiMayPostJob($db, $user, $config, 'report', null), false, 'report remains paid');
expectPolicy(aiMayPostJob($db, $user, $config, 'coach', null), false, 'coach remains paid; no onboarding bypass');
$db->planJobs = 5;
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', null), false, 'five new previews maximum');
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', $oldPlan), true, 'retry does not consume preview');
$db->completedAt = '2026-10-14 11:00:00';
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', null), false, 'new preview ends with onboarding');
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', $oldPlan), true, 'existing onboarding job survives completion');
expectPolicy(aiMayPostJob($db, $user, $config, 'parse_plan', $oldPlan), false, 'job kind cannot change');
expectPolicy(aiMayPostJob($db, $user, $config, 'food', $oldPlan), false, 'existing job cannot become free food task');
$db->hasProfile = false;
expectPolicy(aiMayPostJob($db, $user, $config, 'generate_plan', $oldPlan), false, 'profile is required');
$db->member = true;
expectPolicy(aiMayPostJob($db, $user, $config, 'food', null), true, 'paid member unrestricted');
$db->member = false;
expectPolicy(aiMayPostJob($db, $user, ['membership_enforcement' => false], 'report', null), true, 'disabled enforcement');

echo "onboarding plan preview policy passed\n";
