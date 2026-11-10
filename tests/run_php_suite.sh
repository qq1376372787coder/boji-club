#!/usr/bin/env bash
# Run the PHP rule/SQL suites against an isolated MySQL instance.
# Requirements: PHP 8.3+ with pdo_mysql, a disposable MySQL/MariaDB server.
#   BOJI_TEST_DSN_BASE='mysql:host=127.0.0.1;port=13306' \
#   BOJI_TEST_DB_USER=root BOJI_TEST_DB_PASSWORD='' tests/run_php_suite.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PHP="${PHP:-php}"
: "${BOJI_TEST_DSN_BASE:?set BOJI_TEST_DSN_BASE, e.g. mysql:host=127.0.0.1;port=13306}"
export BOJI_TEST_DSN_BASE
# Keep the platform OpenSSL default on Linux; a macOS path breaks EC keygen.
if [ -z "${OPENSSL_CONF:-}" ] && [ -f /System/Library/OpenSSL/openssl.cnf ]; then
  export OPENSSL_CONF=/System/Library/OpenSSL/openssl.cnf
fi
BASE="${BOJI_TEST_DSN_BASE%;}"
DBS=(bojiclub_repair_v2_test bojiclub_repair_v4_test_20261002 bojiclub_repair_v17_test_20261004 bojiclub_media_test bojiclub_automation_test boji_membership_v70_test bojiclub_app_config_test bojiclub_ai_conversations_test bojiclub_it)
"$PHP" -r '
require "tests/php_test_bootstrap.php";
$base=getenv("BOJI_TEST_DSN_BASE"); $user=getenv("BOJI_TEST_DB_USER")?:"root"; $pass=getenv("BOJI_TEST_DB_PASSWORD")?:"";
$pdo=new PDO($base,$user,$pass,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
foreach (["bojiclub_repair_v2_test","bojiclub_repair_v4_test_20261002","bojiclub_repair_v17_test_20261004","bojiclub_media_test","bojiclub_automation_test","boji_membership_v70_test","bojiclub_app_config_test","bojiclub_ai_conversations_test","bojiclub_outbox_repair_test","bojiclub_timestamp_repair_test","bojiclub_repair_test","bojiclub_ai_runs_test","bojiclub_it"] as $db) {
  $pdo->exec("DROP DATABASE IF EXISTS `$db`"); $pdo->exec("CREATE DATABASE `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
}
foreach (["bojiclub_repair_v2_test","bojiclub_repair_v4_test_20261002","bojiclub_repair_v17_test_20261004","bojiclub_media_test","bojiclub_automation_test","bojiclub_app_config_test","bojiclub_ai_conversations_test","bojiclub_outbox_repair_test","bojiclub_timestamp_repair_test","bojiclub_repair_test","bojiclub_ai_runs_test","bojiclub_it"] as $db) {
  bojiTestSchema(bojiTestDatabase($db),"account-server");
}
' || exit 1
TMPCFG="$(mktemp -t boji-php-config.XXXXXX.php)"
trap 'rm -f "$TMPCFG"' EXIT
cat >"$TMPCFG" <<PHP
<?php
return ['dsn'=>'$BASE;dbname=bojiclub_it;charset=utf8mb4','db_user'=>getenv('BOJI_TEST_DB_USER')?:'root','db_password'=>getenv('BOJI_TEST_DB_PASSWORD')?:'','otp_secret'=>'test-only-otp-secret-0123456789abcdef'];
PHP
OUT="${BOJI_TEST_LOG_DIR:-/tmp/boji-php-suite}"
mkdir -p "$OUT"
: >"$OUT/results.tsv"
fail=0
for file in "$ROOT"/tests/test_*.php; do
  name="$(basename "$file" .php)"
  args=()
  env_db=""
  case "$name" in
    test_ai_stability_sql|test_repair_v48_sql) args=("$TMPCFG") ;;
    test_membership_verify_db_v70) env_db="$BASE;dbname=boji_membership_v70_test;charset=utf8mb4" ;;
    test_account_v4) env_db="bojiclub_repair_v4_test_20261002" ;;
    test_account_v2|test_account_regression) env_db="bojiclub_repair_v2_test" ;;
    test_repair_v17) env_db="bojiclub_repair_v17_test_20261004" ;;
  esac
  if [ "$name" = "test_membership_verify_db_v70" ]; then
    BOJI_V70_TEST_DSN="$env_db" "$PHP" "$file" >"$OUT/$name.log" 2>&1
  elif [ -n "$env_db" ]; then
    BOJI_TEST_DB="$env_db" "$PHP" "$file" >"$OUT/$name.log" 2>&1
  elif [ ${#args[@]} -gt 0 ]; then
    "$PHP" "$file" "${args[@]}" >"$OUT/$name.log" 2>&1
  else
    "$PHP" "$file" >"$OUT/$name.log" 2>&1
  fi
  status=$?
  if [ $status -eq 0 ]; then echo -e "$name\tPASS" >>"$OUT/results.tsv"; else echo -e "$name\tFAIL:$status" >>"$OUT/results.tsv"; fail=$((fail+1)); fi
done
echo "PHP suites: $(grep -c PASS "$OUT/results.tsv") passed, $fail failed. Logs: $OUT"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
