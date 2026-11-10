# TEST RESULTS — final fix run

Environment: PHP 8.3.12 (pdo_mysql, mbstring, filter, ctype; **no openssl**), MySQL 8.4.0 isolated socket, Python 3.9.6, Xcode 26.6 / iOS 26.5 simulator.

| # | Command | Exit | Result | Evidence |
|---|---|---|---|---|
| 1 | `python3 tests/run_offline.py` | 0 | **722 tests OK** | `evidence/python_722.log` |
| 2 | `python3 tests/run_golden_evals.py` | 0 | 120/120 intent, 120/120 safety, 10/10 adversarial, 0 failures | `evidence/golden.log` |
| 3 | `python3 tests/test_intelligence_engines.py` | 0 | 34/34 | included in #1 |
| 4 | `xcodebuild Debug build` | 0 | **BUILD SUCCEEDED** | `evidence/ios_debug_build.log` |
| 5 | `xcodebuild test -only-testing:BojiClubTests` | 0 | **59/59** | `evidence/xctest_59.log` |
| 6 | 5 frozen-shell UI tests | 0 | **5/5** | `evidence/uitest_5.log` |
| 7 | `xcodebuild Release build` | 0 | **BUILD SUCCEEDED** | `evidence/ios_release_build.log` |
| 8 | `bash tests/run_php_suite.sh` | 1 | **52 passed, 4 failed** | `evidence/php-results.tsv`, `evidence/php-suite-final/` |
| 9 | `php tests/test_ai_runs.php` | 0 | `AI_RUNS_OK` | included in #8 |
| 10 | `php tests/test_worker_context.php` | 0 | `WORKER_CONTEXT_OK` | included in #8 |
| 11 | `php tests/test_trace_chain.php` | 0 | `TRACE_CHAIN_OK` | included in #8 |
| 12 | `php tests/test_intelligence_closure.php` | 0 | `INTELLIGENCE_CLOSURE_OK` | included in #8 |
| 13 | migration `--apply` / `--check` | 0 | compatible=true, missing=[] | terminal / migration evidence |
| 14 | migration negatives (drop trace/event_floor/index, narrow enum) | 1 then 0 | detect drift; apply restores; check 0 | terminal |
| 15 | real HTTP probe (create/replay/header/foreign/cancel/SSE) | — | 202/202/**409**/**404**/200/200 | `evidence/probe-http.json` |
| 16 | stale SSE cursor after prune | — | **410** + resync JSON; current cursor 200 | terminal |
| 17 | two-connection cancel race | — | final `cancelled`; no post-cancel text/completed | `evidence/race_*.log` |
| 18 | cancelled child action | — | `measurement_count=0`, calls=[] | terminal |
| 19 | fresh ZIP extraction | — | Python + Golden pass on extracted source | final ZIP note |

## 8. Remaining PHP failures (all environment)

The four failures all stop at `Call to undefined function openssl_*`:

- `test_account_regression` — `openssl_pkey_new`
- `test_account_v2` — `openssl_encrypt`
- `test_club_push` — `openssl_pkey_new`
- `test_repair_v48` — `openssl_pkey_new`

This PHP runtime has no OpenSSL extension; PHP source and `phpize` are present but `autoconf`/GNU m4 are not, so the extension could not be built locally. These are **BLOCKED_ENV**, not PASS and not claimed as code failures.

## What is not proven

- Real provider token streaming, model quality, tool-selection accuracy, TTFA/TTFB and cost.
- HealthKit add/delete/revoke, APNs delivery, StoreKit sandbox, TestFlight/signing, real device audio/accessibility.
- Production food database and professional review of fitness/nutrition thresholds.
- Ops panel rendering in a browser and outbox recovery drill on production-like data.
