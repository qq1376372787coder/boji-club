# MIGRATION AND ROLLBACK

## 1. Additive changes

| Object | Change |
|---|---|
| `ai_runs` | new (durable Run, lease, attempts, trace, `event_floor`) |
| `ai_run_events` | new (`(run_id, seq)` PK, unique `event_id`, cascade) |
| `ai_runs.event_floor` | new, default 1 |
| `ai_runs_cleanup` | new index `(status, updated_at)` |
| `ai_runs_client` | unique `(user_id, client_message_id)` |
| `ai_usage_ledger.trace_id` | nullable |
| `ai_action_proposals.trace_id` | nullable |
| `data_operations.trace_id` | nullable |
| `ai_action_messages.trace_id` | nullable |
| `ai_action_calls.trace_id` | nullable |
| `domain_outbox.trace_id` | nullable |
| `user_action_preferences.proactive_learning` | new boolean default true |

No DROP, no enum narrowing, no business fact rewrite. No new authoritative plan/session tables.

## 2. Apply / verify

```bash
export BOJI_MIGRATION_DSN="mysql:host=...;dbname=...;charset=utf8mb4"
export BOJI_MIGRATION_USER=... BOJI_MIGRATION_PASSWORD=...
php account-server/migrate-v2-repair.php --apply
php account-server/migrate-v2-repair.php --check   # expect missing=[] compatible=true exit 0
php account-server/migrate-v2-repair.php --apply   # repeat is a no-op
```

Local MySQL 8.4 result:
- normal schema: apply/check exit 0; repeat apply 0.
- drop any new column/index or narrow `ai_action_proposals.kind`: check exit 1 with exact item; apply restores; check 0.
- `--check` still emits legacy `missing_tables` alias (same list) for older test contracts.

## 3. Deploy order

1. Backup DB/config; stop/keep `ai_streaming_v2=false`.
2. Run migration (DDL maintenance account); run `--check`.
3. Deploy account-server + backend + worker; install `bojiclub-ai-runs.timer`.
4. Keep flag off; run `tests/run_ai_runs.sh` and HTTP probe in isolation.
5. Enable for an internal account; verify create/replay/409/404/cancel/SSE/410.
6. Only then gray release.

## 4. Rollback

1. Publish `ai_streaming_v2=false`; clients fall back to polling.
2. Disable `bojiclub-ai-runs.timer`; leases expire; no new runs.
3. Revert code. **Keep new tables/columns and completed rows**; do not DROP or restore old full-state snapshots while new rows exist.
4. Event logs may be pruned by `php account-server/prune-ai-runs.php 30`; Run rows/results remain for snapshot recovery.
5. For disaster recovery only: restore pre-deploy backup with app stopped; no ad-hoc destructive SQL.

## 5. Test DBs

The PHP suite creates/drops its own databases; `tests/test_ai_runs.php`, `test_worker_context.php`, `test_trace_chain.php`, `test_intelligence_closure.php` create their own DBs. No production data is used.
