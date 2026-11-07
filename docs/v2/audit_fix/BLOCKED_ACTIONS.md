# BLOCKED ACTIONS

> 本轮未连接生产、未部署、未付款/调用付费模型、未上传 TestFlight。

## B1. OpenSSL PHP extension (4 test suites)
**Status:** BLOCKED_ENV.
**Evidence:** `undefined function openssl_pkey_new/openssl_encrypt` in `test_account_regression`, `test_account_v2`, `test_club_push`, `test_repair_v48`.
**Why not fixed:** PHP runtime built without openssl; PHP 8.3.12 source and phpize exist, but `autoconf`/GNU m4 are absent; local build attempt stopped at `no acceptable m4`.
**Action:** install OpenSSL-enabled PHP (or build ext with autoconf), then:
```bash
BOJI_TEST_DSN_BASE=... PHP=php bash tests/run_php_suite.sh   # expect 56/56
```

## B2. Real provider token streaming
**Status:** NOT IMPLEMENTED.
**Current:** progress SSE (`run.status/tool.*`) + fully validated `assistant.text.snapshot`; post-hoc 48-char chunking was removed so it cannot be mistaken for token streaming.
**Why:** provider streaming + incremental JSON/answer extraction requires a real provider contract and credentials; no key in this environment.
**Action:** implement `streamChat` in ModelGateway, buffer full JSON for validation, emit only validated answer deltas; test with a fake OpenAI-compatible stream first.

## B3. Real model quality / cost / TTFB
**Status:** UNKNOWN. No provider key; do not cite deterministic Golden as model acceptance.

## B4. HealthKit / APNs / StoreKit / TestFlight / real device
**Status:** UNKNOWN. No device authorization, APNs key, sandbox account or signing identity.
**Action:** run the device checklist in `REQUIREMENT_COMPLETION_MATRIX.md` / release plan on a human-controlled machine.

## B5. Production food database and professional review
**Status:** PARTIAL. `backend/food-catalog.json` is a 12-item fixture; model prompt does not force `per_100g`; fitness/nutrition thresholds await qualified review.
**Action:** replace fixture with licensed food data; keep `expert_approval_required=true` until reviewed.

## B6. Ops panel browser render / recovery drill
**Status:** PARTIAL. SQL backed by real MySQL tests but the admin page was not opened in a browser; outbox dead-letter recovery was not drilled on production-like data.
**Action:** deploy to isolated host, open `admin/?p=ai&trace=<32hex>`, verify Run/message/action/proposal/command/Outbox rows; drill a dead-letter with audited replay.

## B7. Live SSE UI visual verification
**Status:** PARTIAL. 5 frozen-shell UI tests + timeline unit test pass; no real signed-in stream to render.
**Action:** after B2/B4 environment is available, capture small/large text, dark mode, scroll, background/foreground and network-switch behavior.

## B8. MariaDB 10.11
**Status:** UNVERIFIED. Only MySQL 8.4 was run locally. If MariaDB support is claimed, run the same migration/runner on 10.11.
