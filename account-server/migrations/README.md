# 版本化迁移（Build 112 交接补充）

线上是 MariaDB 10.11；本目录与 `migrate-build112-compat.php` 只做**只扩不缩**的变更，不删除业务行。

## 20261018-build112-compat

- `club_automation.paused` / `paused_reason` / `retry_count`
- `club_automation_runs`（执行记录，后台统计与恢复）
- `club_push_settings`（默认 `proactive_daily_limit=1`，仅在缺失时插入）
- `club_push_account_blocks`
- `club_push_budget`
- `ai_user_jobs.kind` 枚举并集保留 `coach`（AUD-021）

执行：

```bash
BOJI_MIGRATION_ROOT=1 php migrate-build112-compat.php --check
BOJI_MIGRATION_ROOT=1 php migrate-build112-compat.php
```

`--check` 发现漂移返回 2；应用只新增缺失项，重复执行无副作用。`deploy.sh` 已在
`migrate-20261001.php` 之后调用本迁移。旧入口 `migrate-20261001.php` 已改为枚举并集，
不再把 `coach` 收窄；仍禁止在未备份、未核对线上分支时直接运行旧部署脚本。

## 隔离验证

2026-10-18 在 MySQL 8.4 隔离库完成：旧 `club_automation` 缺 3 列、缺 4 张表、已有 coach 行；
`--check` 返回 7 项漂移；应用后 7 项补齐；再检查 `SCHEMA_OK`；coach 行仍为 1 条。

## 20261024-ai-conversations (M-1, Phase 2 §2.3)

- `ai_conversations` / `ai_messages` / `ai_message_cards`（服务端会话存储，expand-only）
- 幂等（CREATE TABLE IF NOT EXISTS）；旧客户端不读不写；账号删除经
  `ai_conversations_user_fk ON DELETE CASCADE` 自动清理。
- 回滚 = 回退写入代码（deploy-experience-sync.sh 哈希回滚即停止写入）；按 §3 规则
  表保留不删，历史在重新启用后仍可用。
- 应用前备份：`mysqldump <db>`（三张表为新建，恢复点只需早于首次写入）。
- 写入路径：coach 提交时记 user 轮（幂等键 user+client_job+role）；worker 成功结果
  中转时补 assistant 轮 + 卡片行（重试幂等）；存储失败不阻塞主 AI 链路（仅 error_log，
  日志不含对话内容）。
- 读端点：`GET /me/ai/conversations`、`GET /me/ai/conversations/{id}/messages`
  （全部按认证 user_id 过滤，跨账号返回空）。
- 历史注入：coach 提交时以服务端存储的最近完整对替换 payload.history（≤12 行，
  对齐 worker 校验包络）；无服务端历史时保留客户端自带历史（M-1 前对话继续可用）。

## 20261025-training-commands (Phase 1)

- `active_workout_sessions`（user_id 主键：单活跃训练会话的 DB 级不变式，P0-2）
- `data_operations.idempotency_key` + 唯一键 `data_ops_idem(user_id, idempotency_key)`
  （提案外直接命令的操作级幂等；既有行 key 为 NULL，不冲突）
- expand-only：旧客户端不读不写；回滚 = 停用新命令类型（commands.php 白名单移除即
  恢复旧语义），表可 DROP。
- 应用：`php migrate-v2-repair.php --check` → `--apply` → 再 `--check`
  （该入口已注册本迁移；`tests/run_php_suite.sh` 的隔离 schema 由 schema.sql 建出
  同等结构）。
- 配套：`app_config` 新开关 `training_commands` / `direct_records`（默认 false，
  灰度开放）；`PUT /me/state` 增加单活跃会话守卫（补领/释放/拒绝并行会话）。

## 20261025-ai-capabilities (Phase 2)

- `ai_action_proposals.kind` 扩展 `exercise_swap` / `plan_activation`（追加枚举值）
- `data_operations.undo_json`（直执行记录的逆载荷，供 action.undo 一次性撤销）
- 新端点：`POST /me/ai/resolve`（能力路由，五种处理模式）、`GET /me/ai/actions/{id}`
  （执行状态）、`GET /me/ai/projections`（投影新鲜度）、`POST /me/ai/proposals/{id}/cancel`
- 回滚 = 关闭 `app_config` 的两个开关 + 移除新命令类型；新列/枚举值可保留。

## 20261025-domain-projections (Phase 4)

- `domain_projection_state(user_id, consumer)`：每消费者最后处理事件与计数，用于
  「投影滞后可见」与对账
- 消费者：personal-memory-v1 / notifications-v1 / club-progress-v1 / home-insight-v1
  （收件箱去重沿用 `domain_consumer_inbox`）
- 对账：`php reconcile-domain-outbox.php [--check]`，systemd 单元
  `bojiclub-domain-reconcile.timer`（15 分钟一次）
- 回滚 = 停用新消费者与对账定时器；新表可 DROP。
