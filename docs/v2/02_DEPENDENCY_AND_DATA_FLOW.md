# Phase 0 · 依赖与数据流（DEPENDENCY_AND_DATA_FLOW）

## 1. 跨模块写入路径

```
iOS 原生入口（训练/饮食/体重/计划）
  └─ AppStore / 领域 Store
       ├─ 本地优先：队列 + 幂等 UUID（AppStore.swift、RecordReliability.swift）
       └─ 云端：/me/ai/jobs（AI）或 /me/commands、/me/sync/parts（业务）
                         │
                         ▼
              account-server/public/index.php
                ├─ authenticated() + membership/consent
                ├─ handleBusinessCommandCore()  ◄── AI 提案确认（action-proposals/{id}/confirm）
                │     ├─ lockActiveUser() 行锁
                │     ├─ data_operations 幂等（operation_id / idempotency_key）
                │     ├─ 读取 app_states + 日期分片，校验 _schedule_version / 提案 _expected_days
                │     ├─ 领域变更（businessMoveSchedule / 训练集合 / 餐食 / 测量）
                │     ├─ 写 data_operations（审计 + 逆载荷）
                │     └─ 写 domain_outbox（同事务）
                └─ ai-router.php：模型能力只读/建议/预览/直执行/异步
                         │ 内部 loopback + APP_TOKEN
                         ▼
              backend/server.py（Python）
                ├─ 任务库（SQLite）：jobs / 租约 / 重试
                ├─ ai_core.Router：供应商选择、超时、降级、JSON 校验
                ├─ coach_core / intent_router / food_core / adaptive_core
                └─ 返回结构化结果（answer/cards/capability_calls）
                         │
                         ▼
              iOS 轮询 /me/ai/jobs → AILocalJob → ClubCoachView 渲染
              account-server 写 ai_messages / ai_message_cards（服务端会话副本）
                         │
                         ▼
              domain_outbox worker → 消费者（记忆/通知/成长季/首页洞察）
```

## 2. 权威性判定

| 数据 | 权威 | 客户端缓存 | 说明 |
|---|---|---|---|
| 训练组数/完成 | `app_states.days[date].exercises[].sets[]` + `workoutSessions` | `AppStore.state` 本地副本 | 本地先写，服务端按命令合并；冲突以版本/指纹判定 |
| 计划模板 | `days[].planCycle` + 计划版本映射 | 同上 | 历史 Session 不随计划移动 |
| 日程 | `days[date]` + `_schedule_version` | 同上 | 改期会复制动作并生成新 ID，源日清空 |
| 餐食 | `days[date].meals` | 同上 | 草稿在 `ai_action_proposals`，确认后才写正式餐食 |
| 体重 | `days[date].bodyMeasurements` | 同上 | 同日多笔 + 墓碑 |
| AI 会话 | `ai_conversations/ai_messages` | iOS 本地 `AILocalJob` 文件 | 两者目前未合并读；本轮保持 |
| 提案/命令 | `ai_action_proposals` / `data_operations` | 结果快照 | 客户端只提交 `proposal_id`，服务端重校验 |

## 3. 门禁问题：把“周四训练改到周六”会发生什么？

**用户操作**：AI 预览 → 用户确认（或手动顺延预览确认）。

1. **预览**：`schedule.preview_change` → `aiRouterPreview()`（`ai-router.php:394`）→ `aiProposalCreate()` 保存 `kind=plan_change_proposal`、`moves:[{from,to}]`、`_expected_days` 指纹、`expires_at`、`status=awaiting_confirmation`。**不写业务文档**。
2. **确认**：`POST /me/ai/proposals/{id}/confirm` → `handleBusinessCommandCore(type=PlanReschedule.Confirm)`（`commands.php:561`）。
3. **事务内写入**：
   - `ai_action_proposals.status → succeeded`（终态幂等，重复确认返回同一命令）。
   - `businessMoveSchedule()`（`business-state.php:72`）：
     - 周四 `days[from].exercises = []`（清空安排，保留当日其他记录）；
     - 周六 `days[to].exercises` 复制为新 ID、`completed=false`、新 `workoutSessionID`，`movedFromDate=from`；
     - `days[to]._schedule_version += 1`；必要时创建/继承 `planCycle`；
     - 已完成的历史 `workoutSessions` 不移动（仅复制计划，不复制完成事实）。
   - `data_operations`：`operation_id=commandId`、`payload_hash`、`after_version`、`diff`（moves + 前后日程版本）。
   - `domain_outbox`：`PlanRescheduled` 事件（供记忆/通知/成长季/洞察消费者）。
4. **返回**：最新 revision + day versions；iOS 通过共享 Store 刷新 Club AI/训练/日历。

**手动 vs AI 是否共用入口**：是。手动顺延最终也调用同一 `/me/commands`（`PlanReschedule.Confirm` 或 `Schedule.Move`），AI 只多一层“提案 + 用户确认”。分片/整包兼容适配器（`action-sync.php`、`cloud-parts.php`）同样经过 `data_operations`/`domain_outbox` 与账号锁，不存在第二条静默写入路径。

**代码定位**：
- 提案创建：`account-server/public/ai-router.php:394-428`
- 确认与事务：`account-server/public/commands.php:30-150`、`:561-593`
- 日程变更：`account-server/public/business-state.php:72-130`
- 客户端确认：`BojiClub/ClubProposalSync.swift:220`、`BojiClub/ClubCoachView.swift:201-240`

## 4. 离线与同步

- 本地队列：`AppStore.swift`（命令队列、重试计数持久化、账号切换隔离）。
- 分片同步：`cloud-parts.php` / `action-sync.php`；活动训练预检在合并 override 后执行（Build116 AS-19）。
- 训练组：`client_operation_id` / `set_id` 防重；结束训练走提案快照校验（`Training.FinishConfirm`）。
- 状态语义：`local_saved → syncing → synced / needs_resolution / failed_retryable`（`RecordReliability.swift`）。

## 5. 本轮新增数据流（SSE）

```
iOS POST /me/ai/conversations/{cid}/runs  (Idempotency-Key = client_message_id)
  → ai_runs (running, trace_id) + run.created(seq=1)
  → process-ai-runs.php 领取（lease）
      → 调用 Python /v1/jobs（kind=coach，沿用能力白名单）
      → 逐条追加 ai_run_events（seq 单调）：
         run.status / tool.started / tool.completed /
         assistant.text.delta（校验后分块投递）/ card.upsert /
         usage.summary / run.completed
      → 写 ai_messages + ai_message_cards（复用 aiCoachTurnComplete）
  ← iOS GET /me/ai/runs/{id}/events?after_seq=N  (SSE)
  ← 断线：Last-Event-ID / after_seq；日志过期：GET /runs/{id} 快照 → 410 RESYNC_REQUIRED
```

SSE 只承载“进度与已校验文本”，不授予任何写权限；卡片确认仍走提案确认端点。
