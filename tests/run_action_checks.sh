#!/usr/bin/env bash
# Only run against a disposable MySQL instance. Does not run UI/video or contact providers.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BOJI_TEST_DSN_BASE:?Set a disposable MySQL DSN}"
PHP="${PHP:-php}"
"$PHP" -r '
require "tests/php_test_bootstrap.php";
$db=new PDO(getenv("BOJI_TEST_DSN_BASE"),getenv("BOJI_TEST_DB_USER")?:"root",getenv("BOJI_TEST_DB_PASSWORD")?:"",[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$db->exec("DROP DATABASE IF EXISTS bojiclub_it");$db->exec("CREATE DATABASE bojiclub_it CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
bojiTestSchema(bojiTestDatabase("bojiclub_it"),"account-server");'
for suite in training_commands ai_router domain_projections action_system_repair action_migration ai_runs_kinds; do "$PHP" "tests/test_$suite.php"; done
python3 -m unittest discover -s tests -p test_capability_calls.py
