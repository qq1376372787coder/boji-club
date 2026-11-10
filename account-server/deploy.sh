#!/usr/bin/env bash
set -euo pipefail

cd /opt/bojiclub-account
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
    mysql -e "CREATE DATABASE IF NOT EXISTS bojiclub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'bojiclub'@'localhost' IDENTIFIED BY '${db_password}'; GRANT SELECT,INSERT,UPDATE,DELETE ON bojiclub.* TO 'bojiclub'@'localhost'; FLUSH PRIVILEGES;"
    umask 0027
    cat > config.php <<PHP
<?php
return [
    'dsn' => 'mysql:host=127.0.0.1;dbname=bojiclub;charset=utf8mb4',
    'db_user' => 'bojiclub',
    'db_password' => '${db_password}',
    'otp_secret' => '${otp_secret}',
    'sms_mode' => 'development',
    'dev_phone' => '18800000000',
    'allow_development_phone_auth' => false,
    'membership_enforcement' => true,
    'apple_client_ids' => ['com.bojiclub.app.dev'],
    'revenuecat_product_ids' => ['bojiclub_halfyear_2990', 'bojiclub_yearly_4290'],
    'revenuecat_environment' => 'PRODUCTION',
];
PHP
fi

chown root:www-data config.php
chmod 0640 config.php
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
for worker in action-jobs ai-runs ai-run-prune domain-outbox domain-notifications domain-reconcile; do
    install -m 0644 "deploy/bojiclub-$worker.service" "/etc/systemd/system/bojiclub-$worker.service"
    install -m 0644 "deploy/bojiclub-$worker.timer" "/etc/systemd/system/bojiclub-$worker.timer"
done
systemctl daemon-reload
for worker in action-jobs ai-runs ai-run-prune domain-outbox domain-notifications domain-reconcile; do systemctl enable --now "bojiclub-$worker.timer"; done
systemctl enable --now bojiclub-account-deletions.timer
systemctl reload "$php_service"
systemctl reload nginx
echo 'Boji Club account service deployed.'
