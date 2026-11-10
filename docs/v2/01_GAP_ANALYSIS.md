# Phase 0 · 差距分析（GAP_ANALYSIS）

目标：把 01–06 规格的每条能力映射到真实代码，标出“已有 / 部分 / 缺失”，并给出最小复用策略。状态口径：`HAVE`、`PARTIAL`、`MISSING`。

| # | 目标模块 | 现有能力（证据） | 差距 | 复用策略 | 风险/复杂度 |
|---|---|---|---|---|---|
| G1 | SSE Run（POST + GET events + snapshot + cancel） | 无。全仓 `grep -r "text/event-stream"` 零命中；AI 为同步 JSON 代理 + 轮询（`AIService.swift:704-790`、`weekly.php:77`） | 协议、持久 Run、seq 事件日志、重连、去重、客户端解析全缺 | 在现有 `ai_conversations/ai_messages` 旁新增 `ai_runs/ai_run_events`；复用 `aiJobID`、`aiCoachTurnComplete`、卡片 envelope；客户端新增 `AIRunStream`，完成结果注入现有 `AILocalJob` 复用原渲染 | 中高；PHP 无可执行运行时，客户端需 fallback |
| G2 | 能力注册表 / Intent Router | `capability-registry.php`（15 能力、5 模式）、`ai-router.php`、`command_type` 映射 | 无 fitness/nutrition 计算能力；无 trace | 新增 `fitness.*`、`nutrition.compute` 只读/建议能力，调用内部 Python 引擎 | 中 |
| G3 | 提案 / 命令 / 幂等 | `ai_action_proposals`、`data_operations` 唯一 `(user_id,idempotency_key)`、`lockActiveUser`、CAS | 提案过期/冲突/撤销已做；缺 trace 关联 | 加 `trace_id`（可空）贯穿 proposal/command/outbox/usage | 低 |
| G4 | Outbox / 消费去重 / 对账 | `domain_outbox`、`domain_consumer_inbox`、`process-domain-outbox.php`、`reconcile-domain-outbox.php` | 无后台 backlog 视图/告警 | 新增管理员只读聚合端点/页面 | 低 |
| G5 | 训练/日程/饮食/体重真实联动 | 文档 + 分片 + 命令 + 提案 + 离线队列（`AppStore.swift` 队列、`action-sync.php`） | SSE 未接入；离线状态展示已有 | 以适配层接入 SSE，不改写业务 | 中 |
| G6 | Fitness Intelligence | `adaptive_core.py` 渐进建议、`weekly_core.py` 就绪度、`aiRouterAdvice` 关键词分流 | 无 variant/负重口径模型；无结构化 SafetyTriage；无覆盖度特征对象 | Python 新增 `fitness_intelligence.py`：canonical/variant 分组、可比性、窗口特征、红旗分流、渐进建议（仅建议）；PHP 能力经内部 HTTP 调用 | 中 |
| G7 | Nutrition Engine | `food_core.py` 单位/整份一致性；`ai-proposals.php` 草稿；图片识别异步 | 无 per-100g 计算、可食质量、来源优先级、估算区间 | Python 新增 `nutrition_engine.py`，暴露 `nutrition.compute` 只读能力；不改变现有草稿字段语义 | 中 |
| G8 | Personal Intelligence | `ai-memory.php`（kind/status/evidence/supersedes）、`insights.php`（去重/评分）、`ClubInsightRules.swift` | 无全局频控/冷却；无统一排序契约 | Python 新增 `personal_intelligence.py`（排序/冷却/证据门槛），PHP 洞察分发调用；不删除现有记忆表 | 中低 |
| G9 | Trust & Reliability | 事务、幂等、版本、提案、Outbox、租约、故障注入测试 | 无 trace、无统一错误码映射文档、无健康数据删除传播的端到端证据 | 加 trace/错误码；补测试矩阵（可运行部分） | 中 |
| G10 | AI Operations Center | 后台模型/任务/容量、`ai_usage_ledger` | 无 trace 检索、无 backlog/成本聚合、无告警阈值文件 | 新增只读聚合端点 + 后台页面 + `OPS_RUNBOOK` 阈值 | 中 |
| G11 | Golden Evals | 无数据集/门禁 | 100–200 条意图集、确定性评测、报告 | 新增 `tests/golden/*.jsonl` + `run_golden_evals.py`，对 `intent_router`/`capability` 契约评测；真实模型评测标记未验证 | 中 |
| G12 | UI 冻结回归 | 现有 UI 已验收；`BojiClubUITests` 覆盖 shell/侧栏/记录 | 无像素基线自动化 | 源码哈希 + 模拟器截图 + UITest 截图；变更例外清单 | 低 |

## 优先级与执行顺序（风险最小化）

1. **P0 安全基座**：trace + 幂等/Outbox 现状核查 + 可运行测试（Python/Swift）。
2. **P1 SSE**：服务端持久 Run（PHP，静态审查+测试脚本）+ iOS 客户端（真实测试，Python 假 SSE 服务端联调）+ 最小 UI 接线（feature flag + 失败回退现有轮询）。
3. **P2 确定性引擎**：Fitness / Nutrition / Personal（Python，真实单测）+ 只读能力接线（PHP）。
4. **P3 运维与评测**：后台 backlog/成本聚合 + Golden Evals + 回归证据。
5. **P4 交付**：报告、ZIP、SHA256、独立审计交接。

## 明确不做（避免越界）

- 不重建首页/侧栏/顶部切换/输入框/训练与记录页。
- 不新建平行业务表替代 `app_states`/`data_operations`。
- 不接入生产数据库、不部署、不上传 TestFlight、不为验证而调用真实付费模型。
- 不把 Mock/静态夹具当作真实联动证据。
