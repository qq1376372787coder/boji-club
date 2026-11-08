<?php
declare(strict_types=1);

// Pure policy, shared by the webhook and regression tests.
// $knownOriginal：该 original_transaction_id 是否已存在于 revenuecat_subscriptions。
// 旧档商品（已下架，见 revenueCatLegacyProductIDs）只为已经买过的订阅续订/过期，
// 任何未知的新交易一律拒绝——发放白名单只有当前三档一套。
function revenueCatDecision(array $event, array $config, bool $knownOriginal = false): ?array {
    $productID = $event['product_id'] ?? '';
    $isCurrent = in_array($productID, revenueCatProductIDs($config), true);
    $isLegacy = !$isCurrent && in_array($productID, revenueCatLegacyProductIDs($config), true);
    if (!$isCurrent && !$isLegacy) return null;
    if (($event['environment'] ?? '') !== ($config['revenuecat_environment'] ?? 'PRODUCTION')) return null;
    if (!empty($config['revenuecat_app_id']) && ($event['app_id'] ?? '') !== $config['revenuecat_app_id']) return null;
    if (!empty($config['revenuecat_store']) && ($event['store'] ?? '') !== $config['revenuecat_store']) return null;
    $type = $event['type'] ?? '';
    $time = $event['event_timestamp_ms'] ?? null;
    $original = $event['original_transaction_id'] ?? null;
    if (!is_numeric($time) || (int)$time < 946684800000 || !is_string($original) || $original === '' || strlen($original) > 255) return null;
    if ($isLegacy && !$knownOriginal) return null;
    $expires = revenueCatDate($event['expiration_at_ms'] ?? null);
    // Only explicitly listed non-consumable lifetime products can have no expiry.
    // Existing DATETIME columns are NOT NULL; this sentinel is an internal value,
    // never a date to display to customers. Refunds still revoke the entitlement.
    // 'lifetime' 是旧档永久商品：只有通过上方 legacy 闸门（已存在的订阅）才可能走到这里。
    $lifetimeProducts = $config['revenuecat_lifetime_product_ids'] ?? ['yongjiu', 'lifetime'];
    $isLifetime = is_array($lifetimeProducts) && in_array($event['product_id'] ?? '', $lifetimeProducts, true);
    if ($isLifetime && array_key_exists('expiration_at_ms', $event) && $event['expiration_at_ms'] === null) {
        $expires = '9999-12-31 23:59:59';
    }
    $grace = revenueCatDate($event['grace_period_expiration_at_ms'] ?? null);
    if (in_array($type, ['BILLING_ISSUE','CANCELLATION'], true) && $grace !== null && ($expires === null || $grace > $expires)) $expires = $grace;
    if ($type === 'CANCELLATION' && ($event['cancel_reason'] ?? '') === 'CUSTOMER_SUPPORT') $status = 'revoked';
    elseif (($type === 'BILLING_ISSUE' || ($type === 'CANCELLATION' && ($event['cancel_reason'] ?? '') === 'BILLING_ERROR')) && $expires !== null) $status = 'active';
    elseif ($type === 'EXPIRATION') $status = 'expired';
    elseif (in_array($type, ['INITIAL_PURCHASE','RENEWAL','UNCANCELLATION','NON_RENEWING_PURCHASE','SUBSCRIPTION_EXTENDED','REFUND_REVERSED','TEMPORARY_ENTITLEMENT_GRANT'], true) && $expires !== null) $status = 'active';
    else return null; // Normal cancellation, billing issues and product changes do not alter paid access.
    // Granting must include the configured entitlement. Refund/expiration events
    // can omit mappings after a product has been removed: still honor revocation.
    // 未配置时回落到唯一的权益 ID（薄肌俱乐部_pro），让未配置的安装也 fail-closed；
    // 显式配置为空串仍表示关闭该检查，保持向后兼容。
    $entitlement = $config['revenuecat_entitlement_id'] ?? '薄肌俱乐部_pro';
    if ($status === 'active' && is_string($entitlement) && $entitlement !== '') {
        if (!is_array($event['entitlement_ids'] ?? null) || !in_array($entitlement, $event['entitlement_ids'], true)) return null;
    }
    return ['original' => $original, 'time' => (int)$time, 'status' => $status, 'expires' => $expires ?? gmdate('Y-m-d H:i:s')];
}
