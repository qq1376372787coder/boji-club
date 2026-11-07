# Defect Closure Matrix — IA-01 … IA-13

状态口径：**VERIFIED**（有真实执行证据）/ **PARTIALLY VERIFIED** / **BROKEN** / **NOT IMPLEMENTED** / **UNKNOWN**。
环境：PHP 8.3.12（pdo_mysql、filter、ctype；无 openssl）、MySQL 8.4.0 隔离实例、Xcode 26.6、Python 3.9。

| ID | 状态 | 修复位置 | 修复前（审计证据） | 修复后证据 | 剩余限制 |
|---|---|---|---|---|---|
| IA-01 | **VERIFIED** | `account-server/migrate-v2-repair.php` | `--apply/--check` 在正常 schema 上 exit 1：`enum:proposal.kind` | 正常 `--apply`/`--check` exit 0；重复 apply 0；删除 `data_operations.trace_id`、`ai_runs.event_floor`、`ai_action_calls.trace_id`、`domain_outbox.trace_id`、`ai_runs_client` 索引、收窄 `ai_action_proposals.kind` 时 check=1，apply 后恢复 0 | 未在 MariaDB 10.11 实跑（只 MySQL 8.4） |
| IA-02 | **VERIFIED** | `process-ai-runs.php`、`ai-conversations.php`、`AIRunStream.swift` | `run.completed` 先写，assistant 保存失败被吞，snapshot.message=null | 注入 assistant INSERT 失败：worker 将 run 置 `failed`，无 `run.completed`，message=null；正常完成时 message/cards/terminal/completed 同事务；客户端 `completed 无 message` 重查 3 次后显式报错，不静默 idle | 真实模型/真机 E2E 未跑 |
| IA-03 | **VERIFIED** | `ai-runs.php`、`process-ai-runs.php`、`action-execution.php`、`action-jobs.php` | 取消后 worker 覆盖 completed；重复完成双事件；取消后子行动写体重 | 两连接竞态最终 `cancelled`，事件仅 `created/status/cancelled`；重复 Complete 拒绝/不追加；取消后 `ai_action_messages=cancelled`，`actionCallResolve` 返回 cancelled，`measurement_count=0` | 未做双设备真机 |
| IA-04 | **VERIFIED** | `ai-runs.php`、`AIRunStream.swift`、`ClubCoachView.swift` | Header 与 body ID 不绑定；响应丢失后新 UUID 走旧轮询 | HTTP 同 Header 换 body ID → **409**；客户端创建超时重试同一 `client_message_id`（3 次），未知结果不再 fallback；pending 身份持久化，重开恢复 | 真实网络切换/后台恢复未真机 |
| IA-05 | **VERIFIED** | `fitness_intelligence.py`、`ai-router.php` | “胸部疼痛，喘不过气”返回 TRAIN_AS_PLANNED；空日期行伪造 100% 覆盖 | 急症 → SAFETY_ESCALATION（仅 medical）；严重疲劳/疼痛 → ASK_FOLLOWUP/CONSIDER_REST；PHP 以确认训练日计算 coverage/freshness；7 个空日行 → clarify | 真实用户语言覆盖仍有限；无专业医学审阅 |
| IA-06 | **VERIFIED** | `process-ai-runs.php` | CLI 缺 `insightHomeToday/cloudStoredState` 依赖，记忆恒不注入 | 真实 CLI 启动 `{"claimed":0}`；`cloudStoredState_loaded=true`；确认偏好/限制/纠正全部进入 `payload.memory`，`_context_status.memory=injected` | 记忆内容为合成夹具 |
| IA-07 | **PARTIALLY VERIFIED** | `nutrition_engine.py`、`food_core.py`、`ai-proposals.php`、`training-commands.php`、`FoodComponents.swift`、`MealEditorView.swift` | 米饭改鸡胸肉仍保留米饭营养且 `requires_user_confirmation=false`；营养变化不改指纹；ml 当 g | 改名 → 可信目录重匹配/未知则营养未知+需确认；指纹含营养观察与来源版本；ml 无密度 → `volume_requires_density`/营养未知；模型自报 database/label → `source_unverified`；来源/区间/flags 进入原生审核与 MealEntry | 可信食品库是 12 项 fixture，不是生产食品库；模型提示未强制输出 `per_100g`；真实拍照 E2E 未跑 |
| IA-08 | **PARTIALLY VERIFIED** | `ai-router.php`、`capability-registry.php`、`insights.php`、`ai-memory.php`、`ProfileView.swift`、`food_core.py` | 三套规则仅内部 API，无正式链；无主动学习开关/补偿 | 新增 `fitness.suggest_progression` 能力→权威组数→规则→AdviceCard；`insightHomePick` 接 ranker；主动学习开关（服务器 + 设置页）关闭后不再提取/出洞察；记忆 upsert 走信任策略；已执行改期可生成反向补偿提案（需确认） | Nutrition 全量食品库/真实拍照链、专业阈值审阅、部分 UI 入口仍缺；标 PARTIAL |
| IA-09 | **VERIFIED** | `ClubCoachView.swift`、`ClubCoachTimelineBuilder` | live 轮次在历史之前 | `ForEach` 使用 `ClubCoachTimelineBuilder.rows`，history 在前、live 最后；XCTest 覆盖 2 条历史 + live | 真实流式 UI 未截图（无真实服务端账号） |
| IA-10 | **PARTIALLY VERIFIED** | `process-ai-runs.php`、`ai-runs.php`、`prune-ai-runs.php` | 完整回答后按 48 字切块伪装实时流；无过期/410；无并发上限 | 已移除假 delta；只发 progress + 校验后 `text.snapshot`；`event_floor` + `prune-ai-runs.php`；HTTP `after_seq=0` 过期 → **410**，当前游标 200；每用户/会话并发上限 2；事件保留/清理由 CLI 提供 | **真实 provider 逐 Token 流 NOT IMPLEMENTED**（无供应商流式接入/凭证）；只有 progress SSE + 验证后快照 |
| IA-11 | **VERIFIED** | `personal_intelligence.py` | max_per_day=2 却选中 5；换 insight_id 绕过冷却 | 选中 2/2；同 kind/subject 新 ID 被 `kind_cooldown` 抑制；安全类单独 1 条 | 未接线上通知（ranker 已接首页洞察） |
| IA-12 | **VERIFIED** | `ai-runs.php`、`action-execution.php`、`action-jobs.php`、`commands.php`、`ai-proposals.php`、`ai-runs-panel.php` | trace 列存在但 Run→行动→确认→事件不连通 | `ai_action_messages/calls/domain_outbox` 增 trace；worker/确认恢复父 trace；真实 DB 测试同一 trace 找到 Run/消息/行动/提案/命令/Outbox | 后台面板 SQL 未在浏览器渲染 |
| IA-13 | **PARTIALLY VERIFIED** | `php_test_bootstrap.php`、`run_php_suite.sh`、`test_ai_runs.php`、`test_ai_proposals.php`、`test_timestamp_repair.php` | Run 套件缺 helper、原始 SQL 1064、3 个测试库未建、静态断言冒充行为 | Run 套件自建/清理 DB，调用真实 migrator；新增失败注入/取消竞态/重复完成/保留期/并发/补偿/追溯行为断言；完整 PHP 套件 **52/56** 通过 | **4/56 仍失败，均因 PHP 运行时缺 openssl 扩展**（account_regression/account_v2/club_push/repair_v48）；非代码失败；未编译该扩展 |

## 复现命令（摘要）

```bash
# 本机隔离运行时
export BOJI_TEST_DSN_BASE="mysql:unix_socket=$PWD/env/mysql.sock"
export PHP="$PWD/env/php"
python3 tests/run_offline.py                    # 722 OK
python3 tests/run_golden_evals.py               # 0 failures
php tests/test_ai_runs.php                      # AI_RUNS_OK
php tests/test_intelligence_closure.php         # INTELLIGENCE_CLOSURE_OK
php tests/test_trace_chain.php                  # TRACE_CHAIN_OK
bash tests/run_php_suite.sh                     # 52 passed, 4 env-blocked
```

## 未解决发布阻断

1. 真实模型 token 流与真实模型质量/成本未验收。
2. 4 个 OpenSSL PHP 套件环境阻塞。
3. HealthKit/APNs/StoreKit/TestFlight/真机音频/可访问性未验收。
4. Nutrition 生产食品库与专业阈值审阅未完成。
