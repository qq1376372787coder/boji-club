#!/usr/bin/env bash
# Only the validated sync contract is replaced; no user data or database migration.
set -Eeuo pipefail
root=${BOJI_ACCOUNT_ROOT:-/opt/bojiclub-account}
candidate=${1:-$root/.experience-cloud-validation.php}
test_file=${2:-$root/.experience-plan-test.php}
expected=6330b78b8d4256b181966a10825ee8bc5edeb42e840f2c3bb85533c2e7a6a448
live="$root/public/cloud-validation.php"
php -l "$candidate"
BOJI_TEST_CLOUD_VALIDATION="$candidate" php "$test_file"
current=$(sha256sum "$live" | cut -d' ' -f1)
next=$(sha256sum "$candidate" | cut -d' ' -f1)
if [ "$current" = "$next" ]; then echo ALREADY_DEPLOYED; exit 0; fi
if [ "$current" != "$expected" ]; then echo 'Live source changed; deployment stopped before replacement.' >&2; exit 1; fi
backup="$root/.backups/experience-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
chmod 700 "$backup"
cp -p "$live" "$backup/cloud-validation.php"
trap 'cp -p "$backup/cloud-validation.php" "$live"; systemctl reload php-fpm; echo ROLLED_BACK >&2' ERR
install -m 0644 "$candidate" "$root/public/.cloud-validation.upgrade.php"
mv "$root/public/.cloud-validation.upgrade.php" "$live"
php -l "$live"
systemctl reload php-fpm
printf 'DEPLOYED_SHA256 %s\nBACKUP %s\n' "$next" "$backup/cloud-validation.php"
