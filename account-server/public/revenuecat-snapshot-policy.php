<?php
declare(strict_types=1);

/** API v2 returns proj-prefixed IDs even when the API accepts the legacy dashboard ID. */
function revenueCatProjectIDsMatch(mixed $actual, mixed $expected): bool {
    if (!is_string($actual) || !is_string($expected) || $actual === '' || $expected === '') return false;
    $canonical = static fn(string $id): string => preg_match('/^[a-f0-9]{8}$/D', $id) === 1 ? 'proj'.$id : $id;
    return $canonical($actual) === $canonical($expected);
}

/** Pure policy for server-fetched RevenueCat API v2 responses. No client claims. */
function revenueCatSnapshotPolicy(array $customer, array $subscriptions, array $purchases, array $entitlements, array $config, int $userID, int $observedMS): array {
    $expected = 'boji-' . $userID;
    if (($customer['object'] ?? null) !== 'customer' || !revenueCatProjectIDsMatch($customer['project_id'] ?? null, $config['revenuecat_project_id'] ?? null)) {
        throw new UnexpectedValueException('rc_invalid_customer');
    }
    $empty = ['active'=>false, 'product_id'=>'', 'starts_at'=>null, 'expires_at'=>null, 'purchase_id'=>null];
    if (($customer['id'] ?? null) !== $expected) {
        // An alias resolving to another identified club account cannot share its access.
        if (is_string($customer['id'] ?? null) && preg_match('/^boji-[1-9][0-9]*$/D', $customer['id'])) return $empty;
        throw new UnexpectedValueException('rc_identity_mismatch');
    }
    $entitlementID = $config['revenuecat_v2_entitlement_id'] ?? '';
    $lookupKey = $config['revenuecat_entitlement_id'] ?? '';
    if (!is_string($entitlementID) || $entitlementID === '' || !is_string($lookupKey) || $lookupKey === '') throw new UnexpectedValueException('rc_config');
    $globalAccess = false;
    foreach ($entitlements as $item) {
        if (!is_array($item)) throw new UnexpectedValueException('rc_invalid_entitlement');
        if (($item['entitlement_id'] ?? null) !== $entitlementID) continue;
        if (!array_key_exists('expires_at', $item)) throw new UnexpectedValueException('rc_invalid_entitlement');
        $expiry = $item['expires_at'];
        if ($expiry !== null && (!is_int($expiry) || $expiry < 946684800000)) throw new UnexpectedValueException('rc_invalid_entitlement');
        $globalAccess = $expiry === null || $expiry > $observedMS;
    }
    if (!$globalAccess) return $empty;
    $environment = strtolower((string)($config['revenuecat_environment'] ?? 'PRODUCTION'));
    if (!in_array($environment, ['sandbox','production'], true)) throw new UnexpectedValueException('rc_config');
    $catalog = $config['revenuecat_v2_products'] ?? [];
    $best = $empty;
    $hasEntitlement = static function(array $row) use ($entitlementID, $lookupKey, $config): bool {
        $items = $row['entitlements']['items'] ?? null;
        if (!is_array($items) || !array_is_list($items)) throw new UnexpectedValueException('rc_invalid_entitlement_list');
        foreach ($items as $item) {
            if (!is_array($item)) throw new UnexpectedValueException('rc_invalid_entitlement');
            if (($item['id'] ?? '') === $entitlementID && ($item['lookup_key'] ?? '') === $lookupKey &&
                revenueCatProjectIDsMatch($item['project_id'] ?? null, $config['revenuecat_project_id'] ?? null) && ($item['state'] ?? '') === 'active') return true;
        }
        if (!empty($row['entitlements']['next_page'])) throw new UnexpectedValueException('rc_incomplete_entitlements');
        return false;
    };
    foreach ([['subscription',$subscriptions], ['purchase',$purchases]] as [$type,$rows]) {
        foreach ($rows as $row) {
            if (!is_array($row) || ($row['object'] ?? '') !== $type) throw new UnexpectedValueException('rc_invalid_purchase');
            if (($row['customer_id'] ?? '') !== $expected || ($row['store'] ?? '') !== 'app_store' || ($row['environment'] ?? '') !== $environment) continue;
            $product = $catalog[$row['product_id'] ?? ''] ?? null;
            if (!is_array($product) || ($product['app_id'] ?? '') !== ($config['revenuecat_app_id'] ?? '') ||
                !revenueCatSupportedProduct($config, (string)($product['store_identifier'] ?? ''))) continue;
            if (!$hasEntitlement($row)) continue;
            if (!is_string($row['id'] ?? null) || $row['id'] === '' || strlen($row['id']) > 255) throw new UnexpectedValueException('rc_invalid_purchase');
            $identifier = $product['store_identifier'];
            if ($type === 'subscription') {
                if (($product['type'] ?? '') !== 'subscription') continue;
                if (!is_bool($row['gives_access'] ?? null) || !is_bool($row['pending_payment'] ?? null)) throw new UnexpectedValueException('rc_invalid_subscription');
                if (!$row['gives_access']) continue;
                // Pending renewals can still grant access during a legitimate grace period.
                $starts = revenueCatDate($row['starts_at'] ?? null);
                $expiry = revenueCatDate($row['ends_at'] ?? null) ?? revenueCatDate($row['current_period_ends_at'] ?? null);
                if ($starts === null || strtotime($starts . ' UTC') * 1000 > $observedMS) continue;
                if ($expiry === null || strtotime($expiry . ' UTC') * 1000 <= $observedMS) {
                    // gives_access is authoritative in grace/unknown access states. Keep
                    // a short renewable verification lease, never manufacture permanent access.
                    $expiry = gmdate('Y-m-d H:i:s', (int)floor($observedMS / 1000) + 300);
                }
            } else {
                $lifetime = $config['revenuecat_lifetime_product_ids'] ?? [];
                if (!in_array($identifier, $lifetime, true) || ($product['type'] ?? '') !== 'non_consumable' || ($row['status'] ?? '') !== 'owned') continue;
                $starts = revenueCatDate($row['purchased_at'] ?? null);
                if ($starts === null || strtotime($starts . ' UTC') * 1000 > $observedMS) continue;
                $expiry = '9999-12-31 23:59:59';
            }
            if (!$best['active'] || $expiry > $best['expires_at']) {
                $best = ['active'=>true, 'product_id'=>$identifier, 'starts_at'=>$starts, 'expires_at'=>$expiry, 'purchase_id'=>$row['id']];
            }
        }
    }
    return $best;
}
