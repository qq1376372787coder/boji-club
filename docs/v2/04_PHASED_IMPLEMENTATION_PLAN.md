# BOJI CLUB V2.0 · Phase 0 审计报告 04：分阶段实施计划（PHASED IMPLEMENTATION PLAN）

- 依据：主指令五阶段划分 + UI 专项规范 + 00/01/02/03 号审计结论
- 原则：先基建后 UI、旧界面全程可回退、每阶段附证据清单、不重写已稳定业务

---

## 0. Phase 0 退出条件与前置整改（立即执行，1–3 天）

Phase 0 已产出五份报告（本目录）。**进入 Phase 1 前必须完成的整改**（对应 03 号风险 P0/P1 门槛）：

| # | 整改 | 验证方式 |
|---|---|---|
| P0-A | **git init + 全量首提交 + tag `v0.15.1-b114-baseline`**（R-01） | `git log` 有基线 tag；`.gitignore` 复用包内已有 |
| P0-B | **服务器 root 密码轮换 + 改密钥登录**（R-21b，运维立即执行，不阻塞代码） | 运维记录 |
| P0-C | **本地可运行测试基线**（R-02/R-04）——**审计中已实测**（`docs/v2/evidence/phase0/test-baseline.md`）：①Python 离线 **640/640 OK** ✅②Swift 规则链 **29/52** ❌（R-41：生成器过期，需修复或冻结）③XCUITest **21/21 passed** ✅④主应用模拟器编译 **SUCCEEDED** ✅。剩余整改：把三套件+xcodebuild 纳入 CI；修复 R-41；PHP 套件 docker 化 | CI 首次全绿截图 + R-41 闭环记录 |
| P0-D | **性能/体验基线采集**（R-16）：Instruments Time Profiler + MetricKit 挂 Debug 构建，记录：冷启动首屏时间、首页滚动掉帧、训练页内存、对话提交→首字延迟（现状为轮询首响应） | 基线数据入 `docs/v2/evidence/phase0/baseline.md`；Phase 1 验收阈值以此为准 |
| P0-E | **产品决策清单签认**（02 号报告 §2 CONFLICT 六项）：导航模型（已定 B 方案）、数据权威模型（本文 §3 建议 A 路线）、Context Builder 方向、parse_plan 入口去留、流式 vs 轮询（建议 Phase 2 轮询起步）、远程推送是否本期启用 | 决策记录 `docs/v2/DECISIONS.md` |

PHP 测试（39+4 个）本机无法运行（无 php）：**不阻塞** Phase 0/1，纳入 CI 后以 docker（php:8.3 + MariaDB）执行，或每次服务器部署前在服务器跑（现状 38/38 有记录）。

---

## 1. Phase 1：App Shell / Design System / Feature Flag 基建

**目标**：交付 `Club AI | 训练` 双模式 Shell + Sidebar + 留白工作台 + Composer 骨架 + 训练中心重组，全程 Feature Flag 控制、旧 TabView 一键回退。

### 1.1 工作项（按依赖顺序）

1. **FeatureFlagService**（R-03，先于一切 UI）：
   - 客户端本地 Flag（默认值）+ 服务端 `GET /account/v1/config` 下发合并（复用 `ClubRemoteConfig` 通道，`AccountService.swift:142-166`）；**补齐 ai_enabled/club_enabled 消费**（历史问题⑩闭环：AI 入口/俱乐部入口真实拦截+公告展示）。
   - 新增键（服务端 app_config 扩展，向后兼容——appConfigNormalize 已拒绝未知键，需同步加白名单 `app-config.php:11-19`）：`feature_ai_native_home`（默认 false→灰度开）、`chatgpt_inspired_shell`。
   - 验证：后台改开关 → `/config` ETag 变化 → 客户端下次启动/前台刷新生效（120s 循环已有，`BojiClubApp.swift:273-291`）。
2. **DesignTokens 补全**（UI 规范 C 节）：现有 `BojiColor/Space/Radius/Font` 已覆盖 80%（brandMist=#E3E7F0 已在 `DesignTokens.swift:24-26`）；补：Header 高度 52-60pt、模式胶囊 40-46pt、Composer 高度 72-112pt、Sidebar 宽度 min(88% 屏宽, 360pt) 语义常量；收敛三套并存系统（ClubUI shim 保持转发、FlowPalette 冻结不再扩散）。
3. **AppShellView 新结构**（独立文件组 `BojiClub/Shell/`，不动旧 MainClubView）：
   ```
   AppShellView（feature_ai_native_home ? 新壳 : MainClubView 旧壳）
   ├─ RootHeaderView[SidebarToggle, ClubModePicker(Club AI|训练), ContextAction]
   ├─ MainModeContainer
   │   ├─ ClubAIWorkspaceView（Idle 留白态 / Conversation 态）
   │   └─ TrainingHubView（复用 ClubPlanHub+WorkoutView 路由，重组为 今日训练→开始→计划/日历→最近）
   ├─ SidebarHostView（历史对话占位/我的记录/俱乐部/AI 对我的了解(占位)/我的/设置）
   └─ ComposerView（+ 菜单/多行文本/相机/麦克风/发送，先骨架）
   ```
   - 状态：`ClubAIFlowState`（新 ObservableObject，R-34：不进 AppStore god-store）、`TrainingFlowState` 复用现有训练持久化（ClubRestStorage/ClubWorkoutPauseStorage 语义不变）、`ComposerDraftState`。
   - 模式切换保留：conversation_id/草稿（复用 `ClubCoach.swift:101-116` 草稿机制）/滚动位置/待确认卡；训练 workout_session_id 独立生命周期（现状已满足：fullScreenCover+持久化，迁移时保持）。
   - Sidebar 各入口全部连到现有页面或显式占位路由（不删功能）：我的记录→ClubRecordsHub、俱乐部→ClubSeasonView、我的→ProfileView、设置→新 SettingsStack（从 ProfileView 抽取）。
4. **音频修复**（R-13，随本 Phase）：`HomeWorkoutVideoBackground` 播放前配置 `AVAudioSession` `.ambient`+`.mixWithOthers`（或直接以静态图替代视频，二选一由产品定）；新增回归：冷启首页 + 后台 Apple Music 不中断（真机）。
5. **胶囊提醒重做**（R-14）：`ClubAIAmbientPill` dismiss 持久化（per-day，UserDefaults）+ 任务进行中态仅在完成/取消后消失。
6. **UI 测试先行**：为旧 5-Tab 壳补齐回归（现有 21 个 UI 测试为主），再写新壳测试（模式切换 20 次草稿/滚动/训练态保持、Sidebar 开合、键盘避让、VoiceOver 顺序）。

### 1.2 Phase 1 验收证据（对应主指令十项交付证据）

1. 修改文件清单（Shell/ 新文件 + FeatureFlagService + DesignTokens 增量 + HomeWorkoutVideo 修复）。
2. 无数据库迁移（app_config 白名单扩展为向后兼容，无 DDL）。
3. 契约：`/config` 响应新增 2 键的兼容性说明（旧版本客户端忽略未知键——已核实 ClubRemoteConfig 解码行为）。
4. 测试：新增 UI 测试名称 + `xcodebuild test` 结果；`run_offline.py`/`run_swift_regressions.py` 回归。
5. 模拟器多机型（iPhone SE/标准/Pro Max）浅深色截图：首页空态/洞察态/对话态/Sidebar/训练中心/键盘展开（≥7 组，UI 规范 H 节）；**真机限制如实声明**（本机无签名证书则标注 UNVERIFIED）。
6. 音频回归证明（真机或模拟器+音乐 App 并行）。
7. 性能对照 Phase 0 基线（冷启动/掉帧/内存无显著倒退，阈值=基线±10%）。
8. 回滚验证：`feature_ai_native_home=false` 恢复旧 TabView 且训练/记录数据无损。

---

## 2. Phase 2：对话接入真实数据 + 只读卡片

**目标**：Club AI 可查询当天训练/历史/记录并返回结构化卡片；卡片协议双向契约测试。

### 2.1 工作项

1. **卡片协议先行**（R-35）：
   - 定义 `card envelope` JSON Schema：`card_id/card_type/schema_version/title/payload/actions[]/evidence_refs/created_at/expires_at/presentation`（对齐主方案 6.1）。
   - 首批只读卡：`today_training`、`training_progress`、`insight`；空态定义（无数据→空卡文案，禁止 AI 编造）。
   - iOS `CardRegistry`：编译期 SwiftUI View 注册表 + `type/version` 解码器 + loading/loaded/expired/error/empty 状态 + actionId 白名单映射（复用 coach 7 动作白名单 `coach_core.py:98-102` 为客户端路由依据）。
   - 双方契约测试：服务端产出样例 JSON → iOS 解码快照测试；Schema 版本化（旧卡降级策略）。
2. **服务端 Card Composer**（backend 新模块 `card_composer.py`）：在现有 job 结果（report/coach）之上组装卡片；**只读卡数据从服务端权威数据组装**——注意现状 CONFLICT：服务端只有同步文档 JSON。Phase 2 最小方案：Card Composer 解析 account-server 传入的已同步状态（信任边界=与现状 coach 相同），同时启动 §3 数据投影。
3. **对话域增强**：
   - 服务端会话存储（新表 `ai_conversations/ai_messages`，见 §3 迁移 M-1）：历史从"客户端携带 6 组"升级为服务端分页；`conversation_id` 复用现有语义。
   - Intent Router 最小版：`chat / query / draft_create / change_proposal` 四分类（先规则后模型，job kind 之外的新字段，向后兼容）。
   - Context Builder：按意图最小拉取（今日计划/最近 N 次训练/饮食摘要/身体趋势），数据来自同步文档的服务端解析。
4. **流式决策落地**：默认保持轮询（12.2 允许）；若决策选 SSE：`/me/ai/jobs/{id}/events` 增量端点（nginx `X-Accel-Buffering: no`），客户端 URLSession bytes 流。**先不投**——对话延迟基线（Phase 0-D）显示轮询首响应可接受则延后。
5. **首页洞察接入**：Idle 工作台 0-1 条主洞察改为服务端 `/insights/home`（新端点，读 report_archive+club 进度+计划日历，全部带 evidence_refs）——替代纯本地 ClubInsightRules（本地规则保留为离线兜底）。

### 2.2 验收

AI 回答"今天练什么"返回 today_training 卡（payload 来自真实计划）并可一键开始训练（复用现有 trainingRoute 深链）；无数据返回空态；卡片跨版本渲染；无跨用户读取（越权契约测试 R-22 首批）；离线时训练/记录全可用（回归）；`ai_conversations` 迁移含回退路径（§3 M-1）。

---

## 3. 数据库迁移与数据权威策略（Phase 2–3 通用，对应 R-07 决策）

**现状**：业务数据=客户端 SavedState 单文档（云=app_states/cloud_parts）；服务端仅 club_progress/报告为派生。**建议路线（expand-and-contract）**：

| 步骤 | 内容 | 回退 |
|---|---|---|
| M-0 | 领域读投影表（expand）：`training_plan_versions / workout_sessions / meal_entries / body_entries`，由同步事件或 PUT /me/state 提交时**服务端解析文档填充**（只读副本，标记 source_revision） | 直接 DROP（纯投影，权威仍是文档） |
| M-1 | `ai_conversations / ai_messages / ai_message_cards`（新能力，无回退问题——旧版客户端不读） | 表保留不删 |
| M-2 | `ai_action_proposals / ai_action_executions`（V2 11.1 结构；`data_operations` 保留为总审计流，新增 awaiting_confirmation 等状态由 proposals 表承载） | proposals 状态机停用即回退到现有 commands.php 语义 |
| M-3 | 双读验证期（reconcile）：投影表 vs 文档解析对比任务（复用 data_integrity_engine DI 规则风格），差异报表入后台 | — |
| M-4 | （远期，需独立评审）cutover：领域表成为权威、文档降为传输格式 | contract 前必须有完整回放重建脚本 |

**规则**：任何阶段不删除/不修改 app_states/cloud_parts 结构；所有新表带 `user_id` 外键+索引；迁移文件进 `account-server/migrations/`（沿用日期前缀命名）+ 漂移检测（复用 migrate-v2-quality.php 模式）；部署走 `deploy-experience-sync.sh`（哈希校验+自动回滚）。

---

## 4. Phase 3：AI 草稿与经确认写入

**目标**：meal_draft / weight_entry / plan_change_proposal 三类卡 + Proposal 状态机 + 确认写入幂等。

1. **Proposal 状态机**（服务端 `ai_action_proposals`）：`draft→validated→awaiting_confirmation→executing→succeeded`，旁路 `rejected/expired/conflict/failed/cancelled`；确认瞬间重读版本与权限（主方案 9.3）；`idempotency_key` 唯一索引（结构已存在于 `ai_action_executions` 设计）。
2. **命令通道扩展**（`commands.php`，R-10）：新增 `Meal.Create / BodyWeight.Create / PlanReschedule.Confirm`；**必须支持 _partitioned=2 账号**（改走 /me/state 分区提交或分区感知命令）；保留现有 CAS+审计+Outbox 语义。客户端首次接入命令通道（当前无调用点）。
3. **Outbox 真实消费者**（R-08）：`ScheduleMoved/ScheduleReplaced` → ①作废相关 ai_insights ②重建提醒计划；死信入后台可见面板（`dead_letter` 状态已有字段）。
4. **餐食/体重草稿卡**：AI 识别结果→`meal_draft` 卡（estimated 标记沿用 `food_core.py:63`）→用户编辑→确认→`Meal.Create` 命令→幂等写入文档（appliedAIJobs 语义保持）→NutritionLogged 事件。
5. **验收**：重复提交/并发修改/过期提案/断网确认/两设备同时确认，各自有确定结果（专项测试矩阵）；失败补偿路径可演示（compensated 状态已有）；训练/饮食离线可用回归通过。

## 5. Phase 4：长期记忆 + 主动洞察

1. Memory Store（`user_memory_items` 六类型+置信度+有效期+纠错链）；**数据最小化**：仅从已确认事实与足量行为样本提取（复用 automation 的最小样本门槛思想 `automation_core.py:101-194`）；敏感健康记忆单独存储策略。
2. "AI 对我的了解"页（Sidebar 入口落地）：三栏（确认事实/观察习惯/待确认推断）+ 查看/纠错/删除/暂停个性化；删除走队列模式（复用 account_deletions 模式，R-37）。
3. 主动程度三档（安静/平衡/积极）映射到现有 automation daily/weekly/workout + push budget（proactive_daily_limit）——设置页升级为三档选择+细粒度开关。
4. Insight 排序评分（relevance+timeliness+confidence+actionability−repetition−disruption，权重 Phase 4 调参）；同类去重/证据失效撤销（evidence_refs 过期联动）。
5. 反馈闭环：曝光→接受→执行→结果 链路记录（扩展 ClubActionRecord 为服务端事件）。
6. **远程推送决策落地**（R-28）：若启用——补 entitlement+`BOJI_REMOTE_PUSH` 开启+APNs .p8 配置（服务端栈已全备 `club-push.php`）+设备验收。

## 6. Phase 5：俱乐部/订阅/运营完整联动

1. `club_progress` 卡 + 徽章/Keepsake 进度卡（数据全部来自服务端 club_progress——权威已就绪）；领取仍走确定性 claim 端点（AI 只解释，R-04 红线维持）。
2. AI 成本看板（`ai_usage_ledger`：按请求 token/成本/延迟，扩展现有 attempts 遥测）；对话维度配额。
3. 灰度：app_config build 白名单 → TestFlight 分组；指标看板（R-31 最小埋点 6-8 事件：新首页开始训练成功率/AI 首页→训练耗时/饮食记录完成率/卡片可用率/建议采纳率/错误率）。
4. TestFlight 正式外测前的 20.2 P0 清单全项复核（R-29 四阻断+法律定稿）。

---

## 7. 每阶段通用证据包（模板，对应主指令"十项交付证据"）

```
docs/v2/evidence/phaseN/
├── 01_files_changed.md          # 路径+功能描述
├── 02_migrations.md             # DDL+回退路径（无则声明"本阶段无迁移"）
├── 03_contracts.md              # API/Card/Event schema 与兼容性
├── 04_tests.md                  # 测试名+命令+通过/失败/未运行
├── 05_device_results.md         # 真机/模拟器结果+环境限制声明
├── 06_screenshots/              # 首屏/对话/侧栏/训练/键盘 多机型浅深色
├── 07_regression.md             # 历史 10 bug + 本阶段新 bug 回归表
├── 08_security_privacy.md       # 权限/日志/数据流变更审查
├── 09_performance.md            # 对照 Phase 0 基线的指标
└── 10_go_no_go.md               # 继续/阻断/回滚建议
```

**固定回归命令集**（每阶段执行；Phase 0 实测结果见 `evidence/phase0/test-baseline.md`）：
- `python3 -I tests/run_offline.py`（Python 离线——实测 640 项全过）
- `python3 tests/run_swift_regressions.py --output /tmp/boji-rules --jobs 3`（**实测 29/52，修复 R-41 前以实际数字为准，禁引 51/51**）
- `xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -destination 'platform=iOS Simulator,name=iPhone 17' test`（UI 测试——实测 21/21 过）
- `bash scripts/check-on-mac.sh`（编译检查）
- PHP 套件（docker 或服务器）：`BOJI_TEST_DSN_BASE=… tests/run_php_suite.sh` + 补跑 `tests/php/` 4 个（R-39）
- 管理端 HTTP：`BOJI_ADMIN_BASE=… python3 -m unittest tests.test_admin_v2_http tests.test_feature_gates_http -v`

## 8. 阶段门禁汇总

| 阶段 | 准入 | 退出（DoD） |
|---|---|---|
| Phase 0 | 本审计 | 五报告评审通过 + P0-A~E 完成 |
| Phase 1 | P0 退出 | UI 规范 H 节验收清单（多机型/浅深色/键盘/VoiceOver/切换保持/音频不中断/性能不倒退）+ Flag 回退演示 + 训练/记录路径完整 |
| Phase 2 | 数据路线决策（§3）签认 | 只读卡真实数据可查证、越权测试、空态正确、离线不依赖 AI、契约测试进 CI |
| Phase 3 | M-2 迁移评审 | 幂等/并发/过期/补偿全矩阵通过、Outbox 消费者可观测、离线写入回归 |
| Phase 4 | 记忆设计评审（法务过目 R-32） | 洞察全带证据、记忆可删、关闭个性化即停学、无高频刷屏 |
| Phase 5 | TestFlight 阻断清零 | 权益/奖励零错误、成本看板在线、灰度数据回收、20.2 P0 全绿 |

## 9. 明确不做（本期）

- 不替换 5-Tab 旧壳的底层代码（仅用 Flag 遮蔽切换，稳定一个版本周期后评估下线）。
- 不引入 HealthKit anchor/observer 后台同步（现有按需+同意模型满足当前产品；若 V2 需要增量，另立设计评审）。
- 不上微服务/独立向量库/本地大模型（单主机 2C2G 现实约束；现有 SQLite+MySQL+内存守卫架构够用）。
- 不让 LLM 任何形式直写业务数据、不生成远程 UI 代码（红线维持现状设计）。
