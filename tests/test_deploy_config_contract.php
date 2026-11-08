<?php
declare(strict_types=1);
/**
 * 部署配置契约测试（校验函数判据本身）。
 *
 * deploy.sh 生成模板的文本级校验见 tests/test_deploy_config_contract.py，
 * 那里不依赖 PHP，可在任意环境运行。
 */
require dirname(__DIR__) . '/account-server/config-contract.php';

$checks = 0;
function contractCheck(bool $ok, string $label): void {
    global $checks;
    if (!$ok) { fwrite(STDERR, "FAIL: $label\n"); exit(1); }
    $checks++;
}

$valid = [
    'dsn' => 'mysql:host=127.0.0.1;dbname=bojiclub;charset=utf8mb4',
    'db_user' => 'bojiclub',
    'db_password' => str_repeat('d', 24),
    'otp_secret' => str_repeat('o', 24),
    'apple_client_ids' => ['com.bojiclub.app'],
    'apple_keys_cache_dir' => '/opt/bojiclub-account/cache/apple-keys',
    'apple_team_id' => 'TEAMID1234',
    'apple_key_id' => 'KEYID1234',
    'apple_private_key_path' => '/nonexistent/apple-signin.p8',
    'apple_token_encryption_key' => base64_encode(random_bytes(32)),
    'revenuecat_webhook_authorization' => str_repeat('w', 32),
    'revenuecat_product_ids' => ['yuefu', 'nianfu', 'yongjiu'],
    'revenuecat_lifetime_product_ids' => ['yongjiu'],
    'revenuecat_environment' => 'SANDBOX',
    'revenuecat_store' => 'APP_STORE',
    'revenuecat_app_id' => 'app0302d94ca1',
    'revenuecat_entitlement_id' => 'thinclub_pro',
    'revenuecat_project_id' => '9ce7d94a',
    'revenuecat_v2_entitlement_id' => 'entl5fbc5bccbf',
    'revenuecat_v2_products' => [
        'prod84eab5a54f' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'yuefu', 'type' => 'subscription'],
    ],
    'revenuecat_api_v2_key_file' => '/nonexistent/revenuecat-api-v2.key',
];
contractCheck(bojiValidateConfig($valid, false) === [], '自检配置通过契约校验');
contractCheck(bojiValidateConfig($valid, false) === bojiValidateConfig($valid, false), '校验结果稳定');

$broken = $valid;
unset($broken['revenuecat_webhook_authorization']);
contractCheck((bool) preg_grep('/revenuecat_webhook_authorization/', bojiValidateConfig($broken, false)), '缺失 webhook 密钥被拒绝');

$broken = $valid;
$broken['revenuecat_webhook_authorization'] = 'short';
contractCheck((bool) preg_grep('/>= 24/', bojiValidateConfig($broken, false)), '过短的 webhook 密钥被拒绝');

$broken = $valid;
$broken['revenuecat_environment'] = 'STAGING';
contractCheck((bool) preg_grep('/PRODUCTION 或 SANDBOX/', bojiValidateConfig($broken, false)), '非法环境取值被拒绝');

$broken = $valid;
$broken['revenuecat_store'] = 'SIDE_LOAD';
contractCheck((bool) preg_grep('/revenuecat_store/', bojiValidateConfig($broken, false)), '非法商店取值被拒绝');

$broken = $valid;
$broken['apple_client_ids'] = 'com.bojiclub.app';
contractCheck((bool) preg_grep('/apple_client_ids/', bojiValidateConfig($broken, false)), 'apple_client_ids 非数组被拒绝');

$broken = $valid;
$broken['revenuecat_v2_products'] = ['prod1' => ['app_id' => 'x']];
contractCheck((bool) preg_grep('/v2_products/', bojiValidateConfig($broken, false)), 'v2_products 条目缺 store_identifier 被拒绝');

$broken = $valid;
$broken['apple_client_ids'] = [];
contractCheck((bool) preg_grep('/apple_client_ids/', bojiValidateConfig($broken, false)), 'apple_client_ids 空数组被拒绝');

fwrite(STDOUT, "config-contract OK ($checks checks)\n");
