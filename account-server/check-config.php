<?php
declare(strict_types=1);
/**
 * 部署配置校验：可被 deploy.sh 在部署后调用，也可单独运行（deploy.sh --check-config）。
 *
 * 校验失败时退出码 1，避免配置缺失被部署流程吞掉、只在运行时表现为接口 401/503。
 * 私钥文件缺失只告警不失败：管理员需在部署后登录服务器放置。
 */

require __DIR__ . '/config-contract.php';

$configPath = __DIR__ . '/config.php';
if (!is_file($configPath)) {
    fwrite(STDERR, "配置契约校验未通过：缺少 config.php，请先执行部署生成配置。\n");
    exit(1);
}
$config = require $configPath;
if (!is_array($config)) {
    fwrite(STDERR, "配置契约校验未通过：config.php 未返回数组。\n");
    exit(1);
}

$errors = bojiValidateConfig($config, false);
if ($errors) {
    fwrite(STDERR, "配置契约校验未通过：\n  " . implode("\n  ", $errors) . "\n");
    exit(1);
}

$warnings = [];
foreach ([$config['apple_private_key_path'] ?? '', $config['revenuecat_api_v2_key_file'] ?? ''] as $file) {
    if (!is_string($file) || $file === '') {
        continue;
    }
    if (!is_file($file) || !is_readable($file)) {
        $warnings[] = "密钥文件缺失或不可读：{$file}（放置后由 PHP-FPM 用户可读，否则对应功能不可用）";
    }
}
$writable = $config['apple_keys_cache_dir'] ?? '';
if (is_string($writable) && $writable !== '' && (!is_dir($writable) || !is_writable($writable))) {
    $warnings[] = "Apple 公钥缓存目录不可写：{$writable}（Apple 登录会返回 503）";
}

foreach ($warnings as $warning) {
    fwrite(STDERR, "提示：{$warning}\n");
}
fwrite(STDOUT, '配置契约校验通过（' . count(bojiRequiredConfigKeys()) . " 个必需键）。\n");
