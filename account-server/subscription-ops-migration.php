<?php
declare(strict_types=1);
function subscriptionOpsMigrate(PDO $db): void {
    $sql = file_get_contents(__DIR__.'/migrations/20261028-subscription-ops.sql');
    if ($sql === false) throw new RuntimeException('订阅来源迁移文件缺失。');
    $db->exec($sql);
    subscriptionOpsCheckSchema($db);
}
function subscriptionOpsCheckSchema(PDO $db): void {
    $db->query('SELECT event_id,source,environment,store_name,cancel_reason,evidence_json,processing_result,recorded_at FROM revenuecat_event_facts LIMIT 0');
    $db->query('SELECT user_id,observed_at_ms,source,environment_scope,project_id,verified_status,recorded_at FROM revenuecat_check_facts LIMIT 0');
}
