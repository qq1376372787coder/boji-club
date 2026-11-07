# BOJI CLUB V2.0 · Phase 0 审计报告 02：缺口分析（GAP ANALYSIS）

- 对照文档：《BOJI_CLUB_V2_AI原生化_完整功能与技术落地方案_V1.1.md》第 00–23 章 +《ChatGPT 式页面架构与 UI 专项规范 V1.1》
- 标记定义：**EXISTING**（已存在且可复用）/ **PARTIAL**（部分存在）/ **MISSING**（不存在）/ **CONFLICT**（现状与方案假设冲突）/ **UNKNOWN**（需生产环境/运行验证）
- 所有 EXISTING/PARTIAL 结论附真实源码位置。

---

## 0. 结论速览

| 章 | 主题 | 判定 |
|---|---|---|
| 00 | 边界与原则 | PARTIAL（业务能力齐备，原则层需补：无版本控制、无回退开关体系） |
| 01 | 信息架构 IA | CONFLICT（现为 5-Tab，非双模式+Sidebar） |
| 02 | Club AI 首页 + 2.5 ChatGPT 式架构 | MISSING（Shell/Composer/卡片流不存在；对话与留白理念部分已有） |
| 03 | 原生训练中心 | EXISTING（能力全；需重组为首屏导向 + 顶部双模式挂载） |
| 04 | 记录中心 | PARTIAL（四分类+三入口中两条；缺 Composer `+` 与 AI 自然语言直达） |
| 05 | Sidebar/我的/俱乐部/AI 记忆 | PARTIAL（俱乐部 EXISTING；AI 记忆 MISSING；我的/设置散在 Profile） |
| 06 | 动态原生卡片协议 | MISSING（卡片为硬编码分支，无 CardRegistry/协议校验） |
| 07 | 五条用户故事 | PARTIAL（UC-02 基本全；UC-01/03 双路径半成；UC-04/05 缺结构化） |
| 08 | 总体架构 | PARTIAL（模块边界已按域划分；单 JSON 文档 vs 领域表 CONFLICT；Outbox 骨架在、消费者空） |
| 09 | AI 工作流程与行动安全 | PARTIAL（行动分级实质已实现 R0–R3 语义；缺 Intent Router/Card Composer/Proposal 通用状态机） |
| 10 | 长期记忆与主动学习 | MISSING（无 Memory Store；主动机制有雏形但无三档主动程度/反馈学习闭环） |
| 11 | 数据模型 | CONFLICT（V2 假设领域表；现实 app_states 单文档 + 34 表辅助；data_operations/outbox 已有） |
| 12 | API 与流式契约 | PARTIAL（REST 面 EXISTING；SSE/流式 MISSING；对话无服务端会话） |
| 13 | 事件驱动一致性 | PARTIAL（Outbox 表+worker 在；事件类型 3 种；消费者空实现） |
| 14 | iOS 技术实现 | PARTIAL（分层清晰 god-store 风险；V2 组件树需新建） |
| 15 | Health/隐私/App Store | PARTIAL（同意域路由/隐私清单/权限文案优；HealthKit 无增量同步；裸 IP HTTPS 风险） |
| 16 | 部署/供应商/成本 | PARTIAL（3 供应商路由+熔断+配额+管理端 EXISTING；无 token 成本台账/流式；2C2G UNKNOWN） |
| 17 | 性能与异常 | PARTIAL（降级等级 L0-L4 部分实质存在；基线指标 UNVERIFIED；历史 bug 部分未闭环） |
| 18 | 安全隐私风控 | PARTIAL（服务端 posture 强；无 BOLA 级对象授权测试面；管理后台鉴权需复核） |
| 19 | 分阶段迁移与退出 | MISSING（无 feature flag 客户端体系、无灰度、无回退开关；迁移原则未文档化到库内） |
| 20 | 测试矩阵 | PARTIAL（大量规则回归测试+脚本；无 CI、 XCTest 单测进工程与否待查、PHP 无法本地跑） |
| 21 | 运营与定量验证 | MISSING（无指标埋点体系；后台有统计但非对照实验结构） |
| 22 | 关键决策确认 | 本报告逐条回答（见 §22） |
| 23 | 执行约束 | 过程文档显示历史上已遵循类似纪律（审计 ID/验证 JSON），需在新阶段延续 |

---

## 1. 逐章映射

### 第 00 章 项目边界、目标与不可破坏原则 — PARTIAL

| 项 | 状态 | 证据 |
|---|---|---|
| 覆盖范围中的既有业务（训练/营养/健康/记录/俱乐部/会员/后台/监控/迁移/QA） | EXISTING | 见 01 号报告 A 节 |
| "AI 不可用时核心功能可用" | EXISTING | 训练/记录全本地：`AppStore.swift:929-939`（本地保存）、`CloudSyncStatus` 非阻塞（`CloudSync.swift:4-22`）；AI 失败仅降级 AI 域 |
| "任何灰度阶段可关闭新首页回退" | MISSING | 无客户端功能开关体系；`ClubRemoteConfig.aiEnabled/clubEnabled` 解码后从未读取（`AccountService.swift:142-166`，全仓 grep 无消费点） |
| "iOS 音频会话等问题纳入回归基线" | PARTIAL | 首页静音视频仍会激活默认会话（`HomeWorkoutVideo.swift:5-27` 无 mixWithOthers）——问题机制仍在（详 §17） |
| 不含项（AI 直接写库/生成 SwiftUI/单用户训模） | EXISTING（符合） | 后端无 LLM 直写业务表路径；模型输出全部经校验器（backend/`*_core.py`） |

### 第 01 章 产品信息架构 IA — CONFLICT

- **CONFLICT**：V2 要求"顶部双模式 Club AI|训练 + 左 Sidebar + 右新对话"；现实为 **5-Tab TabView**（首页/计划/记录/俱乐部/自己，`BojiClubApp.swift:423-469`）+ 全屏 Cover 训练。
- 路由清单中的目标：现有可映射能力——
  - `app://training/home` ≈ 计划 Tab `ClubPlanHub`（PARTIAL：训练中心尚未以"今日训练优先"组织）
  - `app://records/{...}` ≈ 记录 Tab 四分段（EXISTING，`ProductArchitecture.swift:414`）
  - `app://club/home` ≈ 俱乐部 Tab（EXISTING）
  - `app://account`/`app://settings` ≈ Profile Tab 内（PARTIAL：无独立设置栈）
  - `app://ai/memory` MISSING（无 AI 记忆页）
  - `app://club-ai/conversation/{id}` PARTIAL（conversation_id 存在但无历史会话列表/恢复，`ClubCoach.swift:101-116`）
- "切换保留各自导航栈/草稿/待确认卡片"：现状 TabView 天然保留各 Tab NavigationStack；**草稿持久化已在对话域存在**（UserDefaults per conversation，`ClubCoach.swift:101-116`）；训练进行态跨 Tab 由迷你条+fullScreenCover 保留（`BojiClubApp.swift:410-420`）。→ 双模式方案可复用该机制，但**AI↔训练切换的状态隔离是新工作**。

### 第 02 章 Club AI 首页（含 2.5 ChatGPT 式规格）— MISSING（结构性）/ PARTIAL（理念性）

| 规格项 | 状态 | 证据/缺口 |
|---|---|---|
| 顶部胶囊 `Club AI | 训练` | MISSING | 无 RootHeaderView；现 TabView |
| 左 Sidebar 抽屉（历史对话/我的记录/俱乐部/AI 对我的了解/我的/设置） | MISSING | 无抽屉；各入口分散在 Tab |
| 右上新对话（AI 模式） | MISSING | 现无新会话按钮（conversation_id 由提交生成） |
| 默认大量留白 + 0-1 条主洞察 | PARTIAL | 首页已"top1 洞察"（`HomeView.swift:721-777`，`ClubInsightPriorityRules.top`），但首页同时堆叠身体卡+hero 视频+餐食卡+训练卡（`HomeView.swift:69-94`）——与"留白"相反，且 hero 视频即音频风险源 |
| 进入对话后工作台收起 | PARTIAL | ClubAIHub 分段切换动态/报告/对话（`ClubCoachView.swift:3-53`），非收起式单流 |
| 底部固定多模态 Composer（+、文本、图片、语音、发送/停止） | MISSING | 对话输入框仅文本 1200 字（`ClubCoachView.swift:222-235`）；相机/语音/文字分散在饮食域 |
| S0-S3 状态机 | PARTIAL | S2/S3 概念上存在（对话流/提案卡）；无 S0/S1 的"工作台"定义 |
| 键盘避让/草稿恢复 | PARTIAL | 对话草稿已恢复（`ClubCoach.swift:101-116`）；键盘行为 UNVERIFIED（需真机） |
| 普通对话不抢占音频 | CONFLICT | 首页静音视频会激活默认 AVAudioSession（`HomeWorkoutVideo.swift:5-27`）；语音录入是唯一显式配置点且正确释放（`MealSpeechInput.swift:47-49,109`） |
| `#E3E7F0` 品牌雾蓝 | EXISTING | `DesignTokens.swift:24-26` brandMist（浅深自适应），已用于日历表面 |
| 液态玻璃/系统材质按部署目标适配 | UNKNOWN→已核 | 部署目标 iOS 17.0（`project.pbxproj`）→ **不可用 iOS 26 Liquid Glass API**，只能用系统材质/自绘 |
| 首页 0-3 条上下文相关推荐问题 | PARTIAL | 快捷问题已基于真实记录（`ClubCoach.swift:120-132`），但无"轻量出现于输入框附近"的形态 |

### 第 03 章 原生训练中心 — EXISTING（能力层）/ PARTIAL（组织层）

- 计划包两路径（AI 制定 + 自定义）EXISTING：`PlanCreationSheet` 6 入口（`PlanManagement.swift:8-63`）；AI 计划采纳带 Diff（`PlanView.swift:571-594`）；手动计划编辑器（`ManualPlanView.swift`）。
- 计划版本 draft/published/archived ≈ EXISTING：`ClubPlanVersion` 不可变链 + ended/archived 墓碑（`ClubHistory.swift:213-301`）。"正在执行的训练引用发布时版本"由**冻结执行基线 executionBaseline** 实质承担（backend/`training_feedback.py:52-58` 按 set ID 对比冻结目标）。
- 训练会话状态机 not_started→active↔paused→finishing→saved + sync_pending ≈ EXISTING：本地保存即时 + 云同步状态 waiting/waitingService（`CloudSync.swift:4-22`）；`idempotency` 经 appliedAIJobs/稳定 ID 体系（`AppStore.swift:1657-1691,1947-1951`）。
- 组间计时本地单调 + 后台恢复按存储时间重算 ≈ EXISTING：`ClubRestStorage` 持久化 restEnd（`ClubAutomation.swift:188-232`）。
- "AI 调整计划列 Diff、检查冲突、确认后发布" PARTIAL：改期提案有校验+预览（`ClubCoachView.swift:267-338`）；参数变更提案有证据规则（`adaptive_core.py:31-55`）；**但无统一 Proposal/Diff 协议卡**（见第 06/09 章）。
- 不恢复"文字识别计划"主入口 —— 现状 `AI 整理文字计划`（parse_plan）仍是一级入口（`PlanManagement.swift:8-63`）→ **CONFLICT**：产品决定需确认（方案 3.2 说"不恢复…除非产品决策明确恢复"，而当前 App 里它存在且后端 parse_plan 全链路在用）。⚠️ 需产品拍板。

### 第 04 章 记录中心 — PARTIAL

- 四分类训练/饮食/身体/报告 EXISTING：`ClubRecordsHub`（`ProductArchitecture.swift:414`）。
- 三条触达路径：
  1. 原生入口（Sidebar→记录→分类→新增）：PARTIAL（现为 Tab→记录→分类；Sidebar 形态 MISSING）
  2. 快捷入口（AI 底部 `+`）：MISSING（无 Composer）
  3. 自然语言：PARTIAL——语音/文字餐食理解 EXISTING（`MealSpeechInput.swift:123-217`）；**通用自然语言记录（"今天早上喝了牛奶吃了两个鸡蛋"→草稿）的对话路径未接**：food 任务支持 text 模式（backend `ai_core.py:360-423` text ≤2000 字），但对话入口在饮食编辑器内而非 Club AI 对话。
- 数据核对与合并：source 标记 PARTIAL（AI 餐食有 estimated/来源任务 ID；手动 vs HealthKit 冲突的"展示优先级"规则未见显式实现——体重双源仅 per-source 去重 `HealthData.swift:527-531`）；修改旧记录触发报表重算 PARTIAL（报告有 source_revision 版本链 `automation_core.py:11-17`，客户端报告库是否强制刷新 UNVERIFIED）。

### 第 05 章 Sidebar / 我的 / 俱乐部 / AI 记忆 — PARTIAL

- Sidebar 顶层结构 MISSING（无抽屉）。
- 俱乐部 EXISTING：成长季/任务/徽章/实物/Club Keepsake/发货全链路（`ClubSeason.swift:239-416` + `index.php:529-688`）；AI 可解释（coach 上下文含俱乐部数据 PARTIAL——coach 上下文为 days/upcoming，未含 club 进度）。
- 我的/订阅 EXISTING：`ProfileView`（1,296 行）+ `MembershipService`；订阅管理 CustomerCenter（`RevenueCatViews.swift:75-77`）。
- **AI 对我的了解（记忆三栏）MISSING**：无 user_memory_items 等价物、无记忆查看/纠错/删除 UI；最接近物是 insight ledger（本地规则事实+反馈，`ClubInsightLedger.swift:102-`）与 goalVersions（历史快照）——但都不可算"长期记忆"。
- 最近对话列表/搜索 MISSING：服务端不存会话（backend `coach_core.py`），客户端只存当前会话草稿。

### 第 06 章 动态原生卡片协议 — MISSING

- 现状 AI 呈现 = 按 `result.kind` 硬编码 SwiftUI 分支（`AIViews.swift:29-272` 报告卡/反馈徽章；`ClubCoachView.swift:154-192` 对话答案卡）。无 `card_id/card_type/schema_version/payload/actions/evidence_refs/expires_at` 协议；无 CardRegistry、无卡片状态机（loading/ready/stale/expired/confirmed…）、无 actionId 白名单映射层（coach 的 7 动作白名单在服务端，`coach_core.py:98-102`，客户端直接硬编码路由）。
- 方案 6.2 的 10 类卡片现状：`today_training` MISSING（无对话内训练卡）；`training_progress` PARTIAL（报告卡近义）；`meal_draft` PARTIAL（饮食编辑器草稿流，非对话卡）；`weight_entry` MISSING（无体重草稿卡）；`body_trend` PARTIAL（身体趋势页，非卡）；`plan_change_proposal` PARTIAL（改期预览/Diff sheet 存在，非协议卡）；`insight` PARTIAL（insight ledger 有反馈动作）；`clarification` MISSING；`club_progress` PARTIAL（俱乐部页）；`report` EXISTING（报告卡+阅读器）。

### 第 07 章 五条用户故事 — PARTIAL

见 01 号报告 §E 预演表。要点：UC-02 最完整（EXISTING 级）；UC-01 缺对话卡直达；UC-03 缺统一提案状态机与 Outbox 消费者；UC-04 缺趋势+不确定性结构化卡；UC-05 缺行为学习闭环（自动分析有，习惯归纳无）。

### 第 08 章 总体技术架构与边界 — PARTIAL + 一处 CONFLICT

- "渐进式模块化单体 + AI 可控领域" ≈ EXISTING：现架构就是单体 PHP + 单体 Python worker + 单 iOS 应用，AI 无直写业务表路径（全部经校验器+命令通道）。
- 模块对照：Conversation Service PARTIAL（无服务端会话存储，历史客户端携带 `coach_core.py:21-26`）；Intent Router MISSING（无 chat/query/draft_create/change_proposal 分类层，kind 由客户端显式指定）；Context Builder PARTIAL（coach 上下文=客户端提交 days≤14 天+upcoming，非服务端按意图拉取——**信任模型不同：现状信任客户端提供的记录**）；AI Gateway PARTIAL（无供应商配额/成本按请求级台账，有全局+账号日配额）；Card Composer MISSING；Memory Engine MISSING；Insight Engine PARTIAL（本地规则+automation 触发器，无评分排序）；Action Orchestrator PARTIAL（commands.php 3 命令+审计+Outbox）；Event Workers PARTIAL（worker 在、消费者空）。
- **CONFLICT（数据架构）**：V2 §8.3"Training Plan 是计划权威源；日历/首页摘要是派生视图"——现实权威源是**客户端 SavedState 文档**（服务端 app_states 只是存储），服务器派生仅 club_progress/报告。V2 的"Single Writer=领域服务"与"客户端单文档生成"两种模型需要明确共存策略（04 号报告展开）。

### 第 09 章 AI 工作流程与安全行动协议 — PARTIAL（思想已高度实现，形态不同）

- 处理链 10 步对照：①client_request_id ≈ client_job_id UUID（EXISTING，`ai_user_jobs`）；②BFF 校验身份/订阅/配额 EXISTING（`weekly.php:130-162`）；③Intent Router MISSING（无分类）；④Context Builder PARTIAL（见上，方向相反）；⑤工具白名单只读查询 MISSING（无 server-side tool calling，模型不主动查数据）；⑥AI Gateway 调用+结构化校验 EXISTING（三家路由+全输出校验器）；⑦Card Composer MISSING；⑧Action Orchestrator PARTIAL（`commands.php`）；⑨Domain Service 事务+事件+回执 PARTIAL（Outbox 在、消费者空）；⑩质量记录 PARTIAL（attempts/task_audits 统计，无按请求 trace 贯穿）。
- 行动分级：R0 只读 EXISTING；R1 界面行为 EXISTING（动作白名单7项路由到页面）；R2 草稿 EXISTING（餐食/计划草稿、AI 结果永远 estimated+确认）；R3 有状态修改 PARTIAL（服务端命令通道有 CAS+确认语义，但客户端未接入；现有 UI 修改走本地→同步，同样是用户确认后）；R4 禁止项 EXISTING（无 AI 写支付/发奖/删史路径；模型输出被禁止宣称已修改 `coach_core.py:86`）。
- Proposal 状态机（draft→validated→awaiting_confirmation→executing→succeeded + 旁路）MISSING（现提案是"一次性校验→预览→本地应用"，无服务端持久状态机/过期/冲突终态）。
- Tool Calling 安全 MISSING（无 tool registry——因为根本无模型发起的工具调用；V2 若引入需新建）。
- Prompt Injection 防御 EXISTING：系统提示注入抗性 + 输出校验器（backend 全模块）。

### 第 10 章 长期记忆与主动学习 — MISSING / PARTIAL

- 六种记忆类型 MISSING（无 memory store）。
- 记忆写入守门 PARTIAL：goalVersions 快照（`ClubHistory.swift:65-94`）与"point-in-time profile 进 AI 上下文"（`ClubAIContext`）体现了"不拿今日资料回填历史"的纪律（backend `goal_context.py` 强制）；偶发行为不固化的原则在 automation（35 天窗口、就绪门槛 `automation_core.py:101-194`）有影子。
- Insight 排序 score 公式 MISSING（现为固定优先级 `ClubInsightPriorityRules`）。
- 三种主动程度 MISSING（现为 daily/weekly/workout/partial 四个布尔 + 免打扰 + 推送预算——语义不同但可映射：安静≈全关、平衡≈默认、积极≈partial+提高预算）。
- 反馈学习闭环 PARTIAL：insight ledger 有 helpful/read/archive/dismiss（`ClubInsightLedger.swift:15-28`）+ ClubActionRecord 状态机（`:59-88`），但无"曝光→接受→执行→结果"全链路记录与策略更新。
- 推送限频 EXISTING（4 类预算+语义去重+免打扰+账号拉黑，`club-push.php:37-113`）。

### 第 11 章 数据模型 — CONFLICT（部分骨架 EXISTING）

- V2 建议表 vs 现实：`ai_conversations/ai_messages/ai_message_cards` MISSING；`ai_action_proposals/ai_action_executions` ≈ 部分对应 `data_operations`（有 idempotency+diff+version+actor）但**无 awaiting_confirmation 等状态**（数据模型见 `schema.sql:568-583`）；`user_memory_items/user_behavior_features/ai_insights/ai_feedback_events` MISSING；`ai_usage_ledger` PARTIAL（`task_successes/task_completions/attempts` 统计粒度，无按请求成本）；`ai_settings` PARTIAL（club_automation.preferences_json + club_push_devices.preferences_json 分散）；`outbox_events/projection_checkpoints` ≈ `domain_outbox` EXISTING / projection checkpoints MISSING（消费者本来就没实现）。
- **CONFLICT 核心**：V2 的领域表（训练/营养/身体）在现实 = `app_states.state_json` 单文档（≤16MB）+ `cloud_parts` 分片（`sync-schema-v59.sql`）。V2 若建领域表必须走 expand-and-contract 且明确文档模型保留多久（04 号报告）。

### 第 12 章 API 与流式事件契约 — PARTIAL

- BFF API 对照：`/v2/ai/conversations*` MISSING；`/v2/ai/respond` ≈ `POST /me/ai/jobs {kind:"coach"}`（形态：任务而非请求-响应）；`/v2/ai/insights/home` MISSING（洞察本地生成）；`/v2/ai/memory*` MISSING；`/v2/ai/proposals/{id}/confirm|reject` MISSING（命令通道 `/me/commands` 语义近但无确认流）；`/v2/ai/feedback` MISSING（insight 反馈仅本地）；`/v2/me/ai-settings` PARTIAL（automation+push 两处分散）。
- SSE/流式 MISSING：全链路无 SSE/WebSocket（backend 单次请求+轮询，`server.py`；iOS AIService 轮询 2-15s）。V2 需决定：给现有 job 模型加 SSE 事件流，或保持轮询+协议语义对齐（12.2 允许退化为轮询）。
- `client_request_id` 幂等 EXISTING（client_job_id+server_id HMAC 映射，`ai_user_jobs`）。
- 断线恢复 PARTIAL：`GET /me/tasks?cursor=` 任务恢复页 EXISTING（`task-recovery.php`）。

### 第 13 章 事件驱动与跨模块一致性 — PARTIAL

- 核心 V2 事件（WorkoutSessionSaved 等 13 种）MISSING；现实事件仅 `ScheduleReplaced/ScheduleMoved/ProfileUpdated`（`commands.php:135,168,206`）。
- envelope（event_id/version/aggregate/causation）PARTIAL：`domain_outbox` 有 event_id/operation_id/aggregate_*/version（`schema.sql:585-602`），无 causation/correlation id。
- 写入实例（改训练日历 6 步）：步骤 1-3 EXISTING（事务+Outbox 同事务）；步骤 4-6 MISSING（消费者空转 `process-domain-outbox.php:47-56`，无投影重建/提醒失效/死信面板——死信状态有字段无后台页）。
- 一致性测试重点（并发编辑/重复确认/乱序/重放）MISSING（无此测试；sync 冲突路径有三方合并+409 但无专项测试证据）。

### 第 14 章 iOS 技术实现建议 — PARTIAL

- 分层对照：V2 建议的 ClubAIWorkspace/TrainingFeature/RecordsFeature/ClubFeature 边界在代码中已有清晰雏形（按文件分域），但**AppStore god-store（2,814 行）持有全部域状态**，与 V2"ClubAIFlowState/TrainingFlowState 独立状态源"建议相反（V2 文档自己也说"以现有架构适配"——保留单 store + 子状态划分是务实路径）。
- 状态管理建议已满足项：训练状态独立于聊天（EXISTING——训练在 fullScreenCover+独立存储，聊天不持有计时）；共享数据单一读入口 PARTIAL（均经 AppStore，但 HealthDataService 缓存独立 60s）。
- 主线程压力：图片解码/压缩有后台处理（`MealEditorView.swift:955-971` 降采样；GIF 自定义 delegate 流式 `ExerciseLibraryView.swift:746-803`）；识别后滚动卡顿风险点定位（动画 keyed on sourceJobID `MealEditorView.swift:94-95` + 120ms 延迟滚动 `:98-109`）——UNVERIFIED 是否实际卡顿。
- AVAudioSession 纪律 PARTIAL：语音录入正确（仅触发时激活+结束恢复），首页视频无会话配置（§02）。

### 第 15 章 Apple Health、AI 数据权限和 App Store — PARTIAL

- 按场景申请授权 EXISTING（12 类读按需查询；写仅 workout opt-in；逐日分享同意 `HealthData.swift:104-179`）。
- HKAnchoredObjectQuery/HKObserverQuery/后台交付 MISSING（仅按需拉取，`HealthData.swift:513-579`）。V2 §15.1 说"需要增量同步时可使用"——**需产品决策是否引入**（引入即触碰同步锚点持久化+删除样本处理）。
- 重复导入处理 PARTIAL（per-source 去重 `:527-531`；无 origin UUID 级去重证据——因无持续同步，风险低）。
- 第三方 AI 共享透明披露 EXISTING（`_routing_version` 同意流 + `AIRoutingConsentView` `AIViews.swift:365-380` + PrivacyInfo 非跟踪声明）；健康数据仅发 MiMo/DeepSeek 的 fail-closed 路由 EXISTING（`ai_core.py:1276-1287`）。
- TestFlight/审核材料：隐私清单/权限文案/订阅本地化 JSON（`SUBSCRIPTION-LOCALIZATIONS-20261013.json`）EXISTING；**裸 IP HTTPS（117.50.119.49）无域名** —— App Review 通常可接受有效证书的 IP HTTPS，但证书有效性 UNKNOWN，且 dongzuo 媒体域 nginx 仅见 80 端口配置（`dongzuo.nginx`）→ 媒体 URL 却是 https://dongzuo.gongxiang.cloud —— **TLS 配置 UNVERIFIED，列为发布风险**。

### 第 16 章 部署资源、供应商路由和成本 — PARTIAL

- fast/reasoning/vision/fallback 分模型路由 PARTIAL：三供应商按优先级+能力路由（图片→MiMo；同意 v2 解锁全部），无按任务类型（fast/reasoning）显式分层——但输出上限按 kind 分级（3072-12288 tokens，`ai_core.py:1300-1304`）实质等效。
- 供应商不可用降级 EXISTING（熔断+故障转移+维护开关 accepting）。
- 成本保护 PARTIAL：任务级 token 上限+配额+去重 EXISTING；**token/成本台账 MISSING**（attempts 有 token_usage 字段——`server.py:818-826` 供应商遥测含 token 用量，但无成本估算/告警/按用户套餐配额映射）。
- 统计计算不靠 LLM EXISTING（club_progress 服务端 SQL/PHP 计算；营养总量服务端重算 `food_core.py:33-34`；训练反馈服务端定色）。
- 管理后台 EXISTING（AI 服务中心：容量/供应商/实时/任务审计 + 推送预算 + 配置 draft/publish/rollback）；**"控制台→客户端生效"闭环 PARTIAL**（服务端生效点存在；客户端不消费 ai/club 开关 = 历史问题⑩）。
- 2C2G 基础设施 UNKNOWN（包内文档口径；cgroup 内存守卫的存在暗示资源紧张，`server.py:27-64`）。

### 第 17 章 性能、稳定性与异常处理 — PARTIAL

降级等级现状：

| V2 等级 | 现状 |
|---|---|
| L0 全功能 | EXISTING |
| L1 单模型不可用 | EXISTING（熔断/故障转移/供应商禁用后台开关） |
| L2 AI 全不可用 | EXISTING（AI 域报错文案"输入仍在本机"，训练/记录不受影响；`weekly.php:66-69` 等） |
| L3 后端不可用 | EXISTING（本地保存+waiting 重试；只读历史走本地） |
| L4 数据库故障 | PARTIAL（服务端 503 文案统一；客户端"未同步"标识=CloudSyncStatus；无显式"服务端写入暂停"区分） |

历史 10 问题逐条核对（Phase 0 义务）：

| # | 问题 | 现状判定 | 证据 |
|---|---|---|---|
| 1 | 首页中断其他 App 音频 | **未修复（机制仍在）** | 首页静音循环视频无 AVAudioSession 配置（`HomeWorkoutVideo.swift:5-27`、`HomeView.swift:254`）；无 `.mixWithOthers` |
| 2 | 组间休息按钮 bug | 已修复+仍有小瑕疵 | 计时跨页/重启存活（`ClubAutomation.swift:188-232`）；−15s 钳制 `Date()`（`WorkoutView.swift:478-483`）；暂停时跳过写 owner 0 被忽略（`:446`，无害） |
| 3 | AI 提醒关闭后复现 | **未修复** | 胶囊关闭仅 `@State dismissedID` 不持久化（`DesignTokens.swift:943`）；进行中变体不可关闭（`:1003`） |
| 4 | 识别慢/取消失效 | 大幅改善 | 轮询 2-15s+10 分钟截止；取消 `markConsumed` 迟到结果不覆盖（`AIService.swift:539-549`、`MealEditorView.swift:277-287`）；"慢"本身受任务式架构限制（无流式） |
| 5 | 识别动画卡顿 | PARTIAL/UNVERIFIED | 动画 TimelineView 30fps（`Design.swift:263-290`）；无实测证据 |
| 6 | 识别后首页滚动卡顿 | UNVERIFIED | 风险点定位（动画 keyed 插卡 `MealEditorView.swift:94-95`）；无 profile 数据 |
| 7 | 身体面板只显示体重 | 已修复 | 7 指标可配置（`HealthOverview.swift:6-16,109-120`） |
| 8 | 图表难懂 | PARTIAL | 首页趋势图无 x 轴标签（`HealthOverview.swift:175-180`）；体重图有轴（`BodyWeightView.swift:193-204`） |
| 9 | 页面过长/文字过多 | PARTIAL | 首页多卡堆叠（`HomeView.swift:69-94`）；NutritionView 长滚动（`NutritionView.swift:31-102`）；WorkoutView 已用 DisclosureGroup 缓解 |
| 10 | 后台配置不生效 | **未闭环** | 服务端拦截 `/club/*`、AI 任务；客户端 aiEnabled/clubEnabled 解码后从未读取（`AccountService.swift:142-166`） |

性能基线（首屏/掉帧/内存/崩溃）：**全量 UNVERIFIED**——包内无 Instruments/_metricKit 证据，仅有编译检查脚本。Phase 1 前必须建立基线（04 号报告）。

### 第 18 章 安全、隐私、风控 — PARTIAL

- 已有（强项）：服务端鉴权全覆盖（Bearer+会话过期+账号状态）；密钥零提交（env 生成，`deploy.sh`）；PDO 预处理全覆盖；输出脱敏（`publicAIResponse` 剥供应商错误/密钥模式 `ai-response.php:49-60`）；PHP 异常只记类名（`index.php:930-935`）；Python 端不接触真实用户 ID（HMAC quota_owner）；HTTP 访问日志关闭（`server.py:972-973`）；照片 payload 用后即清；NoRedirect 防凭据转发；注入抗性提示+全输出校验；传输数据最小化（automation 过滤字段白名单 `process-club-automation.php:63-73`）。
- 缺口：**BOLA/IDOR 专项测试面 MISSING**（代码上 media/club/jobs 均按 user_id 过滤，如 `index.php:803-806`，但无自动化越权测试）；管理后台鉴权机制（admin-session）需渗透式复核（UNKNOWN）；**裸 IP HTTPS 证书** UNKNOWN；`dongzuo` 媒体域 TLS UNKNOWN；rate limit 仅 nginx 层（API 逻辑层无限流，AI 有配额）；敏感日志审计（含健康数据）无定期审查证据；备份恢复演练 UNVERIFIED（README 自认"备份成功记录不能替代恢复演练"）。
- 高风险内容处理 PARTIAL：疼痛主诉→禁止处方 EXISTING（`weekly_core.py:147-150`）；危险减重/过度训练红线未见显式规则（UNKNOWN→需补）；无医疗求医指引文案证据（需在 V2 prompt 契约中补）。

### 第 19 章 渐进式迁移与退出机制 — MISSING（体系）/ PARTIAL（纪律）

- feature.ai_native_home 等六开关体系 MISSING（无客户端 Flag 系统；服务端 app_config 仅 5 键且客户端不消费 2 个）。
- 灰度（内部→TestFlight 小流量→扩大）MISSING（无灰度组/分桶设施；TestFlight 配置存在 `BOJI_TESTFLIGHT`）。
- expand→dual-read→reconcile→cutover→contract 迁移方法 MISSING（从未需要——业务从未有领域表；首次引入时必须执行）。
- 无 .git 版本控制（交付包形态）→**回滚能力依赖人工 zip 备份**，为 P0 风险（03 号报告）。

### 第 20 章 测试矩阵与上线准入 — PARTIAL

- 已有：大量规则回归测试（tests/ 213 项：PHP 隔离接口测试、Python 生成器产出的 Swift 规则测试、构建检查脚本 ~40 个 `check-*-on-mac.sh`）；UITests 6 个场景（`BojiClubUITests.swift`：Tab 壳/动作库 sheet/计划日历展开+移动预览/迷你条跨 Tab+重启持久/仅确认容量完成/Club AI 单层导航）。
- 缺口：测试是否接入 Xcode 工程 test target 逐项 UNVERIFIED（需 `xcodebuild test` 实测，本机 Xcode 26.6 可执行——04 号报告给出命令）；**无 CI**；无 E2E UC-01..05；无故障注入测试；无支付沙盒自动化；无性能/设备矩阵基线；PHP 测试本机无 php 二进制无法跑（需 docker 或服务器）。
- P0 阻断项对照（V2 20.2）：当前无证据表明存在"训练丢失/重复记录/越权/权益误判"——但**也无反向测试证明**，全部 UNVERIFIED。

### 第 21 章 产品运营与定量验证 — MISSING

- 无埋点体系（无 Analytics 依赖，grep 无 Analytics/Telemetry 框架）；后台统计为运营统计非产品漏斗；无 A/B 或对照实验设施。V2 指标（开始训练成功率/AI 采纳率等）需新建。

### 第 22 章 待 Phase 0 确认的关键决策 — 逐条回答

| # | 问题 | 审计答案 |
|---|---|---|
| 1 | SwiftUI/UIKit 比例、最低 iOS、RootRouter | **纯 SwiftUI**（无 UIKit 视图层，仅 UIViewRepresentable 3 处：相机预览/图表支撑）；**iOS 17.0**；无 Router——TabView+fullScreenCover+分层修饰符 |
| 2 | API 语言/框架、身份、WS/SSE、数据库、迁移工具 | 后端**两套**：PHP 8.2 无框架（账号）+ Python 3 标准库（AI worker/动作库）；身份=自研 Bearer session（Sign in with Apple 签发）；**无 WS/SSE**；DB=MariaDB（账号）+SQLite（AI）；迁移=手写 SQL 文件+ migrate-*.php（无版本化迁移工具） |
| 3 | 正式训练/日历/组次/食物/身体/目标的存储 | **全部在客户端 SavedState JSON 文档**（`Models.swift:401-426`），云端=app_states 单行+cloud_parts 分片；服务端仅 profiles 投影 |
| 4 | HealthKit 授权/同步/anchor | 读 12 类+写 workout；按需查询+60s 缓存+逐日分享同意；**无 anchor/observer/后台交付** |
| 5 | StoreKit/RevenueCat、entitlement 权威 | RevenueCat SDK（StoreKit2 后端）；**服务端 membership_entitlements 为权威**（webhook+REST+admin 三源 recompute） |
| 6 | 俱乐部成长规则/后台审核/库存/兑换 | club_tasks 6 指标由服务端从同步状态计算（AI 任务核验防刷）；后台管理成长季/徽章/礼品/发货/库存；实物=申领（地址电话）+发货跟踪，非兑换码 |
| 7 | AI 网关/供应商/缓存/日志/敏感传输 | 自研路由：LongCat/MiMo/DeepSeek（OpenAI 兼容）；熔断+故障转移+同意域路由；SQLite 遥测（无请求级成本台账）；健康/照片数据按同意域发第三方（fail-closed） |
| 8 | 2C2G 是否准确、环境隔离 | **UNKNOWN**（包内文档未给规格；单主机确认；生产/预发布隔离**不存在**——仅一个生产环境+本机开发） |
| 9 | 历史 bug 是否已解决 | 见 §17 表：#2/#7 已修；#1/#3/#10 未闭环；#4 大幅改善；#5/#6 UNVERIFIED；#8/#9 PARTIAL |
| 10 | TestFlight 状态/审核素材 | TestFlight 构建配置存在（`BOJI_TESTFLIGHT`）；提审状态/演示账号 **UNKNOWN**（需 App Store Connect 访问）；隐私清单/订阅本地化/权限文案已备 |

### 第 23 章 执行约束 — PARTIAL（文化已建立，工程设施未跟上）

- 包内 ~180 个修复文档+验证 JSON+审计 ID（AUD-xxx/FIX-xxx/DI-xxx/R01…）显示"先审计后修、每步验证"的纪律已存在。
- 但**无版本控制/无 CI/无灰度**使该纪律依赖人工；V2 阶段必须补工程设施（03/04 号报告列为前置条件）。

---

## 2. CONFLICT 清单（必须先做产品/架构决策再动工）

1. **导航模型**：5-Tab vs 双模式+Sidebar（V2 已决定 B 方案——需按 UI 规范新建 Shell，旧 TabView 作为回退保留）。
2. **数据权威模型**：客户端单文档 vs V2 领域表/Single Writer（决定 Phase 2/3 的写入路径与 commands.php 的扩展方式）。
3. **Context Builder 方向**：现状"客户端提交记录上下文"（信任客户端）vs V2"服务端按意图拉权威数据"（需服务端可读业务数据——当前服务端只有文档 JSON，可解析但无查询层）。
4. **parse_plan（AI 整理文字计划）入口**：V2 说不恢复，现实存在且在用。
5. **流式 vs 轮询**：V2 倾向 SSE；现实全链路任务轮询。建议：Phase 2 保持轮询语义+协议对齐（V2 12.2 允许），Phase 2.5 视体验数据决定是否投 SSE。
6. **远程推送**：服务端 APNs 全备、客户端默认编译关闭且 entitlement 缺失——V2 主动洞察依赖推送，需产品+证书决策。

## 3. UNKNOWN 清单（需生产环境/真机验证）

生产服务器与 DB 状态、2C2G 规格、TLS 证书有效性（裸 IP + dongzuo 80 端口）、TestFlight 提审状态、RevenueCat 控制台配置、APNs 证书/环境、备份恢复演练、性能基线（首屏/掉帧/内存）、历史 bug #5/#6 实测、管理后台鉴权强度、`tests/` 中生成测试在 Xcode 工程中的实际挂载情况。
