<?php
// Merge this array into /opt/bojiclub-account/config.php; do not replace database/SMS keys.
return [
    'revenuecat_webhook_authorization' => '', // Generate a strong random value; configure the same Authorization in RevenueCat.
    'revenuecat_product_ids' => ['yuefu', 'nianfu', 'yongjiu'],
    'revenuecat_lifetime_product_ids' => ['yongjiu'],
    // 已下架旧档（¥29.9/¥42.9 及更早）：只为已购订阅续订/过期，不发放新权益。
    'revenuecat_legacy_product_ids' => ['monthly', 'six_month', 'lifetime', 'bojiclub_halfyear_2990', 'bojiclub_yearly_4290'],
    'revenuecat_entitlement_id' => '薄肌俱乐部_pro',
    'revenuecat_environment' => 'SANDBOX', // Current TestFlight server. Review separately before switching to PRODUCTION.
    'revenuecat_store' => 'APP_STORE',
    'revenuecat_app_id' => 'app0302d94ca1', // RevenueCat Apple app identifier, not the Bundle ID.
    'membership_enforcement' => true,
    // API v2 secret stays only in this private server file, never in an iOS build.
    'revenuecat_api_v2_key_file' => '/opt/bojiclub-account/private/revenuecat-api-v2.key',
    'revenuecat_project_id' => '9ce7d94a',
    'revenuecat_v2_entitlement_id' => 'entl5fbc5bccbf',
    'revenuecat_v2_products' => [
        'prod84eab5a54f' => ['app_id'=>'app0302d94ca1', 'store_identifier'=>'yuefu', 'type'=>'subscription'],
        'prod5e2b6410d5' => ['app_id'=>'app0302d94ca1', 'store_identifier'=>'nianfu', 'type'=>'subscription'],
        'prod53ea4e8e97' => ['app_id'=>'app0302d94ca1', 'store_identifier'=>'yongjiu', 'type'=>'non_consumable'],
    ],
];
