<?php
declare(strict_types=1);
// P0-3 会员商品统一：发放白名单只认当前三档，权益 ID 只认一个。
// 纯策略用例（revenueCatDecision 是纯函数），不需要数据库。
require __DIR__.'/../account-server/public/revenuecat.php';

function rcu(bool $ok, string $label): void {
    if (!$ok) throw new RuntimeException($label);
    echo "PASS {$label}\n";
}
function rcuEvent(array $overrides = []): array {
    static $now = null;
    if ($now === null) $now = (int)(microtime(true) * 1000);
    return array_merge([
        'id' => 'rcu-' . bin2hex(random_bytes(6)),
        'type' => 'INITIAL_PURCHASE', 'app_id' => 'app_fixture', 'app_user_id' => 'boji-970001',
        'environment' => 'SANDBOX', 'store' => 'TEST_STORE',
        'product_id' => 'yuefu', 'entitlement_ids' => ['薄肌俱乐部_pro'],
        'original_transaction_id' => 'rcu-tx-' . bin2hex(random_bytes(4)), 'transaction_id' => 'rcu-tx',
        'purchased_at_ms' => $now, 'event_timestamp_ms' => $now, 'expiration_at_ms' => $now + 86400000,
    ], $overrides);
}
// 不设置 revenuecat_product_ids / revenuecat_entitlement_id：全部走代码默认值。
$base = ['revenuecat_environment' => 'SANDBOX', 'revenuecat_store' => 'TEST_STORE', 'revenuecat_app_id' => 'app_fixture'];

// 1) 两套清单的默认值：发放只认三档，旧四档单独隔离。
rcu(revenueCatProductIDs([]) === ['yuefu', 'nianfu', 'yongjiu'], '默认发放白名单只有当前三档');
rcu(revenueCatProductIDs(['revenuecat_product_ids' => ['yuefu']]) === ['yuefu'], '配置覆盖发放白名单仍然生效');
$legacy = revenueCatLegacyProductIDs([]);
rcu($legacy === ['monthly', 'six_month', 'lifetime', 'bojiclub_halfyear_2990', 'bojiclub_yearly_4290'], '默认旧档清单固定为已下架的四个 ID');
rcu(revenueCatSupportedProduct([], 'yuefu') && revenueCatSupportedProduct([], 'bojiclub_yearly_4290'), '已购老商品仍被视为受支持商品（续订/过期可用）');
rcu(!revenueCatSupportedProduct([], 'unapproved'), '未知商品不受支持');

// 2) 三档在默认配置下正常发放。
foreach (['yuefu', 'nianfu', 'yongjiu'] as $product) {
    $event = rcuEvent(['product_id' => $product]);
    if ($product === 'yongjiu') { $event['type'] = 'NON_RENEWING_PURCHASE'; $event['expiration_at_ms'] = null; }
    $d = revenueCatDecision($event, $base);
    rcu($d !== null && $d['status'] === 'active', "默认配置接受当前档位 {$product}");
}

// 3) 旧档一律拒绝新交易（未存在的 original_transaction_id）。
foreach (['bojiclub_halfyear_2990', 'bojiclub_yearly_4290', 'monthly', 'six_month', 'lifetime'] as $product) {
    rcu(revenueCatDecision(rcuEvent(['product_id' => $product]), $base) === null, "旧档新交易被拒绝 {$product}");
    rcu(revenueCatDecision(rcuEvent(['product_id' => $product]), $base, false) === null, "旧档未知订阅被拒绝 {$product}");
}

// 4) 老付费用户：已存在的订阅仍可续订、过期、退款（不凭空失效，也永不过期不了）。
$renewal = rcuEvent(['product_id' => 'bojiclub_yearly_4290', 'type' => 'RENEWAL']);
$d = revenueCatDecision($renewal, $base, true);
rcu($d !== null && $d['status'] === 'active', '已购旧档订阅的续订被接受');
$expire = rcuEvent(['product_id' => 'bojiclub_halfyear_2990', 'type' => 'EXPIRATION']);
$d = revenueCatDecision($expire, $base, true);
rcu($d !== null && $d['status'] === 'expired', '已购旧档订阅的过期被接受（否则老订阅永不过期）');
$refund = rcuEvent(['product_id' => 'bojiclub_yearly_4290', 'type' => 'CANCELLATION', 'cancel_reason' => 'CUSTOMER_SUPPORT']);
unset($refund['entitlement_ids']);
$d = revenueCatDecision($refund, $base, true);
rcu($d !== null && $d['status'] === 'revoked', '已购旧档订阅的退款撤销被接受');
rcu(revenueCatDecision(rcuEvent(['product_id' => 'bojiclub_yearly_4290', 'type' => 'EXPIRATION']), $base, false) === null,
    '未知旧档订阅的过期不被接受（没有记录可撤销）');

// 5) 权益 ID 只有一个：未配置时 fail-closed 到 薄肌俱乐部_pro。
$noEntitlement = rcuEvent(); unset($noEntitlement['entitlement_ids']);
rcu(revenueCatDecision($noEntitlement, $base) === null, '缺少 entitlement_ids 的发放事件被拒绝');
rcu(revenueCatDecision(rcuEvent(['entitlement_ids' => ['club_member']]), $base) === null, '旧权益 ID club_member 不再发放权益');
rcu(revenueCatDecision(rcuEvent(['entitlement_ids' => ['薄肌俱乐部_pro']]), $base) !== null, '唯一权益 ID 薄肌俱乐部_pro 发放权益');
// 显式空串仍表示关闭该检查（向后兼容），只有「缺失」才回落到默认 ID。
rcu(revenueCatDecision($noEntitlement, $base + ['revenuecat_entitlement_id' => '']) !== null, '显式空配置保持关闭权益检查的旧行为');
rcu(revenueCatDecision($noEntitlement, $base + ['revenuecat_entitlement_id' => '薄肌俱乐部_pro']) === null, '显式配置同样强制权益检查');

// 6) 永久商品的无到期语义只属于当前档位。
$lifetime = rcuEvent(['product_id' => 'yongjiu', 'type' => 'NON_RENEWING_PURCHASE', 'expiration_at_ms' => null]);
$d = revenueCatDecision($lifetime, $base);
rcu($d !== null && $d['expires'] === '9999-12-31 23:59:59', 'yongjiu 无到期时间视为永久');

// 7) 源码一致性：仓库里不再出现旧权益 ID，文档与配置指向同一套。
$root = dirname(__DIR__);
$sources = [
    'REVENUECAT.md',
    'BojiClub/Info.plist',
    'account-server/revenuecat-config.example.php',
    'account-server/public/revenuecat.php',
    'account-server/public/revenuecat-policy.php',
];
foreach ($sources as $rel) {
    $body = (string)file_get_contents($root . '/' . $rel);
    rcu(!str_contains($body, 'club_member'), "旧权益 ID 已从 {$rel} 清除");
}
rcu(str_contains((string)file_get_contents($root . '/BojiClub/Info.plist'), '薄肌俱乐部_pro'), 'Info.plist 使用唯一权益 ID');
rcu(str_contains((string)file_get_contents($root . '/account-server/revenuecat-config.example.php'), "'revenuecat_product_ids' => ['yuefu', 'nianfu', 'yongjiu']"), '配置样例使用当前三档');
rcu(str_contains((string)file_get_contents($root . '/REVENUECAT.md'), 'yuefu'), '文档记录当前三档');

echo "P0-3 PRODUCT/ENTITLEMENT UNIFICATION CHECKS PASSED\n";
