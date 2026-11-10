# Phase 0 · 迁移、灰度与回滚计划（MIGRATION_PLAN）

## 1. 原则

- **expand-only**：只新增表/列/索引，不删除、不收窄枚举、不回填旧整包。
- 所有新能力有服务端 feature flag；写权限默认关闭或保持现有值。
- 迁移可重复执行；`--check` 发现漂移返回非零。
- 生产应用需人工批准；本轮仅提供脚本与隔离验证步骤，不连接生产。

## 2. 本轮新增迁移（文件级）

### `account-server/migrations/20261025-ai-runs.sql`（新增）

- `ai_runs`：持久 Run（user/conversation/client_message_id/message_id/status/last_seq/request/result/error/trace/lease/attempts/timestamps）。
  - 唯一键 `(user_id, client_message_id)`：POST 重试返回同一 Run。
  - FK `user_id → users(id) ON DELETE CASCADE`：账号删除清理。
- `ai_run_events`：`(run_id, seq)` 主键、`event_id` 唯一；FK 级联删除。
- `ai_usage_ledger` 增加 `trace_id CHAR(32) NULL` + 索引（可空，旧行不受影响）。
- `ai_action_proposals` 增加 `trace_id CHAR(32) NULL`（可空）。
- `data_operations` 增加 `trace_id CHAR(32) NULL`（可空）。

回滚：停止写入（flag off + 停 worker）→ 代码回退；**不 DROP 表/列**。需要灾备时按备份恢复。

### 修改 `account-server/public/app-config.php`

新增 flag：
- `ai_streaming_v2`（bool，默认 `false`）：关闭时 Run 端点返回 503，客户端回退现有轮询。
- `ai_write_commit`（bool，默认 `false`）：显式网关，本轮不改现有 `direct_records`/`training_commands` 语义。

### 部署顺序（人工执行）

1. 备份数据库与 `config.php`；暂停 action-jobs timer。
2. `php migrate-v2-repair.php --apply`（含新迁移）；`--check` 必须 `SCHEMA_OK`。
3. 部署 `account-server`（含新 `ai-runs.php`、`process-ai-runs.php`）与 `backend`。
4. 安装 `bojiclub-ai-runs.service/timer`（每 5–10 秒）。
5. 保持 `ai_streaming_v2=false` 观察；内部账户开启验证后再灰度。
6. 回滚：flag off → 停 ai-runs timer → 回退代码 → 保留数据。

## 3. 兼容性

| 面 | 影响 | 处理 |
|---|---|---|
| 旧客户端 | 不调用新端点 | 无影响 |
| 新客户端 + 旧服务端 | POST run 404/503 | 客户端自动回退现有 `/me/ai/jobs` |
| 新客户端 + 新服务端，flag off | 503 | 同上 |
| 旧 AI 轮询链 | 不改协议 | 保留 |
| 卡片 schema | 新增字段可忽略 | `AICards` 未知类型降级 |

## 4. 数据迁移

无需迁移旧计划/训练/餐食/体重数据：
- 计划/日程/训练事实继续使用 `app_states` 文档与分片；
- 新表只承载 Run/事件与可空 trace 列；
- 不存在双写两份权威计划。

## 5. 回滚演练（隔离环境）

```bash
# 1. 迁移前快照
mysqldump --single-transaction bojiclub_it > /tmp/boji_before.sql
# 2. 应用
BOJI_MIGRATION_DSN=... php account-server/migrate-v2-repair.php --apply
BOJI_MIGRATION_DSN=... php account-server/migrate-v2-repair.php --check   # 期望 0
# 3. 旗标关闭后验证旧路径
curl -s -o /dev/null -w '%{http_code}' -X POST .../me/ai/conversations/x/runs   # 期望 503
# 4. 恢复（仅灾备）
mysql bojiclub_it < /tmp/boji_before.sql
```

> 本机无 MySQL/PHP，以上未执行；命令已写入 `BLOCKED_ACTIONS.md`。
