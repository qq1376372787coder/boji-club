<?php
declare(strict_types=1);

// Fixed, non-public runtime location. No PDO SQLite dependency or root file reads.
function operationsAlertsStatus(): array {
    $path = dirname(__DIR__).'/runtime/operations-alerts.json';
    if (!is_file($path) || !is_readable($path) || filesize($path) > 2097152) return [];
    $raw = @file_get_contents($path);
    $data = json_decode($raw ?: '', true, 32);
    return is_array($data) && ($data['schema_version'] ?? null) === 1 && is_array($data['events'] ?? null) ? $data : [];
}

function operationsAlertTime(mixed $value): string {
    if (!is_string($value) || $value === '') return '暂无记录';
    try { return (new DateTimeImmutable($value, new DateTimeZone('UTC')))->setTimezone(new DateTimeZone('Asia/Shanghai'))->format('Y-m-d H:i'); }
    catch (Throwable) { return '时间待核对'; }
}

function operationsAlertDelivery(array $event, string $mode): string {
    if ($mode !== 'external_enabled') return '仅在后台显示';
    $states = is_array($event['notifications'] ?? null) ? $event['notifications'] : [];
    if (!$states) return ($event['status'] ?? '') === 'recovered' ? '恢复已记入后台' : '待尝试外部通知';
    $labels = [];
    foreach (['webhook'=>'企业机器人', 'smtp'=>'邮件'] as $key=>$label) {
        if (!is_array($states[$key] ?? null)) continue;
        $state = $states[$key];
        $labels[] = $label.'：'.(($state['state'] ?? '') === 'accepted' ? '渠道已接收' : '发送失败，稍后重试');
    }
    return $labels ? implode('；', $labels) : '待尝试外部通知';
}
