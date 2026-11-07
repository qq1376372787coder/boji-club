#!/usr/bin/env bash
# Run the PHP rule/SQL suites against an isolated MySQL instance.
# Requirements: PHP 8.3+ with pdo_mysql, a disposable MySQL/MariaDB server.
#   BOJI_TEST_DSN_BASE='mysql:host=127.0.0.1;port=13306' \
#   BOJI_TEST_DB_USER=root BOJI_TEST_DB_PASSWORD='' tests/run_php_suite.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -f account-server/config.php ]; then echo "Use an unconfigured isolated checkout; refusing configured checkout" >&2; exit 2; fi
PHP="${PHP:-php}"
: "${BOJI_TEST_DSN_BASE:?set BOJI_TEST_DSN_BASE, e.g. mysql:host=127.0.0.1;port=13306}"
export BOJI_TEST_DSN_BASE
# migrate-ai-context.php 通过 BOJI_MIGRATION_* 取凭据；本地 QA 走免密 socket
# 从未暴露，CI 是 TCP + fixture-only 密码 → Access denied（首跑静默 exit 1 根因）。
export BOJI_MIGRATION_USER="${BOJI_TEST_DB_USER:-root}"
export BOJI_MIGRATION_PASSWORD="${BOJI_TEST_DB_PASSWORD:-}"
OUT="${BOJI_TEST_LOG_DIR:-/tmp/boji-php-suite}"
mkdir -p "$OUT"
# Own this deterministic-only service; do not silently use an unrelated listener.
python3 -I tests/intelligence_fixture_server.py >"$OUT/rules-service.log" 2>&1 &
RULES_PID=$!
cleanup() { kill "$RULES_PID" 2>/dev/null || true; if [ -n "${TMPCFG:-}" ]; then rm -f "$TMPCFG"; fi; }
trap cleanup EXIT
ready=0
for attempt in {1..30}; do
  if ! kill -0 "$RULES_PID" 2>/dev/null; then cat "$OUT/rules-service.log" >&2; exit 1; fi
  if grep -q RULES_FIXTURE_READY "$OUT/rules-service.log"; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then echo "Rules fixture startup failed" >&2; exit 1; fi
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
foreach (["bojiclub_repair_v2_test","bojiclub_repair_v4_test_20261002","bojiclub_repair_v17_test_20261004","bojiclub_media_test","bojiclub_automation_test","boji_membership_v70_test","bojiclub_app_config_test","bojiclub_ai_conversations_test","bojiclub_outbox_repair_test","bojiclub_timestamp_repair_test","bojiclub_repair_test","bojiclub_ai_runs_test","bojiclub_it","boji_build122_check","boji_experience130_test","boji_experience131_test"] as $db) {
  $pdo->exec("DROP DATABASE IF EXISTS `$db`"); if(!in_array($db,["boji_experience130_test","boji_experience131_test"],true))$pdo->exec("CREATE DATABASE `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
}
foreach (["bojiclub_repair_v2_test","bojiclub_repair_v4_test_20261002","bojiclub_repair_v17_test_20261004","bojiclub_media_test","bojiclub_automation_test","bojiclub_app_config_test","bojiclub_ai_conversations_test","bojiclub_outbox_repair_test","bojiclub_timestamp_repair_test","bojiclub_repair_test","bojiclub_ai_runs_test","bojiclub_it","boji_build122_check"] as $db) {
  bojiTestSchema(bojiTestDatabase($db),"account-server");
}
' || exit 1
TMPCFG="$(mktemp -t boji-php-config.XXXXXX.php)" || { echo "php-suite stage FAIL: mktemp TMPCFG" >&2; exit 1; }
[ -n "$TMPCFG" ] && [ -f "$TMPCFG" ] || { echo "php-suite stage FAIL: TMPCFG empty" >&2; exit 1; }
echo "== php-suite stage: config fixture ok =="
cat >"$TMPCFG" <<PHP
<?php
return ['dsn'=>'$BASE;dbname=bojiclub_it;charset=utf8mb4','db_user'=>getenv('BOJI_TEST_DB_USER')?:'root','db_password'=>getenv('BOJI_TEST_DB_PASSWORD')?:'','otp_secret'=>'test-only-otp-secret-0123456789abcdef'];
PHP
: >"$OUT/results.tsv"
fail=0
# Prepare the dedicated audit fixture through its real CLI, not a blank schema.
"$PHP" -r '$db=new PDO(getenv("BOJI_TEST_DSN_BASE"),getenv("BOJI_TEST_DB_USER")?:"root",getenv("BOJI_TEST_DB_PASSWORD")?:"");$db->exec("DROP DATABASE IF EXISTS boji_audit129_test");' \
  || { echo "php-suite stage FAIL: audit129 drop" >&2; exit 1; }
# CI 首跑在以下三步静默 exit 1（输出全进日志文件，runner 没了日志就没了）：
# 现在每步打 stage 标记，失败即把日志回灌 stderr。
echo "== php-suite stage: migrate ai-context (bojiclub_it) =="
BOJI_MIGRATION_DSN="$BASE;dbname=bojiclub_it" "$PHP" account-server/migrate-ai-context.php --apply >"$OUT/context-prepare.log" 2>&1 \
  || { echo "--- context-prepare.log (bojiclub_it) ---" >&2; cat "$OUT/context-prepare.log" >&2; echo "php-suite stage FAIL: migrate ai-context bojiclub_it" >&2; exit 1; }
echo "== php-suite stage: migrate ai-context (boji_build122_check) =="
BOJI_MIGRATION_DSN="$BASE;dbname=boji_build122_check" "$PHP" account-server/migrate-ai-context.php --apply >>"$OUT/context-prepare.log" 2>&1 \
  || { echo "--- context-prepare.log (boji_build122_check) ---" >&2; tail -50 "$OUT/context-prepare.log" >&2; echo "php-suite stage FAIL: migrate ai-context boji_build122_check" >&2; exit 1; }
echo "== php-suite stage: audit129 prepare =="
"$PHP" tests/test_audit129_sql.php prepare >"$OUT/audit129-prepare.log" 2>&1 \
  || { echo "--- audit129-prepare.log ---" >&2; cat "$OUT/audit129-prepare.log" >&2; echo "php-suite stage FAIL: audit129 prepare" >&2; exit 1; }
echo "== php-suite stage: fixtures ready, running suites =="
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
