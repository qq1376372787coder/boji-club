#!/usr/bin/env bash
set -euo pipefail

cd /opt/bojiclub-account
mode="${1:-deploy}"
if [[ "$mode" == "--check-config" ]]; then
    exec php check-config.php
fi
if [[ "$mode" != "deploy" ]]; then
    echo "用法：$0 [deploy|--check-config]" >&2
    exit 2
fi
chmod 0755 /opt/bojiclub-account
install -d -m 0755 -o root -g root public
install -d -m 0750 -o www-data -g www-data media
chmod 0644 public/index.php schema.sql
find public admin -name '*.php' -exec php -l {} \; >/dev/null
php_service="${BOJICLUB_PHP_SERVICE:-php8.2-fpm}"
if [[ ! "$php_service" =~ ^php[0-9]+\.[0-9]+-fpm$ ]]; then echo 'PHP service name is invalid.' >&2; exit 1; fi

if [[ ! -f config.php ]]; then
    : "${BOJICLUB_DB_PASSWORD:?请通过 BOJICLUB_DB_PASSWORD 提供数据库密码，不要写入脚本。}"
    : "${BOJICLUB_OTP_SECRET:?请通过 BOJICLUB_OTP_SECRET 提供 OTP 签名密钥，不要写入脚本。}"
    db_password="$BOJICLUB_DB_PASSWORD"
    otp_secret="$BOJICLUB_OTP_SECRET"
    for value in "$db_password" "$otp_secret"; do
        if [[ ! "$value" =~ ^[A-Za-z0-9._~+/=-]{24,128}$ ]]; then
            echo '部署密钥必须为 24–128 位安全字符，且不能包含引号、空白或换行。' >&2
            exit 1
        fi
    done
    # 以下密钥缺失时自动生成并落盘到 0600 文件，避免每次部署重新生成导致旧密钥失效。
    generate_config_secret() {
        local path="$1" length="$2"
        if [[ -s "$path" ]]; then cat "$path"; return 0; fi
        local value
        if command -v openssl >/dev/null 2>&1; then value="$(openssl rand -base64 "$length" | tr -d '\n/+=' | cut -c1-"$length")"; else value="$(head -c "$length" /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-"$length")"; fi
        if [[ ${#value} -lt $length ]]; then echo "无法生成足够长度的随机密钥：$path" >&2; exit 1; fi
        (umask 077 && printf '%s' "$value" > "$path")
        cat "$path"
    }
    webhook_secret="$(generate_config_secret private/revenuecat-webhook.secret 40)"
    apple_token_key="$(generate_config_secret private/apple-token-encryption.key 48)"
    apple_client_ids="${BOJICLUB_APPLE_CLIENT_IDS:-com.bojiclub.app.dev}"
    apple_environment="${BOJICLUB_APPLE_ENVIRONMENT:-SANDBOX}"
    # Sign in with Apple 的私钥与密钥 ID 必须由管理员提供，无法自动生成。
    : "${BOJICLUB_APPLE_TEAM_ID:?请通过 BOJICLUB_APPLE_TEAM_ID 提供 Apple Team ID。}"
    : "${BOJICLUB_APPLE_KEY_ID:?请通过 BOJICLUB_APPLE_KEY_ID 提供 Apple 私钥 Key ID。}"
    apple_team_id="$BOJICLUB_APPLE_TEAM_ID"
    apple_key_id="$BOJICLUB_APPLE_KEY_ID"
    install -d -m 0700 private
    chown -R root:www-data private
    # RevenueCat API v2 密钥由管理员放置；缺失时提示，不阻断部署。
    if [[ ! -s private/revenuecat-api-v2.key ]]; then
        echo '提示：private/revenuecat-api-v2.key 缺失，请放入 RevenueCat API v2 secret key（sk_ 开头）。' >&2
    else
        chmod 0640 private/revenuecat-api-v2.key
        chown root:www-data private/revenuecat-api-v2.key
    fi
    mysql -e "CREATE DATABASE IF NOT EXISTS bojiclub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'bojiclub'@'localhost' IDENTIFIED BY '${db_password}'; GRANT SELECT,INSERT,UPDATE,DELETE ON bojiclub.* TO 'bojiclub'@'localhost'; FLUSH PRIVILEGES;"
    umask 0027
    cat > config.php <<PHP
<?php
// 本文件由 deploy.sh 生成。缺失的密钥由部署环境变量或同目录 private/*.secret 提供。
// 不要把真实密钥写回本文件或提交到仓库。
return [
    'dsn' => 'mysql:host=127.0.0.1;dbname=bojiclub;charset=utf8mb4',
    'db_user' => 'bojiclub',
    'db_password' => '${db_password}',
    'otp_secret' => '${otp_secret}',
    'sms_mode' => 'development',
    'dev_phone' => '18800000000',
    'allow_development_phone_auth' => false,
    // 验证码明文回显（dev_code）为独立开关，默认关闭；仅本地开发环境需要时置 true。
    'expose_dev_code' => false,
    'membership_enforcement' => true,
    // Apple 登录：Sign in with Apple 的客户端标识，必须与 App 的 Bundle ID 一致。
    'apple_client_ids' => ['${apple_client_ids}'],
    'apple_keys_cache_dir' => '/opt/bojiclub-account/cache/apple-keys',
    // 以下四项用于签发 Apple client secret，缺任何一项都会让 Apple 登录返回 503。
    'apple_team_id' => '${apple_team_id}',
    'apple_key_id' => '${apple_key_id}',
    'apple_private_key_path' => '/etc/bojiclub/apple-signin.p8',
    'apple_token_encryption_key' => '${apple_token_key}',
    // RevenueCat webhook 鉴权头，必须与 RevenueCat 后台配置的 Authorization 完全一致，
    // 长度不足 24 位时 webhook 会被自身拒绝（线上表现为付款后权益不到账）。
    'revenuecat_webhook_authorization' => '${webhook_secret}',
    'revenuecat_product_ids' => ['yuefu', 'nianfu', 'yongjiu'],
    'revenuecat_lifetime_product_ids' => ['yongjiu'],
    'revenuecat_environment' => '${apple_environment}',
    'revenuecat_store' => 'APP_STORE',
    'revenuecat_app_id' => 'app0302d94ca1',
    'revenuecat_entitlement_id' => '薄肌俱乐部_pro',
    // 以下四项用于 API v2 会员核验；缺失会让 /me/membership/verify 返回
    // rc_not_configured，客户端表现为长时间"核验中"。
    'revenuecat_project_id' => '9ce7d94a',
    'revenuecat_v2_entitlement_id' => 'entl5fbc5bccbf',
    'revenuecat_v2_products' => [
        'prod84eab5a54f' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'yuefu', 'type' => 'subscription'],
        'prod5e2b6410d5' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'nianfu', 'type' => 'subscription'],
        'prod53ea4e8e97' => ['app_id' => 'app0302d94ca1', 'store_identifier' => 'yongjiu', 'type' => 'non_consumable'],
    ],
    'revenuecat_api_v2_key_file' => '/opt/bojiclub-account/private/revenuecat-api-v2.key',
];
PHP
fi

# 部署后校验：键缺失或取值非法时直接失败，避免接口在运行时静默 401/503。
# 私钥文件由管理员在部署后放置，check-config.php 只校验配置键齐全与取值合法。
php check-config.php

chown root:www-data config.php
chmod 0640 config.php
# Apple 公钥缓存：目录必须由 PHP-FPM worker 可写，否则 cachedAppleKeys() 会在
# 读取公钥前因 cache unavailable 失败，Apple 登录返回 503。
install -d -m 0750 -o root -g www-data cache
install -d -m 0700 -o www-data -g www-data cache/apple-keys
backup_dir="/root/bojiclub-deploy-backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_dir"
mysqldump --single-transaction bojiclub > "$backup_dir/database.sql"
cp config.php "$backup_dir/config.php"
cp -a /etc/nginx "$backup_dir/nginx"
chmod 0600 "$backup_dir/database.sql" "$backup_dir/config.php"
BOJI_MIGRATION_ROOT=1 php migrate-20261001.php
BOJI_MIGRATION_ROOT=1 php migrate-build112-compat.php
BOJI_MIGRATION_ROOT=1 php migrate-v2-quality.php
BOJI_MIGRATION_ROOT=1 php migrate-v2-repair.php --apply
BOJI_MIGRATION_ROOT=1 php migrate-onboarding-v2.php --apply
# R10: Verify schema compatibility and report drift
BOJI_MIGRATION_ROOT=1 php migrate-build112-compat.php --check || true
BOJI_MIGRATION_ROOT=1 php migrate-v2-quality.php --check || true
BOJI_MIGRATION_ROOT=1 php migrate-onboarding-v2.php --check
install -d -m 0750 -o www-data -g www-data admin-media
find admin-media -maxdepth 1 -type f -name "*.png" -exec chmod 0644 {} \;
php migrate-repair-v5.php --apply
BOJI_MIGRATION_ROOT=1 php migrate-repair-v6.php --apply

site="${BOJICLUB_NGINX_SITE:-/etc/nginx/sites-enabled/bojiclub}"
if [[ ! -f "$site" ]] || ! grep -q 'location .*account/v1/' "$site"; then
    echo '请先配置账号与管理后台路由，参考两个 location.conf 文件。' >&2; exit 1
fi
python3 - "$site" "$php_service" <<'PY'
import re,sys
from pathlib import Path
path=Path(sys.argv[1]).resolve(); content=path.read_text()
content=re.sub(r'(location\s+\^~\s+/account/v1/\s*\{.*?client_max_body_size\s+)\w+',r'\g<1>18m',content,flags=re.S)
content=re.sub(r'(location\s*=\s*/admin/\s*\{.*?client_max_body_size\s+)\w+',r'\g<1>32m',content,flags=re.S)
content=re.sub(r'fastcgi_pass unix:/run/php/php[0-9.]+-fpm.sock;',f'fastcgi_pass unix:/run/php/{sys.argv[2]}.sock;',content)
path.write_text(content)
version=sys.argv[2][3:].removesuffix('-fpm')
Path(f'/etc/php/{version}/fpm/conf.d/99-bojiclub-upload.ini').write_text('upload_max_filesize=5M\npost_max_size=32M\n')
PY

nginx -t
install -m 0644 deploy/bojiclub-account-deletions.service /etc/systemd/system/bojiclub-account-deletions.service
install -m 0644 deploy/bojiclub-account-deletions.timer /etc/systemd/system/bojiclub-account-deletions.timer
php migrate-v2-repair.php --check
for worker in action-jobs ai-runs ai-run-prune domain-outbox domain-notifications domain-reconcile membership-refresh ai-completion-refresh; do
    install -m 0644 "deploy/bojiclub-$worker.service" "/etc/systemd/system/bojiclub-$worker.service"
    install -m 0644 "deploy/bojiclub-$worker.timer" "/etc/systemd/system/bojiclub-$worker.timer"
done
systemctl daemon-reload
for worker in action-jobs ai-runs ai-run-prune domain-outbox domain-notifications domain-reconcile membership-refresh ai-completion-refresh; do systemctl enable --now "bojiclub-$worker.timer"; done
systemctl enable --now bojiclub-account-deletions.timer
systemctl reload "$php_service"
systemctl reload nginx
echo 'Boji Club account service deployed.'
