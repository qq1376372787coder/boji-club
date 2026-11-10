# Phase 0 · 现有仓库与依赖审计（CURRENT_STATE_AUDIT）

- 审计日期：2026-10-25
- 审计对象：`BojiClub-V2-AIAction-Fixed-Build116-20261025.zip`
- ZIP SHA256：`c1a242dbefc98706a74f7d30fe574b1fe334d39c96cfb9b6979c7e5369abcbd5`（与随包 `.sha256` 一致）
- 隔离工作区 Git 基线：`313e91ed9afbdafb95cd1823c57ae5825337bc2d`（baseline commit，未 push）
- 口径：以仓库实际行为为事实来源；文档中的 PostgreSQL/SwiftUI 目标设计不视为已实现。

## 1. 技术栈与拓扑（实测）

| 层 | 实际实现 | 入口 | 说明 |
|---|---|---|---|
| iOS | SwiftUI，最低 iOS 17，Xcode 26.6 | `BojiClub/BojiClubApp.swift`、`BojiClub/ClubAIShell.swift` | 单一 AI Shell：顶部 `Club AI / 训练`、左侧栏、右上新会话；无 Tab Bar |
| 账号/BFF | PHP 8.x（生产 MariaDB 10.11；测试 MySQL 8.4） | `account-server/public/index.php` | Bearer 会话、配额、会员、幂等命令、提案、Outbox、后台 |
| AI Worker | Python 3（stdlib HTTP server + SQLite 任务库） | `backend/server.py` | 内部 loopback，仅账号服持令牌访问；模型供应商可路由/降级 |
| 动作库服务 | Python | `exercise-server/api.py` | 678 项动作库校验/查询 |
| 数据库 | MariaDB/MySQL，`app_states` 文档 + 分片表 + 领域增量表 | `account-server/schema.sql`、`account-server/migrations/*` | 计划/日程/训练事实映射在账号文档 JSON 中，不是独立 occurrence 表 |
| 后台 | PHP 管理台 | `account-server/admin/*` | 配置、AI 运维、审核 |
| 定时任务 | PHP CLI + systemd timer | `process-action-jobs.php`、`process-domain-outbox.php`、`process-domain-notifications.php`、`reconcile-domain-outbox.php` | Outbox/任务/通知/对账 |
| 测试 | Python unittest、Swift 独立 harness、PHP 集成脚本 | `tests/` | 依赖本机 PHP + MySQL；本机缺失（见 §6） |
| CI | GitHub Actions | `.github/workflows/*` | 含 Linux + MySQL 8.4 后端检查 |

## 2. 源码覆盖清单（文件数 / 已检查范围）

| 目录 | 文件数 | 主要文件 | 检查方式 |
|---|---:|---|---|
| `BojiClub/` | 92（78 Swift） | `AIService.swift`、`AppStore.swift`、`ClubCoachView.swift`、`AICards.swift`、`ClubProposalSync.swift`、`WorkoutView.swift`、`NutritionView.swift`、`BodyWeightView.swift`、`HealthData.swift` | 全量入口/协议/状态路径阅读；UI 文件逐文件哈希 |
| `account-server/` | 217（68 PHP） | `public/commands.php`、`ai-router.php`、`capability-registry.php`、`action-*.php`、`business-state.php`、`domain-consumers.php`、`weekly.php`、`ai-conversations.php`、`ai-memory.php`、`insights.php` | 路由表、命令事务、提案、Outbox、会话、记忆、运维端点 |
| `backend/` | 20（15 Python） | `server.py`、`ai_core.py`、`coach_core.py`、`intent_router.py`、`food_core.py`、`adaptive_core.py`、`weekly_core.py`、`card_composer.py` | 全量模块清单 + 关键函数/契约；676 项离线测试实际运行 |
| `exercise-server/` | 11 | `api.py` | 动作库身份/校验路径 |
| `tests/` | 237 | 54 个 Swift harness、124 个 Python 测试、60 个 PHP 集成测试 | 实际运行 Python/Swift；PHP 因缺运行时未执行 |
| `docs/` | 180 | `docs/v2/*`（前序）、`docs/action-system-build116/*` | 以代码为准交叉核对，不采信历史“已完成”声明 |
| `admin-media/`、`scripts/`、`Configuration/`、`legal/` | 30 / 43 / 2 / 4 | 部署、运维、法务 | 只读审计 |
| `BojiClubWidget/` | 7 | Live Activity/Widget | 只读审计（本轮不修改） |

未逐行阅读：历史说明类 Markdown、媒体资源、生成物（`*.json` manifest、`*.html` 预览）。所有与本次目标相关的代码路径均已定位到文件/行号。

## 3. 权威数据源（单写入口）

- **账号与会员**：`users`、`memberships`（`account-server/schema.sql`）。
- **业务文档**：`app_states.state_json`（revision）+ 分片表（`cloud-parts.php` / `business-state.php`）。计划模板、每周 `planCycle`、每日 `exercises/sets`、餐食、身体测量均在文档 JSON 内，按日期窗口读写。
- **日程实例**：`days[date]` + `planCycle`；无独立 `schedule_occurrence` 表（与目标 TDD 的差异见 `ARCHITECTURE_DIFF.md`）。
- **训练事实**：`days[date].workoutSessions/exercises[].sets[].completed`；`data_operations` 保存命令审计和逆载荷。
- **餐食**：`days[date].meals`；来源/估算标记存于条目字段。
- **体重**：`days[date].bodyMeasurements`（同日多笔、墓碑 `deletedBodyMeasurementIDs`）。
- **提案/命令/Outbox**：`ai_action_proposals`、`ai_action_calls`、`data_operations`、`domain_outbox`、`domain_consumer_inbox`、`domain_projection_state`。
- **AI 会话**：`ai_conversations` / `ai_messages` / `ai_message_cards`（服务端只写；iOS 尚未读取）。
- **AI 任务**：`ai_user_jobs`（账号服）+ Python worker SQLite `jobs`。
- **AI 记忆**：`user_memory_items`（`ai-memory.php`）。
- **用量/反馈**：`ai_usage_ledger`、`ai_feedback_events`。

**单写入口**：所有高影响业务写入经 `handleBusinessCommandCore()`（`account-server/public/commands.php:30`），在 `lockActiveUser` + 事务 + `expected_version`/提案 `base` 校验下修改文档，并同事务写 `data_operations` 与 `domain_outbox`。AI 只能创建提案；确认由独立用户端点触发（`ai-router.php:352` 拒绝模型直接调用 `schedule.commit_change` / `action.undo`）。

## 4. 既有功能状态（与本次相关）

| 能力 | 状态 | 证据 |
|---|---|---|
| AI 主界面/侧栏/顶部切换/Composer | 已实现（冻结） | `ClubAIShell.swift`、`BojiClubUITests.swift` |
| AI 对话（同步代理 + 轮询任务） | 已实现 | `AIService.swift:704-790`、`weekly.php:10-89` |
| AI Action System（15 能力、提案、确认、撤销） | 已实现，Build116 修复 AS-01…AS-32 | `capability-registry.php`、`action-execution.php`、`commands.php` |
| 计划/日程/训练/饮食/体重 | 已实现（文档 + 分片 + 命令） | `business-state.php`、`commands.php`、`action-sync.php` |
| Outbox/消费者去重/对账 | 已实现 | `domain-consumers.php`、`process-domain-outbox.php` |
| 后台 AI 运维 | 部分（模型/任务/容量） | `admin/index.php`、`backend/server.py:1003-1024` |
| **SSE 流式** | **完全缺失** | 全仓无 `text/event-stream` / `after_seq` / delta 实现 |
| Golden Evals | 缺失 | 仅零散单元测试，无数据集/门禁 |
| Trace ID 全链路 | 缺失 | 仅 job/command UUID；`ai_usage_ledger` 无 trace 列 |
| 动作 canonical/variant | 缺失 | 678 项平铺 `exercise-catalog.json`；仅名称+器械校验 |
| 营养 per-100g 引擎 | 缺失 | `food_core.py` 只校验模型给的整份营养值 |
| 结构化安全分流 | 部分 | 仅关键词正则 `ai-router.php:184-187` |

## 5. 构建与运行命令（实测）

```bash
# iOS 构建（本机已通过）
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build

# Python 离线回归（本机已通过 676 项）
python3 tests/run_offline.py

# Swift 规则回归（本机 32/54 harness；22 个基线编译失败）
python3 tests/run_swift_regressions.py --output <dir>

# PHP/DB 集成（需隔离 MySQL；本机无 PHP/MySQL，未执行）
BOJI_TEST_DSN_BASE=... PHP=php bash tests/run_action_checks.sh
```

## 6. 环境异常与限制（BLOCKED 预登记）

| 项 | 现状 | 影响 |
|---|---|---|
| PHP 运行时 | 本机 `php: command not found`，无 brew/docker | 所有 PHP 单元/集成测试无法本地执行 |
| MySQL/MariaDB | 本机无 `mysql`/`mysqld` | 迁移与事务测试无法本地执行 |
| 真实模型供应商 | 无 `.env`/API Key | 只能验证契约与确定性回退，不能声明真实模型质量 |
| Apple 签名/TestFlight/APNs/HealthKit 真机 | 无证书/设备授权 | 只做模拟器与代码级验证 |

以上不阻止 iOS/Python 的真实构建与测试；PHP 侧交付将标注 `IMPLEMENTED_NOT_VERIFIED` 并给出可复现命令。

## 7. 审计结论

- 项目不是“待建的新系统”，而是已具备完整业务闭环的 AI-first App；本轮应复用 `commands.php`、提案、Outbox、`app_states` 文档，不应新建平行表或第二套 UI。
- 最大结构性缺口是 **流式传输与可观测性**；其次是 **确定性专业引擎** 与 **评测门禁**。
- 现有 UI 为用户已验收资产，冻结基线见 `05_UI_BASELINE_AND_FREEZE_REPORT.md`。
