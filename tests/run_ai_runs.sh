#!/usr/bin/env bash
# Durable Run/SSE persistence tests. Requires PHP 8.3 + pdo_mysql and a
# disposable MySQL/MariaDB instance. Never point this at production.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BOJI_TEST_DSN_BASE:?Set a disposable MySQL DSN (mysql:host=127.0.0.1;port=3306)}"
PHP="${PHP:-php}"
"$PHP" tests/test_ai_runs.php
