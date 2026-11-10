#!/usr/bin/env bash
# Ordinary checks for the AI onboarding V2 delivery (Build 118).
# This is deliberately NOT the independent acceptance suite.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$ROOT/delivery/basic-check-logs"
mkdir -p "$LOGS"
cd "$ROOT"
status=0

echo "== baseline ==" | tee "$LOGS/run-summary.log"
if [ -f "$ROOT/../_baseline_zip/BOJI_CLUB_V2_Build117_SOURCE_20261025.zip" ]; then
  shasum -a 256 "$ROOT/../_baseline_zip/BOJI_CLUB_V2_Build117_SOURCE_20261025.zip" | tee -a "$LOGS/run-summary.log"
elif [ -n "${BOJI_BASELINE_ZIP:-}" ]; then
  shasum -a 256 "$BOJI_BASELINE_ZIP" | tee -a "$LOGS/run-summary.log"
else
  echo "baseline zip not supplied; expected sha256 0c761f6a82154a0ea4b1b095441c4dff95b918f3561d35bb884bdf7dd5f753cb" | tee -a "$LOGS/run-summary.log"
fi

echo "== python compile ==" | tee -a "$LOGS/run-summary.log"
python3 -m py_compile backend/ai_core.py backend/coach_core.py backend/onboarding_core.py > "$LOGS/py-compile.log" 2>&1 || status=1

echo "== python onboarding tests ==" | tee -a "$LOGS/run-summary.log"
python3 tests/test_onboarding_v2_contract.py > "$LOGS/python-onboarding-tests.log" 2>&1 || status=1

echo "== json / schema ==" | tee -a "$LOGS/run-summary.log"
python3 - <<'PY' > "$LOGS/json-schema.log" 2>&1 || status=1
import json
try:
    import jsonschema
except ImportError:
    jsonschema = None
base = 'shared/schemas/'
schema = json.load(open(base + 'onboarding-coach-output.v1.schema.json'))
sample = json.load(open(base + 'onboarding-coach-output.v1.example.json'))
if jsonschema:
    jsonschema.validate(sample, schema)
content_schema = json.load(open(base + 'onboarding-content.v1.schema.json'))
if jsonschema:
    jsonschema.validate({'welcome_title':'今天，想先做什么？','welcome_body':'选一件小事开始','task_labels':{'plan_create':'帮我安排训练'},'tips':[]}, content_schema)
json.load(open('shared/prompts/PROMPT_VERSION.json'))
print('JSON_SCHEMA_OK' if jsonschema else 'JSON_PARSE_OK (jsonschema not installed)')
PY

echo "== php syntax ==" | tee -a "$LOGS/run-summary.log"
if command -v php >/dev/null 2>&1; then
  for f in account-server/public/profile-facts.php account-server/public/onboarding-v2.php account-server/public/task-center.php \
           account-server/public/context-continuation.php account-server/public/export.php account-server/public/ai-runs.php \
           account-server/public/weekly.php account-server/public/index.php account-server/public/ai-entitlements.php \
           account-server/public/app-config.php account-server/process-ai-runs.php account-server/migrate-onboarding-v2.php; do
    php -l "$f" >> "$LOGS/php-lint.log" 2>&1 || status=1
  done
else
  echo "php not installed; php -l NOT_RUN_ENV_BLOCKED" | tee -a "$LOGS/run-summary.log"
  python3 scripts/php_parse_check.py \
    account-server/public/profile-facts.php account-server/public/onboarding-v2.php account-server/public/task-center.php \
    account-server/public/context-continuation.php account-server/public/export.php account-server/public/ai-runs.php \
    account-server/public/weekly.php account-server/public/index.php account-server/public/ai-entitlements.php \
    account-server/public/app-config.php account-server/public/action-execution.php account-server/public/ai-memory.php \
    account-server/process-ai-runs.php account-server/migrate-onboarding-v2.php account-server/admin/index.php \
    account-server/admin/bootstrap.php > "$LOGS/php-parse.log" 2>&1 || status=1
fi

echo "== iOS build/test (optional flags) ==" | tee -a "$LOGS/run-summary.log"
if [ "${BOJI_RUN_IOS_BUILD:-0}" = "1" ]; then
  xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
    -destination 'platform=iOS Simulator,id=FBA6FD7F-4750-48FD-A915-4907A88ED2CA' \
    -derivedDataPath /tmp/boji-dd CODE_SIGNING_ALLOWED=NO build > "$LOGS/ios-build.log" 2>&1 || status=1
  xcodebuild test -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
    -destination 'platform=iOS Simulator,id=FBA6FD7F-4750-48FD-A915-4907A88ED2CA' \
    -derivedDataPath /tmp/boji-dd CODE_SIGNING_ALLOWED=NO -only-testing:BojiClubTests > "$LOGS/ios-unit-tests.log" 2>&1 || status=1
else
  echo "BOJI_RUN_IOS_BUILD != 1; iOS build/test skipped by flag" | tee -a "$LOGS/run-summary.log"
fi

echo "exit=$status" | tee -a "$LOGS/run-summary.log"
exit "$status"
