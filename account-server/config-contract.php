<?php
declare(strict_types=1);

/**
 * 部署配置契约：列出运行环境真正读取的配置键，并在部署时校验它们。
 *
 * 背景：deploy.sh 首次部署生成的 config.php 曾只包含数据库与短信键，漏掉
 * Apple 登录、RevenueCat 回调与 API v2 相关键。缺失不会让部署失败，而是让
 * 接口在运行时静默失败——webhook 全部 401、/me/membership/verify 返回
 * rc_not_configured（客户端表现为长时间"核验中"）、Apple 登录 503。
 *
 * 本文件只做校验，不读取真实密钥，可被测试与部署脚本共同引用。
 */

function bojiRequiredConfigKeys(): array {
    return [
        'dsn', 'db_user', 'db_password', 'otp_secret',
        'apple_client_ids', 'apple_keys_cache_dir',
        'apple_team_id', 'apple_key_id', 'apple_private_key_path', 'apple_token_encryption_key',
        'revenuecat_webhook_authorization',
        'revenuecat_product_ids', 'revenuecat_lifetime_product_ids',
        'revenuecat_environment', 'revenuecat_store', 'revenuecat_app_id',
        'revenuecat_entitlement_id', 'revenuecat_project_id', 'revenuecat_v2_entitlement_id',
        'revenuecat_v2_products', 'revenuecat_api_v2_key_file',
    ];
}

/**
 * 校验配置并返回错误列表；返回空数组表示通过。
 * 密钥类键只校验存在与非空，不校验明文内容。
 * $checkFileReadable 用于部署脚本：私钥文件由管理员在部署后放置，
 * 部署阶段只校验键齐全，文件缺失单独告警，不阻断部署。
 */
function bojiValidateConfig(array $config, bool $checkFileReadable = true): array {
    $errors = [];
    foreach (bojiRequiredConfigKeys() as $key) {
        if (!array_key_exists($key, $config)) { $errors[] = "缺少配置键 $key"; continue; }
        if (is_string($config[$key]) && trim($config[$key]) === '') { $errors[] = "配置键 $key 为空"; continue; }
        if (is_array($config[$key]) && !$config[$key]) { $errors[] = "配置键 $key 为空数组"; }
    }
    if (!isset($config['apple_client_ids']) || !is_array($config['apple_client_ids'])
        || !count(array_filter($config['apple_client_ids'], 'is_string'))) {
        $errors[] = 'apple_client_ids 必须是非空字符串数组';
    }
    if (isset($config['apple_keys_cache_dir']) && !is_string($config['apple_keys_cache_dir'])) {
        $errors[] = 'apple_keys_cache_dir 必须是字符串';
    }
    if (isset($config['apple_private_key_path']) && $checkFileReadable
        && (!is_string($config['apple_private_key_path']) || !is_readable($config['apple_private_key_path']))) {
        $errors[] = 'apple_private_key_path 不可读';
    }
    if (isset($config['revenuecat_api_v2_key_file']) && $checkFileReadable
        && (!is_string($config['revenuecat_api_v2_key_file']) || !is_readable($config['revenuecat_api_v2_key_file']))) {
        $errors[] = 'revenuecat_api_v2_key_file 不可读';
    }
    if (isset($config['revenuecat_webhook_authorization']) && is_string($config['revenuecat_webhook_authorization'])
        && strlen($config['revenuecat_webhook_authorization']) < 24) {
        $errors[] = 'revenuecat_webhook_authorization 长度必须 >= 24';
    }
    if (isset($config['revenuecat_environment']) && is_string($config['revenuecat_environment'])
        && !in_array(strtoupper($config['revenuecat_environment']), ['PRODUCTION', 'SANDBOX'], true)) {
        $errors[] = 'revenuecat_environment 只能是 PRODUCTION 或 SANDBOX';
    }
    if (isset($config['revenuecat_store']) && is_string($config['revenuecat_store'])
        && !in_array(strtoupper($config['revenuecat_store']), ['APP_STORE', 'PLAY_STORE', 'STRIPE', 'PROMOTIONAL'], true)) {
        $errors[] = 'revenuecat_store 取值非法';
    }
    if (isset($config['revenuecat_v2_products']) && is_array($config['revenuecat_v2_products'])) {
        foreach ($config['revenuecat_v2_products'] as $productID => $entry) {
            if (!is_string($productID) || !is_array($entry) || empty($entry['store_identifier'])) {
                $errors[] = 'revenuecat_v2_products 条目格式不正确';
                break;
            }
        }
    }
    return $errors;
}
