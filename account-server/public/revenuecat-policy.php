<?php
declare(strict_types=1);

// Pure policy, shared by the webhook and regression tests.
function revenueCatDecision(array $event, array $config): ?array {
    $products = $config['revenuecat_product_ids'] ?? ['yuefu', 'nianfu', 'yongjiu', 'monthly', 'six_month', 'lifetime', 'bojiclub_halfyear_2990', 'bojiclub_yearly_4290'];
    if (is_string($products)) $products = [$products];
    if (!is_array($products) || !in_array($event['product_id'] ?? '', $products, true)) return null;
    if (($event['environment'] ?? '') !== ($config['revenuecat_environment'] ?? 'PRODUCTION')) return null;
    if (!empty($config['revenuecat_app_id']) && ($event['app_id'] ?? '') !== $config['revenuecat_app_id']) return null;
    if (!empty($config['revenuecat_store']) && ($event['store'] ?? '') !== $config['revenuecat_store']) return null;
    $type = $event['type'] ?? '';
    $time = $event['event_timestamp_ms'] ?? null;
    $original = $event['original_transaction_id'] ?? null;
    if (!is_numeric($time) || (int)$time < 946684800000 || !is_string($original) || $original === '' || strlen($original) > 255) return null;
    $expires = revenueCatDate($event['expiration_at_ms'] ?? null);
    // Only explicitly listed non-consumable lifetime products can have no expiry.
    // Existing DATETIME columns are NOT NULL; this sentinel is an internal value,
    // never a date to display to customers. Refunds still revoke the entitlement.
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
    $entitlement = $config['revenuecat_entitlement_id'] ?? '';
    if ($status === 'active' && is_string($entitlement) && $entitlement !== '') {
        if (!is_array($event['entitlement_ids'] ?? null) || !in_array($entitlement, $event['entitlement_ids'], true)) return null;
    }
    return ['original' => $original, 'time' => (int)$time, 'status' => $status, 'expires' => $expires ?? gmdate('Y-m-d H:i:s')];
}
