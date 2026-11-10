# FINAL FIX REPORT — BOJI CLUB V2.0 Independent Audit Closure

日期：2026-10-25 · 输入源码 SHA256：`43100c27…`（已核验） · 工作区：`/fix`（隔离，未部署）
结论：**13 项审计问题全部有代码修复与定向证据；9 项 VERIFIED，4 项 PARTIALLY VERIFIED。发布仍为 CONDITIONAL，存在未解决的发布阻断。**

## 1. 执行摘要

- 先在隔离 PHP 8.3.12 + MySQL 8.4 环境复现了审计负例：迁移 exit 1、完成先于保存、取消被覆盖、Header 不绑定、红旗漏判、CLI 记忆缺失、食物更名保留旧营养、洞察超额、Run 套件缺依赖。
- 修复后：正常/重复迁移 exit 0，缺列/索引/枚举负例 exit 1 并可 apply 恢复；两连接取消竞态最终 cancelled；取消后工具写入 0；HTTP 同 Header 换 body ID 409；真实 CLI 注入确认记忆；急症/空覆盖不再给正常训练；洞察 2/2 且跨 ID 冷却生效；同一 trace 贯通 Run→消息→行动→提案→命令→Outbox。
- 假 Token 切块已移除：只保留 progress SSE + 校验后 snapshot；真实 provider Token 流明确标为 **NOT IMPLEMENTED**。
- 最终测试：Python 722/722；Golden 0 failures；PHP 52/56（4 项仅缺 OpenSSL 扩展）；XCTest 59/59；UI 5/5；Debug/Release 构建成功。

## 2. 13 项审计问题状态

| ID | 状态 | 一句话 |
|---|---|---|
| IA-01 | VERIFIED | 迁移只对 `kind` 列查枚举；缺列/索引/枚举负例可检测并 apply 修复 |
| IA-02 | VERIFIED | 消息/卡片/终态/完成事件同事务；保存失败置 failed，不再静默丢回答 |
| IA-03 | VERIFIED | lease/status CAS fencing；取消后不再追加事件/执行子行动；完成幂等 |
| IA-04 | VERIFIED | Idempotency-Key = client_message_id；客户端持久化身份，未知结果不换键 |
| IA-05 | VERIFIED | 急症/严重疲劳/空覆盖/真实 freshness 修复；失败时本地安全规则不放宽 |
| IA-06 | VERIFIED | CLI 依赖完整；确认偏好/限制/纠正真实进入上下文 |
| IA-07 | PARTIALLY VERIFIED | 改名失效旧营养、可信重匹配、指纹含营养、密度/来源/区间传递；生产食品库仍缺 |
| IA-08 | PARTIALLY VERIFIED | progression、洞察排序、主动学习开关、记忆策略、补偿提案已接线；营养全链/专家审阅未完成 |
| IA-09 | VERIFIED | live 行固定在排序历史末尾，含结构测试 |
| IA-10 | PARTIALLY VERIFIED | 删除假切块、保留期/410/游标/并发上限已验证；真实 Token 流未实现 |
| IA-11 | VERIFIED | 每日额度在选中时扣减；跨 insight_id 按 kind/subject 冷却 |
| IA-12 | VERIFIED | trace 持久化到消息/行动/提案/命令/Outbox，真实链测试通过 |
| IA-13 | PARTIALLY VERIFIED | Run 套件自洽、真实 migrator、行为断言；52/56，4 项 OpenSSL 环境阻塞 |

## 3. 主要修改（按域）

### 服务端 Run / 持久任务
`ai-runs.php`、`process-ai-runs.php`、`ai-conversations.php`、`action-execution.php`、`action-jobs.php`、`commands.php`：
- 原子完成事务；`aiCoachTurnCompleteTx`；失败不吞；`result_json.coach` 快照恢复。
- lease/status CAS、心跳 owner 校验、终态禁止追加、取消子行动、重复完成幂等。
- Header 绑定、并发上限、`event_floor`/410、`prune-ai-runs.php`、事件保留。
- trace 写入 messages/calls/outbox/proposals；确认时从提案恢复父 trace。

### 迁移 / 测试
`migrate-v2-repair.php`、`schema.sql`、`migrations/20261025-ai-runs.sql`、`php_test_bootstrap.php`、`run_php_suite.sh`、`test_ai_runs.php`、新增 `test_worker_context.php`、`test_trace_chain.php`、`test_intelligence_closure.php`：
- 迁移枚举判断只看 `kind`；新增列/索引 drift 修复；输出保留 `missing`/`missing_tables`。
- 测试自建/清理 DB；真实 migrator；失败注入、取消竞态、重复完成、保留期、并发、补偿、追溯等行为断言。
- 修正 `updatedAt` 测试合同为 reference-epoch number（Swift Date 是 Double），保留原失败历史。

### 智能规则
`backend/fitness_intelligence.py`、`personal_intelligence.py`、`nutrition_engine.py`、`food_core.py`、`ai-router.php`、`insights.php`、`ai-memory.php`：
- 红旗扩展/否定/英文、严重疲劳、空事实询问；PHP 真实覆盖度/freshness。
- 每日上限/跨 ID 冷却；用户记忆优先、AI 不可覆盖用户事实；主动学习开关。
- 可信 food catalog（fixture）、改名重匹配、营养未知/需确认、体积密度、来源/区间/flags 传播。
- `fitness.suggest_progression`、`schedule.preview_compensation` 正式能力与卡片。

### iOS
`AIRunStream.swift`、`ClubCoachView.swift`、`ProfileView.swift`、`FoodComponents.swift`、`MealEditorView.swift`、`AIService.swift`：
- pending 身份、同 ID 重试、unknown 不 fallback、completed 无消息重查。
- timeline builder 保证历史→live；未改全局布局/主题/token。
- 主动学习开关与食物来源/不确定性提示（最小追加）。

## 4. 测试证据

见 `TEST_RESULTS.md` 与 `evidence/`。关键：
- Python **722/722**；Golden **120/120 intent+safety，10/10 adversarial**。
- XCTest **59/59**（含 12 项 SSE/身份/排序）。
- UI **5/5**；Debug/Release **BUILD SUCCEEDED**。
- PHP **52/56**；4 项 `test_account_regression/test_account_v2/test_club_push/test_repair_v48` 均 `undefined openssl_*`。
- 迁移正负例、HTTP 202/409/404/cancel/410、两连接取消竞态、子行动 0 写入均有真实 DB/HTTP 日志。

## 5. 未完成 / 发布阻断

1. **真实 provider 逐 Token 流**：`NOT IMPLEMENTED`；当前是 progress SSE + 完整校验后快照。不得对外宣称实时 Token 流。
2. **4 个 OpenSSL PHP 套件**：运行时缺扩展，环境阻塞，不是代码 PASS。
3. 真实模型质量/工具选择/成本、APNs、HealthKit 增删撤权、StoreKit、TestFlight、真机音频/可访问性：**UNKNOWN**。
4. Nutrition 生产食品数据库、模型提示强制 per-100g、真实拍照 E2E：**PARTIAL**。
5. 专业运动/营养阈值审阅：未完成；不得宣称医学效果。
6. 后台 Ops 面板 SQL 尚未在浏览器渲染（测试环境可启动，但本轮未做 UI 验收）。

**发布结论：CONDITIONAL — 不能据此宣布可上线。**
