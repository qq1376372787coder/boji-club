# BOJI CLUB V2.0 · Phase 0 审计报告 01：功能清单与数据流图（FEATURE & DATA FLOW MAP）

- 审计对象：BojiClub 0.15.1 Build 114（UIUX-v3 精简减负版，2026-10-23）
- 本报告给出：A. 功能清单（含真实入口与代码位置）；B. 功能依赖图；C. 核心数据流（端到端）；D. 数据所有权矩阵；E. 对 V2 五条用户故事的现状预演。

---

## A. 功能清单（按用户可见入口）

### A.1 iOS 导航与入口

| 功能 | 入口 | 实现位置 |
|---|---|---|
| 启动/阶段门（登录→Onboarding→主界面/会员门） | 自动 | `BojiClubApp.swift:92-107` |
| 5 Tab：首页/计划/记录/俱乐部/自己 | TabView | `BojiClubApp.swift:423-469` |
| AI 状态胶囊（环境提示） | 全局浮层 | `DesignTokens.swift:937-1100` |
| 进行中训练迷你条（跨 Tab 常驻） | 全局浮层 | `TrainingRegistrationViews.swift:777`，`BojiClubApp.swift:410-420` |
| 训练全屏页 | Tab 内卡片/迷你条/深链 | `BojiClubApp.swift:520-534`（fullScreenCover） |
| 通知点击路由（本地通知→页面 sheet） | 系统通知 | `BojiClubApp.swift:187-207` |
| 深链 `bojiclub://training?date=` | Widget/Live Activity | `BojiClubApp.swift:505-512` |

### A.2 首页（HomeView，1,202 行）

| 功能块 | 说明 | 位置 |
|---|---|---|
| 头部问候/账号信息 | — | `HomeView.swift:69-94` |
| 身体概览卡（7 指标可配置） | HealthKit 按需查询 | `HealthOverview.swift:54-128` |
| 训练 hero 视频 | **静音循环 MP4**（音频中断风险源） | `HomeWorkoutVideo.swift:5-27`、`HomeView.swift:254` |
| 今日训练卡/快捷动作 | 进入训练 | `HomeView.swift`（详见报告 00 §2.4） |
| 餐食卡 | 进入饮食 | `HomeView.swift` |
| AI 洞察 top1 + 时间线 | 本地规则事实 | `HomeView.swift:721-777`、`ClubInsightTimelineView.swift:348` |

### A.3 计划域

| 功能 | 说明 | 位置 |
|---|---|---|
| 计划中心（今日条+月历） | `ClubPlanHub` | `ProductArchitecture.swift:24-189`、`PlanHubViews.swift:18-53` |
| 计划创建（6 入口） | 自己安排/AI 帮我安排/重复计划/模板/AI 整理文字/补记 | `PlanManagement.swift:8-63` |
| AI 计划生成（7/14/28 天） | 任务式、预览可编辑、**采纳需 Diff** | `PlanView.swift:18-614`、`AppStore.swift:1299-1394` |
| 计划版本历史 | ClubPlanVersion 快照+前后变更 | `ClubHistory.swift:213-239`、`ProductArchitecture.swift:191-348` |
| 手动计划编辑器 | 28 天数组 | `ManualPlanView.swift`（634 行） |
| 批量改期（两阶段） | 冲突分类+指纹守卫 | `AppStore.swift:2601-2743`、`PlanShiftViews.swift:340` |
| 单日提前至今日 | 需先云同步 | `AppStore.swift:1396-1452,631-656` |
| 计划生命周期（结束/归档） | 不可变墓碑 | `ClubHistory.swift:259-301`、`AppStore.swift:2798-2813` |
| 计划解释（AI） | 服务端确定性事实+模型散文 | `PlanExplanation.swift`、backend/`plan_explanation.py` |

### A.4 训练域

| 功能 | 说明 | 位置 |
|---|---|---|
| 训练会话（同日多练） | workoutSessions + activeWorkoutSessionID | `Models.swift:214-303`、`WorkoutView.swift:331-343` |
| 组次记录（重量/次数/时长） | 乐观并发重校验 | `WorkoutView.swift:780-805`、`AppStore.swift:895-915` |
| 组间休息计时（跨页/重启存活） | UserDefaults 持久化+本地通知 | `ClubAutomation.swift:188-232`、`WorkoutView.swift:433-515` |
| 整场暂停 | 独立持久化 | `ClubAutomation.swift:112-186` |
| 结束训练（local-first 保存） | 1.2s 防抖云同步 | `AppStore.swift:929-939,675-769` |
| 完成页（HealthKit 写入/交接下周） | opt-in | `WorkoutView.swift:956-1126` |
| Live Activity + 灵动岛 | 系统驱动计时 | `TrainingLiveActivityWidget.swift`、`AppStore.swift:2227-2290` |
| 今日训练 Widget | app-group 快照 | `TodayTrainingWidget.swift:29-38` |
| 训练反馈徽章（绿/黄/红） | **服务端定色**，模型只写文字 | `AIViews.swift:29-80`、backend/`training_feedback.py` |
| TCX 导入 | — | `TCXImport.swift` |
| 补记训练 | 计划创建入口之一 | `PlanManagement.swift:8-63` |

### A.5 记录域（ClubRecordsHub：训练/饮食/身体/报告）

| 功能 | 说明 | 位置 |
|---|---|---|
| 训练记录仪表盘 | — | `ReviewDashboardView.swift` |
| 饮食记录 | 长滚动+底部 dock | `NutritionView.swift:31-102` |
| 拍照识别（单餐/多餐 batch） | 任务式 AI 识别、草稿确认、可取消 | `MealCamera.swift`、`MealEditorView.swift:972-982,277-287`、`MealBatchReviewView.swift:37` |
| 语音餐食输入 | SFSpeech 本地识别（唯一 AVAudioSession 使用点） | `MealSpeechInput.swift:47-49,109` |
| 文字理解餐食 | 规则式 | `MealSpeechInput.swift:123-217` |
| 餐食草稿（多草稿/恢复） | JSON+jpg | `MealEditorView.swift:775-911` |
| 营养目标 | nutritionTarget | `Models.swift:401-426` |
| 身体记录（体重/体脂/腰围） | 手动+HealthKit | `BodyWeightView.swift` |
| 身体趋势图（7/30/90/自定义） | **x 轴缺失（首页卡）** | `HealthOverview.swift:130-222` |
| 日报库 / 周报 | AI 报告阅读器+分享卡 | `ReportLibraryView.swift`、`AIViews.swift:382-492` |
| 记录修复（journal 损坏恢复） | — | `RecordRepairViews.swift:4` |
| 周复盘（含照片/问卷） | 成人就绪校验 | `WeeklyReview.swift`、backend/`weekly_core.py` |

### A.6 俱乐部域

| 功能 | 说明 | 位置 |
|---|---|---|
| 当季成长（任务/进度/奖励） | `/club/current` | `ClubSeasonView.swift`、`ClubSeason.swift:239-416` |
| 徽章/实物 Club Keepsake 申领 | 库存/单件/截止服务端校验 | `index.php:632-688` |
| 发货跟踪/取消/确认收货 | — | `index.php:536-552` |
| 历史赛季+收藏 | AES-GCM 磁盘缓存 | `ClubHistory`、`ClubDiskCache`（`ClubSeason.swift:6-84`） |
| 30 款 Keepsake SVG 素材 | — | `admin-media/club-keepsake-*.svg` |

### A.7 Club AI 域

| 功能 | 说明 | 位置 |
|---|---|---|
| AI 中心（动态/报告/对话 分段） | — | `ClubCoachView.swift:3-53` |
| 对话（非流式，6 组历史客户端携带） | conversation_id + 草稿 | `ClubCoachView.swift:63-264`、`ClubCoach.swift:56-116` |
| 证据引用（sources）+ 白名单动作（7 种） | 服务端强制 | backend/`coach_core.py:79-105` |
| 参数变更提案 proposal（加重需证据） | 程序化校验后进编辑 | `adaptive_core.py:31-55`、`ClubCoach.swift:72-98` |
| 改期提案 schedule_proposal | 仅空日、≤28 天 | `adaptive_core.py:88-116` |
| 日报/训练锐评/周报（自动化） | opt-in，确定性任务 ID | `ClubAutomationService.swift:6-238`、backend/`automation_core.py:101-194` |
| 快捷问题（基于真实记录可用性） | — | `ClubCoach.swift:120-132` |
| AI 配额（北京时间日界） | 429/终态失败文案 | `AIService.swift:146-164`、backend quota |
| AI 路由同意（第三方共享域） | `_routing_version:2` 门控 | `AIService.swift:918-943` |

### A.8 账号/会员/设置

| 功能 | 说明 | 位置 |
|---|---|---|
| Sign in with Apple（唯一登录） | Keychain token | `AccountService.swift:296-318,520-586` |
| Onboarding（资料+计划方式+公约） | 服务端强校验 | `OnboardingView.swift`、`index.php:848-918` |
| 会员购买（RevenueCat 3 商品） | 服务端权威+60s UI 宽限 | `MembershipService.swift:46-592` |
| 会员核验/恢复 | webhook+REST | `revenuecat.php`、`revenuecat-verify.php` |
| 账号注销（两阶段+队列清除） | — | `AccountService.swift:419-451`、`account-deletion.php` |
| 云同步（分区协议+三方合并） | revision 乐观锁 | `CloudSync.swift`、`index.php:690-791` |
| 本地通知中心（训练/餐/休息/复盘） | — | `AppStore.swift:35-297` |
| 远程推送注册（默认编译关闭） | `BOJI_REMOTE_PUSH` | `ClubRemotePush.swift:7,31-68` |
| 自动跟进设置 | 本地+服务端镜像 | `ClubAutomationService.swift:42-146` |
| 通知偏好/免打扰 | — | `club-push.php:135-163` |

### A.9 动作库

| 功能 | 说明 | 位置 |
|---|---|---|
| 动作库浏览/搜索（中文→英文词典） | 678 项策展目录 | `ExerciseLibraryView.swift:80-237` |
| 动作详情（GIF 流式下载） | dongzuo.gongxiang.cloud | `ExerciseLibraryView.swift:746-803` |
| 自定义动作 | customExercises | `Models.swift`、`PERSONAL-EXERCISES-20261010.md` |

### A.10 管理后台（18 页）

运营总览/成员档案/成长季/徽章库/礼品库/发货/消息中心/AI 服务中心（容量/供应商/实时统计/任务审计）/自动化任务/推送管理（预算）/存储/系统状态/操作记录/系统配置（app_config draft/publish/rollback）/管理员与角色/安全设置（`account-server/admin/`，`admin/index.php` titles+navGroups）。

---

## B. 功能依赖图

### B.1 训练主链（V2 依赖图要求 1）

```
计划域 ──→ 训练日历(PlanWeekCard) ──→ 今日训练卡 ──→ WorkoutView 会话
   │                                                    │组次/休息计时（本地持久）
   │                                                    ▼
   │                                              saveWorkout(local-first)
   │                                                    │1.2s 防抖
   │                                                    ▼
   │                                     CloudSync 分区同步 → app_states(revision)
   │                                                    │
   │                          ┌─────────────────────────┼──────────────────────┐
   │                          ▼                         ▼                      ▼
   │                   club_progress 计算          automation prepare      训练反馈(服务端定色)
   │                   （训练日需完成组+SavedAt      → 日报/锐评/周报任务     → AI 报告卡
   │                    + AI 任务核验）                (确定性 ID)              │
   │                          │                         │                      ▼
   └── 计划版本快照 ←──────────┴── 俱乐部任务进度 ←── AI 报告完成核验 ←── report_archive
       (ClubPlanVersion)        (club_tasks metric)   (verifiedAICompletions)
```

### B.2 健康数据链（V2 依赖图要求 2）

```
HealthKit(12 类读) ──按需 StatisticsQuery/SampleQuery──→ HealthDay(day.health, 60s 缓存)
      │                                                        │
      │ 写(仅 HKWorkout, opt-in, 幂等 metadata)                 │ 逐日"分享复盘"同意
      │                                                        ▼
      │                                          sharingSummary(剥离本地字段)
      │                                                        │
      │                     ┌──────────────────────────────────┼─────────────┐
      │                     ▼                                  ▼             ▼
      │            身体趋势(BodyOverview/WeightView)     AI 报告/周复盘上下文   club health_days
      │            （趋势图无 x 轴标签 ←可读性问题）       (consent 路由: 仅MiMo/DS)  (进度指标)
      └─ 无 anchor/observer/background delivery（仅拉取）
```

### B.3 饮食链

```
拍照/语音/文字 ──→ AI food 任务(照片≤4MB JPEG/PNG, base64) ──→ ai_core 同意域路由
      │                                                          │ 纯 AI 估算(无食物库)
      │                                                          ▼
      │                                              meal/meal_batch(服务端重算总量, estimated=true)
      │                                                          │
      ▼                                                          ▼
餐食草稿(JSON+jpg, 多草稿恢复) ←────────────────── 用户编辑确认（草稿≠正式记录）
      │
      ▼ store.addMeal(幂等 appliedAIJobs+稳定id)
DayLog.meals ──→ 云同步 ──→ club meal_days/meal_records ──→ 营养跟进洞察(蛋白检查)
```

### B.4 会话/会员链

```
Sign in with Apple → sessions(token 30d) → /me → membership_entitlements(权威)
RevenueCat 购买 → webhook(去重/TRANSFER/退款) + REST 快照 → recomputeMembership
                                          ↓
                     requireActiveMembership 门控: /club/current, AI 任务(非 onboarding 计划),
                     automation, 实物申领……（onboarding 期间计划任务 ≤5 次豁免, weekly.php:5-19）
```

### B.5 主动触达链

```
用户开启自动跟进(daily/weekly/workout + 时段) ──镜像──→ club_automation(revision CAS)
        │
        ▼ systemd 定时 process-club-automation.php
会员+同意+有数据(35 天窗口) ──→ /v1/automation/prepare(服务端定任务) ──→ AI jobs
        │
        ▼ club-push(若 BOJI_REMOTE_PUSH 开)
APNs(预算 4 类/语义去重/免打扰/账号拉黑) ──→ 通知点击路由到 App 页面
（默认构建：本地通知替代远程推送）
```

---

## C. 核心数据流（端到端）

### C.1 一次组间休息计时（跨页场景）

1. 勾选组完成 → `toggleSet`（`WorkoutView.swift:799-802`）以 `exercise.restSeconds ?? AppStorage(training.rest.seconds)=60s` 设 `restEnd`。
2. `restEnd` 变化 → `ClubRestStorage.save`（UserDefaults，key `club-rest.v1.<owner>.<date>`，会话作用域，≤1h）（`ClubAutomation.swift:188-232`）；安排本地通知（`AppStore.swift:47-66`）。
3. 用户切 Tab/回首页/杀 App：`WorkoutPauseService` + 快照持续；`MainClubView` 保留 `initialRestEnd` 回灌（`BojiClubApp.swift:384-386,523-527`）。
4. 回到训练页 `onAppear` 恢复（`WorkoutView.swift:92-95`）。
5. 训练进行中状态同时驱动：迷你条（跨 Tab）、Live Activity（锁屏/灵动岛）、Widget 快照（app-group）。

### C.2 保存一次训练（含离线）

1. 结束训练 → `saveWorkout` 本地写 `workoutSavedAt/workoutEndedAt`（`AppStore.swift:929-939`）→ journal 追加 → `persist` → dirty。
2. 1.2s 后 `scheduleSync` → `syncNow`：分区协议（manifest/read/uploads commit）→ 服务端 `PUT /me/state` 或分区 commit；revision 不匹配返回 409+远端状态 → 客户端三方合并（`CloudSync.swift:107-188`）。
3. 断网：`waiting` 状态，`NWPathMonitor` 恢复重试（`AppStore.swift:418-437`）。
4. 训练完成后（≤1 天）：automation worker 触发逐训练"锐评"任务（确定性 ID，幂等）。
5. 俱乐部进度在下一次 `/club/*` 请求时重算（训练日=完成组+SavedAt，需 AI 任务核验项另核验）。

### C.3 一次 AI 对话（现状非流式）

```
用户输入(≤1200字) ── POST /account/v1/me/ai/jobs {kind:"coach", conversation_id, history≤6组,
      question, days≤14天(逐日校验), upcoming, purpose}
   → PHP: appFeatureEnabled(ai_enabled) → 会员门 → ai_user_jobs 幂等行(先提交再网络) 
   → HMAC serverId + _quota_owner(不透明) → 内网 POST 127.0.0.1:8787/v1/jobs
   → Python: 队列(SQLite) → worker → ai_core 路由(LongCat→MiMo→DeepSeek, 同意域约束)
   → 模型 JSON 输出 → coach_core.clean_result(证据/动作/提案校验) → report_archive(仅结果)
   → 客户端 2s-15s 轮询 GET /me/ai/jobs/{id} → 渲染消息卡(证据源/动作/提案)
   → 用户点 proposal → 本地校验 → 进编辑/预览 → (采纳时) 修改进 SavedState → 云同步
```

### C.4 一次"把明天训练改后天"（改期）现状路径

- 用户在 App 内：计划页批量改期（`shiftPlannedSchedule` `AppStore.swift:2601-2743`，两阶段+冲突分类）→ 本地 → 同步。
- AI 路径：对话产出 `schedule_proposal`（仅空日、≤28 天，`adaptive_core.py:88-116`）→ `ClubCoachView.swift:267-338` 校验后进改期预览 → 用户确认 → 本地应用 → 同步。
- 服务端命令路径：`POST /me/commands {type:"Schedule.Move"}`（CAS 版本+已开始训练保护+Outbox 事件，`commands.php:137-168`）——**客户端当前未接入此通道**（无调用点，grep 证实；为后端已备而客户端未用的能力）。

### C.5 一次食物拍照识别

见 B.3；识别等待 UI：`AILoadingCard` + 扫描动画；取消 `markConsumed`；迟到结果不覆盖。

### C.6 一次会员购买

购买（StoreKit2/RevenueCat）→ `logIn("boji-<id>")` → webhook `POST /webhooks/revenuecat`（常量时间鉴权、事件去重、陈旧拒绝）→ `revenuecat_subscriptions` → `recomputeMembership` → `membership_entitlements` → 客户端 `/me` 或 `POST /me/membership/verify` 对账（购买后 60s 宽限内最多 12 次轮询）。

### C.7 配置生效链（历史问题⑩）

```
管理后台 app_config(draft→publish) → MariaDB app_config(+版本审计)
   → 服务端生效点: /club/* 入口(index.php:395), AI 任务提交(weekly.php:42,136)
   → 客户端 GET /config(ETag) → ClubRemoteConfig 解码
   → 实际消费: 仅 announcement + minimumBuild；aiEnabled/clubEnabled 解码后从未读取 ←缺口
```

---

## D. 数据所有权矩阵（Single Writer 现状）

| 数据 | 本地权威 | 云端存储 | 写入者 | 备注 |
|---|---|---|---|---|
| 训练日/组次/会话 | SavedState.days（JSON+journal） | app_states(单文档)/cloud_parts | iOS AppStore（唯一） | commands.php 可服务端改日程（未被客户端使用） |
| 餐食记录 | 同上 | 同上 | iOS addMeal（幂等） | 营养值 AI 估算标记 estimated |
| 计划（版本/草稿/模板） | planDrafts/planTemplates in SavedState | 同上 | iOS applyAIPlan/managePlan | ClubPlanVersion 不可变链 |
| 身体/健康摘要 | day.health（拉取缓存） | 随 SavedState 同步（分享同意后） | HealthKit 读取 + 手动 | 写 HealthKit 仅 workout |
| 个人资料 | state.profile | app_states + profiles 投影 | iOS onboarding；commands.php Profile.Update 同步投影 | 双写由命令通道保证一致 |
| AI 任务 | AIJobDiskStore 拆分文件 | ai_user_jobs(映射) + Python jobs.sqlite3 | 客户端提交/服务端执行 | HMAC serverId；payload 用后即清 |
| AI 报告结果 | aiJobs[].result（SavedState） | report_archive(仅结果) | Python worker | 版本链 source_revision |
| 会员权益 | AccountService 缓存 | membership_entitlements | **仅服务端**（webhook/REST/admin） | 客户端不可写 |
| 俱乐部任务/奖励/申领 | ClubSeasonService 缓存 | club_* 表 | **仅服务端** | 进度由服务端从状态计算 |
| 媒体照片 | media-user-<id>/ | user_media + 文件 | iOS PUT /me/media | 原子 journal、配额、清理队列 |
| 会话/凭据 | Keychain | sessions | 服务端签发 | token 30 天 |
| 通知偏好 | AppStore/UserDefaults | club_push_devices(推送) / club_automation | 双端镜像（revision CAS） | 本地通知 vs 远程推送两套 |
| 操作审计/事件 | — | data_operations / domain_outbox | 服务端（actor 含 'ai'） | Outbox 消费者未实现 |

**关键结论**：除会员/俱乐部/审计外，业务数据的主存储是**客户端生成的单 JSON 文档**，服务端只是带乐观锁的文档仓库 + 派生计算器。V2 若引入领域表，必须先解决与该文档模型的共存（expand-and-contract，详见 04 号报告）。

---

## E. V2 五条用户故事现状预演

| UC | 现状能力 | 缺口 |
|---|---|---|
| UC-01 今天练什么→开始训练 | 首页/计划页今日卡→1-2 点击进入训练；训练/计时/保存离线可用；完成联动进度与自动化 | 无对话内 `today_training` 结构卡（对话只回文字+动作）；无"从 AI 卡片一键开始训练"的卡片协议 |
| UC-02 拍照饮食→草稿确认 | 完整存在：拍照→AI 估算(estimated)→草稿编辑→确认→记录/进度联动；可取消；多餐 batch | 无对话 Composer 内嵌入口（入口分散）；识别为轮询任务非即时；无食物库兜底 |
| UC-03 改期→审批式修改 | 双路径存在：AI schedule_proposal（校验后预览）+ 本地批量改期；服务端 Schedule.Move 命令通道（客户端未接） | 无统一 Proposal 状态机/过期/冲突文案标准化；Outbox 消费者为空，跨模块联动（提醒/洞察失效）未落地 |
| UC-04 最近为什么没进步→可解释分析 | 日报/周报有证据（sources）；训练反馈服务端定色；解释引擎锁数字 | 无"趋势卡+不确定性"结构化输出；无跨域(训练+体重+营养)联合分析卡的协议化呈现 |
| UC-05 AI 发现习惯→提议提醒 | 自动化设置（daily/weekly/workout）；洞察 ledger 有反馈动作；推送预算/免打扰 | 无行为特征计算/最小样本门槛/主动程度三档；洞察为本地规则非学习；远程推送默认关闭 |
