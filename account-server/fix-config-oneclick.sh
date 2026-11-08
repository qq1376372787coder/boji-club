#!/usr/bin/env bash
# 一键补键：在服务器上直接运行，幂等、失败即停。
#
#   bash /tmp/boji-fix-config.sh
#
# 完成后屏幕会打印 40 位的 webhook 鉴权值，把它填到 RevenueCat 后台即可。
set -euo pipefail

ROOT="${BOJICLUB_ROOT:-/opt/bojiclub-account}"
cd "$ROOT"

log() { printf '\033[1;34m[补键]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }

[ -f "$ROOT/config.php" ] || die "找不到 $ROOT/config.php，请在账号服务安装目录运行本脚本"

# 契约与校验脚本随代码仓库更新，老部署上可能没有 —— 直接从仓库补齐，
# 这样用户不必先跑一次完整部署。
RAW_BASE="https://raw.githubusercontent.com/qq1376372787coder/boji-club/main/account-server"
for helper in config-contract.php check-config.php; do
    if [ ! -f "$ROOT/$helper" ]; then
        log "缺少 $helper，从仓库补齐"
        curl -fsSL "$RAW_BASE/$helper" -o "$ROOT/$helper" \
            || wget -q "$RAW_BASE/$helper" -O "$ROOT/$helper" \
            || die "无法下载 $helper，请手工部署最新代码后重跑"
        [ -s "$ROOT/$helper" ] || die "$helper 下载为空"
    fi
done
[ -f "$ROOT/config-contract.php" ] || die "缺少 config-contract.php，无法继续"

# ---------- 0. PHP-FPM worker 用户 ----------
php_user="$(ps -o user= -C php-fpm 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$php_user" ] || php_user="$(awk -F= '/^user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/php/*/fpm/pool.d/www.conf 2>/dev/null | head -1)"
[ -n "$php_user" ] || die "无法确定 PHP-FPM worker 用户"
php_group="$(id -gn "$php_user" 2>/dev/null || echo "$php_user")"
log "PHP-FPM worker: $php_user:$php_group"

# ---------- 1. 备份 ----------
backup_dir="/root/bojiclub-config-backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_dir"
cp -a "$ROOT/config.php" "$backup_dir/config.php"
ok "已备份到 $backup_dir/config.php"

# ---------- 2. 生成缺失的密钥 ----------
install -d -m 0700 "$ROOT/private"
[ -s "$ROOT/private/revenuecat-webhook.secret" ] || openssl rand -base64 40 | tr -d '\n/+=' | cut -c1-40 > "$ROOT/private/revenuecat-webhook.secret"
[ -s "$ROOT/private/apple-token-encryption.key" ] || openssl rand -base64 32 > "$ROOT/private/apple-token-encryption.key"
chmod 0600 "$ROOT/private/"*.secret "$ROOT/private/apple-token-encryption.key" 2>/dev/null || true
ok "密钥文件就绪（$ROOT/private/）"

# ---------- 3. 合并缺失配置键 ----------
php <<'PHP'
<?php
declare(strict_types=1);
require '/opt/bojiclub-account/config-contract.php';

$configPath = '/opt/bojiclub-account/config.php';
$config = require $configPath;
if (!is_array($config)) { fwrite(STDERR, "config.php 未返回数组\n"); exit(1); }

$webhook = trim((string) file_get_contents('/opt/bojiclub-account/private/revenuecat-webhook.secret'));
$appleKey = trim((string) file_get_contents('/opt/bojiclub-account/private/apple-token-encryption.key'));
$defaults = [
    'apple_client_ids' => ['com.bojiclub.app.dev'],
    'apple_keys_cache_dir' => '/opt/bojiclub-account/cache/apple-keys',
    'apple_private_key_path' => '/etc/bojiclub/apple-signin.p8',
    'apple_token_encryption_key' => $appleKey,
    'revenuecat_webhook_authorization' => $webhook,
    'revenuecat_product_ids' => ['yuefu', 'nianfu', 'yongjiu'],
    'revenuecat_lifetime_product_ids' => ['yongjiu'],
    'revenuecat_store' => 'APP_STORE',
    'revenuecat_app_id' => 'app0302d94ca1',
    'revenuecat_entitlement_id' => '薄肌俱乐部_pro',
    'revenuecat_project_id' => '9ce7d94a',
    'revenuecat_v2_entitlement_id' => 'entl5fbc5bccbf',
    'revenuecat_v2_products' => [
        'prod84eab5a54f' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'yuefu', 'type' => 'subscription'],
        'prod5e2b6410d5' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'nianfu', 'type' => 'subscription'],
        'prod53ea4e8e97' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'yongjiu', 'type' => 'non_consumable'],
    ],
    'revenuecat_api_v2_key_file' => '/opt/bojiclub-account/private/revenuecat-api-v2.key',
];
$missing = [];
foreach ($defaults as $key => $value) {
    if (!array_key_exists($key, $config)) { $config[$key] = $value; $missing[] = $key; }
}
// 已存在但取值不对的项，只在明显是旧档时纠正，其余保持原样。
if (($config['revenuecat_product_ids'] ?? null) === ['bojiclub_halfyear_2990', 'bojiclub_yearly_4290']) {
    $config['revenuecat_product_ids'] = $defaults['revenuecat_product_ids'];
    $missing[] = 'revenuecat_product_ids（纠正旧档）';
}
if (isset($config['revenuecat_environment']) && in_array(strtoupper((string) $config['revenuecat_environment']), ['PRODUCTION', 'SANDBOX'], true)) {
    // 环境值保留：切错会让所有支付回调被当成异常事件拒收。
} else {
    fwrite(STDERR, "revenuecat_environment 取值异常，请人工核对（PRODUCTION 或 SANDBOX）\n");
    exit(1);
}

$export = var_export($config, true);
// var_export 对关联数组输出 'key' => value（不带序号），对列表输出 0 => value。
// 去掉列表的序号前缀并统一 => 两侧空格，让生成的文件保持可读。
$export = preg_replace('/^\s*\d+\s*=>\s*/m', '        ', (string) $export);
$export = preg_replace('/\s+=>\s+/', ' => ', (string) $export);
if (!is_string($export) || $export === '') { fwrite(STDERR, "配置导出失败，未写入任何内容\n"); exit(1); }
$temp = $configPath . '.tmp' . bin2hex(random_bytes(4));
if (file_put_contents($temp, "<?php\ndeclare(strict_types=1);\nreturn " . $export . ";\n", LOCK_EX) === false) { fwrite(STDERR, "写入失败\n"); exit(1); }
chmod($temp, 0640);
// 先确认新文件是合法 PHP 再替换，避免把线上配置写坏。
exec('php -l ' . escapeshellarg($temp), $lintOut, $lintCode);
if ($lintCode !== 0) { @unlink($temp); fwrite(STDERR, "生成的配置未通过语法检查，已放弃替换\n"); exit(1); }
if (!rename($temp, $configPath)) { fwrite(STDERR, "替换失败\n"); exit(1); }
echo $missing ? ('补齐 ' . count($missing) . ' 项：' . implode('、', $missing) . "\n") : "配置键齐全，无需补写\n";
PHP
ok "config.php 已合并缺失键"

# ---------- 4. 目录与权限 ----------
install -d -m 0750 -o root -g "$php_group" "$ROOT/cache"
install -d -m 0700 -o "$php_user" -g "$php_group" "$ROOT/cache/apple-keys"
chown "root:$php_group" "$ROOT/config.php"
chmod 0640 "$ROOT/config.php"
install -d -m 0750 -o root -g "$php_group" "$ROOT/media" 2>/dev/null || true
ok "缓存目录与权限就绪（owner $php_user:$php_group）"

# ---------- 5. 校验 ----------
if [ -f "$ROOT/check-config.php" ]; then
    php "$ROOT/check-config.php" || die "配置契约校验未通过，请把上面输出发给运维支付"
else
    log "未找到 check-config.php，跳过校验（建议部署最新代码）"
fi

# ---------- 6. 待办与结果 ----------
webhook="$(cat "$ROOT/private/revenuecat-webhook.secret")"
echo
echo "=========================================================="
echo "  补键完成。下面两件事请照做："
echo
echo "  1）把这一串 40 位值填到 RevenueCat 后台"
echo "     Project Settings → Integrations → Webhook → Authorization"
echo "     （webhook 地址：https://bojiclub.fun/account/v1/webhooks/revenuecat）"
echo
echo "     $webhook"
echo
echo "  2）放置两个密钥文件（缺了对应功能不可用）："
echo "     /etc/bojiclub/apple-signin.p8      （Apple 登录私钥）"
echo "     $ROOT/private/revenuecat-api-v2.key  （RevenueCat API v2，sk_ 开头）"
echo
echo "  3）重载 PHP-FPM：systemctl reload php*-fpm"
echo "=========================================================="
