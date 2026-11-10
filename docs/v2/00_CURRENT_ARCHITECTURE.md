# BOJI CLUB V2.0 · Phase 0 审计报告 00：当前架构（CURRENT ARCHITECTURE）

- 审计对象：`BOJI-CLUB-0.15.1-Build114-UIUX-v3-精简减负版-20261023.zip`（解压于 `BojiClub-0.15.1-Build114-20261021/`）
- 审计日期：2026-10-23
- 审计方式：全量源码阅读（iOS 73 个 Swift 文件 ≈35,397 行；backend/ 14 个 Python 文件 ≈6,000 行；account-server/ 48 个 PHP 文件 ≈4,300 行 public + schema + admin + workers；exercise-server/api.py；测试与脚本抽样）
- 说明：所有结论均附 `文件:行号` 证据；未在代码中证实的内容标注 UNVERIFIED。本包**不含 .git 仓库**（无版本控制历史），不含生产服务器访问权限，生产环境状态仅以包内部署文档为证（UNVERIFIED）。

---

## 1. 总体形态：四组件单主机架构

```
┌─────────────────────────────────────────────────────────────┐
│ iOS App 薄肌俱乐部 (BojiClub.app 0.15.1 Build 114)           │
│ SwiftUI · iOS 17.0+ · 5 TabView + fullScreenCover 训练       │
└───────────────┬─────────────────────────────────────────────┘
                │ HTTPS https://117.50.119.49 （裸 IP + HTTPS）
                │ /account/v1/*（账号、同步、AI 代理、俱乐部、推送）
                │ /api/v1/exercises*（动作库，另一服务）
┌───────────────▼─────────────────────────────────────────────┐
│ Linux 单主机（2C2G，文档口径 UNVERIFIED）                      │
│ nginx ── PHP-FPM 8.2 ── MariaDB（account-server，/opt/bojiclub-account）│
│   └─ 内网 HTTP 127.0.0.1:8787 ── Python AI Worker（SQLite，/opt/bojiclub-ai）│
│ systemd: bojiclub-ai.service / dongzuo-api.service(127.0.0.1:8765) /      │
│          club-automation / club-push / deletions / outbox 定时器           │
│ 媒体: /opt/bojiclub-account/media/<uid>/ + dongzuo.gongxiang.cloud 静态媒体 │
│ 管理后台: https://api.gongxiang.cloud/admin/                 │
└─────────────────────────────────────────────────────────────┘
```

组件清单（真实目录）：

| 组件 | 位置 | 技术栈 | 规模 |
|---|---|---|---|
| iOS 主应用 | `BojiClub/` | SwiftUI + Swift 5，iOS 17.0 部署目标 | 73 文件 / 35,397 行 |
| iOS Widget/Live Activity | `BojiClubWidget/` | WidgetKit + ActivityKit | 4 文件 |
| iOS UI 测试 | `BojiClubUITests/` | XCTest UI | 1 文件 350 行 |
| AI Worker（内网） | `backend/` | 纯标准库 Python（无框架），SQLite | 14 文件 ≈6,000 行 |
| 账号/业务服务 | `account-server/` | PHP 8.2（无框架）+ MariaDB + nginx | 48 PHP + SQL |
| 动作库服务 | `exercise-server/` | 纯标准库 Python，127.0.0.1:8765 | api.py 257 行 + 数据集 |
| 管理后台 | `account-server/admin/` | PHP + 原生 JS | 11 文件，18 个页面 |
| 运维脚本/测试/文档 | `scripts/` `tests/` 根目录 ~180 个 md | — | tests/ 213 项 |

Xcode 工程（`BojiClub.xcodeproj/project.pbxproj`）：3 个 Target（BojiClub `com.bojiclub.app.dev`、BojiClubWidget、BojiClubUITests）；`IPHONEOS_DEPLOYMENT_TARGET = 17.0`；Swift 5.0；Team `GYFUN6MZ9J`；`MARKETING_VERSION 0.15.1 / CURRENT_PROJECT_VERSION 114`；Debug/Release/TestFlight 三套配置，TestFlight 定义 `BOJI_TESTFLIGHT` 编译条件；外部依赖仅 RevenueCat（packageProductDependencies，`project.pbxproj`）。

---

## 2. iOS 客户端架构

### 2.1 入口与导航栈

- `@main BojiClubApp`（`BojiClubApp.swift:4-38`）创建 **8 个 `@StateObject` 服务**经 `.environmentObject` 注入：AppStore、AIService、AccountService、HealthDataService、WeeklyReviewService、ClubSeasonService、MembershipService、AppNotificationService、ClubAutomationService（另加 `ClubPushDelegate` UIApplicationDelegateAdaptor）。
- 根视图链是**分层修饰**而非路由器：`foregroundContent → automationContent → reminderContent → notificationRoutingContent → accountLifecycleContent → recoveryContent → accountContent`（`BojiClubApp.swift:70-292`）。
- `accountContent` 按 `AccountPhase` 分流：`.signedOut → AccountEntryView`、`.onboarding → OnboardingView`、`.ready → MainClubView`（需购会员时先 `MembershipGateView`）（`BojiClubApp.swift:92-107`）。
- **`MainClubView` = 5 个 Tab 的 `TabView`**（`BojiClubApp.swift:423-469`），每个 Tab 是独立 `NavigationStack` 并包裹 `withMiniBar`（全局 AI 状态胶囊 `ClubAIAmbientPill` + 进行中训练悬浮条 `miniWorkoutInset`）：
  1. 首页 `HomeView`；2. 计划 `ClubPlanHub`；3. 记录 `ClubRecordsHub`（训练/饮食/身体/报告分段）；4. 俱乐部 `ClubSeasonView`；5. 自己 `ProfileView`。
- 训练界面为 **`fullScreenCover(item: $trainingRoute)`** 覆盖在 TabView 之上（`BojiClubApp.swift:520-534`），带 `initialRestEnd`/`restChanged` 回调；深链 `bojiclub://training?date=`（`:505-512`）。前台 120 秒循环刷新账号/配置/Widget/同步/推送/AI 恢复/自动化（`:273-291`）。

**对 V2 的含义**：当前没有 RootHeaderView/双模式胶囊/侧栏结构；主导航是 TabView + 全屏 Cover。V2 的 `Club AI | 训练` 顶层双模式需要新建 Shell，但训练页、记录页、俱乐部页可作为子视图复用。

### 2.2 状态管理与本地持久化

- **单一 god-store**：`@MainActor final class AppStore: ObservableObject`（`AppStore.swift:343-344`，2,814 行），`@Published private(set) var state = SavedState`。
- `SavedState`（`Models.swift:401-426`）：`version=1`、`days: [String: DayLog]`（按 `yyyy-MM-dd` 键控）、`profile`、`importedPlan`、幂等集合 `appliedAIJobs`、软删除墓碑（exercise/meal/media/aiJob/customExercise…）、`nutritionTarget`、`customExercises`、`actionStates`、`planDrafts/planTemplates`、`syncSchemaVersion=2`。
- `DayLog`（`Models.swift:214-303`）：单日 exercises、meals、health 摘要、weeklyReview(+历史)、**workoutSessions（同日多练）**、activeWorkoutSessionID、计划周期/版本/动作/移动记录、insight events、goalVersions、phaseReports、bodyWeight、meal completion。
- **持久化 = 明文 JSON 文件 + 预写日志（WAL journal）**，无 SwiftData/Core Data：
  - `Application Support/BojiClub/records-user-<id>-v1.json`（原子写 + `.completeFileProtection`，`AppStore.swift:2063-2085`，排除备份 `:429`）。
  - 追加式 journal `records-...json.journal`（每次变更 `appendJournal` `:1960-1979`，启动重放 `replayJournal` `:1980-2010`，8MB 检查点截断）；损坏时走 `localRecovery` + `RecordRepairView`（`RecordRepairViews.swift:4`）。
  - 少量偏好 UserDefaults（通知设置、组间休息/暂停状态、计划预览编辑、insight 关闭、草稿）；AI 任务拆分文件（`RecordReliability.swift:161` AIJobDiskStore）；Widget 快照走 app-group `group.com.bojiclub.shared`（`AppStore.swift:2087-2117`）。
- 每次变更经 `mutate()/persist()`（`AppStore.swift:1783-1801,1852-1885`）：写 journal、生成代际 UUID、置 dirty、发布 Widget 快照、1.2 秒防抖调度云同步（`:1876`）。照片存每账号 `media-user-<id>` 目录（`:1730-1744`）。

### 2.3 AI 能力现状：任务轮询，无流式对话

- `AIService`（`AIService.swift:179-915`）是**本地任务队列 + 服务器轮询**：`AILocalJob` 持久化到 `ai-tasks-user-<id>-v1.json`（`:204-214`），最多 **3 个并发 worker**（`:202`），轮询 2s→15s，10 分钟截止转 `deferred`（`:732-744`）；载荷 SHA256 去重（`:621-625`）。
- 后端端点（经 `account.cloudRequest`，基址 `https://117.50.119.49/account/v1`，`AccountService.swift:181-197`）：`POST /me/ai/jobs`（提交 `:724`）、`GET /me/ai/jobs/{id}`（轮询）、`POST /me/ai/jobs/{id}/retry`、`GET /me/ai/tasks?cursor=`（云端恢复 `:465`）。
- 任务类型：`generate_plan` / `parse_plan` / `report`（日报）/ `food`（图片/文字/多餐识别）/ `coach`（对话+自动报告）/ `weekly_review`。
- 配额：HTTP 429/5xx → `deferred`+`retry_after`；`quota_exceeded`/`daily_capacity` 终态失败（`AIRetryPolicy` `:146-164`）。
- **"Club AI 对话"**（`ClubCoachView.swift:63-264`）：LazyVStack 消息列表 + 1200 字输入框；**历史仅客户端携带**（最近 6 组问答 ≤16,000 字，`ClubCoach.swift:56-68`），`conversation_id` 标识、草稿 UserDefaults（`:101-116`）；回答可带 `sources`（证据引用）、`actions`（白名单动作）、`proposal`（参数变更提案）和 `schedule_proposal`（改期提案），**进入改期预览前经程序化校验**（`ClubCoach.swift:72-98`、`ClubCoachView.swift:267-338`）。
- 隐私门控：`_routing_version: 2` 载荷仅在 `CloudAnalysisConsent` 同意后提交（`AIService.swift:918-943`；consent 存储 `JourneyRules.swift:74-92`）。
- AI 中心为 `ClubAIHubView` 分段 动态/报告/对话（`ClubCoachView.swift:3-53`）。

**对 V2 的含义**：已有受限对话（非流式、有证据引用、有提案校验），但**无 SSE/流式、无服务端会话存储、无 Context Builder 分层、无 CardRegistry**。V2 对话服务需在现有 job 模型上演进，而非从零开始。

### 2.4 训练流程（Workout Session）

- `WorkoutView`（`WorkoutView.swift:3-534`）：日头、会话选择器（同日多练 `:331-343`）、进度摘要、动作卡（DisclosureGroup 分组 `:272-280`）、底部**组间休息 dock**（`:433-515`，−15s/+30s/暂停/跳过 `:477-503`）。
- **组间计时器跨页/跨重启存活**：`restEnd/restPausedRemaining`（`:22-24`）变化即经 `ClubRestStorage` 持久化（`ClubAutomation.swift:188-232`，key `club-rest.v1.<owner>.<date>`，上限 1 小时，sessionID 作用域）；`scenePhase != .active` 时保存（`WorkoutView.swift:181-186`）；`onAppear` 恢复（`:92-95`）并经 `MainClubView.initialRestEnd` 回灌（`BojiClubApp.swift:384-386,523-527,573-577`）。本地通知"组间休息结束"（`AppStore.swift:47-66`）。整场暂停独立持久化（`ClubWorkoutPauseStorage` `ClubAutomation.swift:112-186`）。
- 组次写入：`toggleSet` 写前按当前 store 状态重校验（乐观并发 `WorkoutView.swift:782-786`）→ `store.updateSet`（`AppStore.swift:895-915`）钳制数值、首组完成自动开始训练（`:900,910`）、事后编辑清除 `workoutSavedAt`（`:912`）。计时组走秒表 sheet（`TimedTrainingSetView` `:808-883`）。Live Activity 由持久化快照驱动（`AppStore.swift:2227-2290`）。
- **保存流程 local-first**：结束训练 → `saveWorkout` 本地写 `workoutSavedAt/workoutEndedAt`（`AppStore.swift:929-939`）→ `WorkoutCompletionView`（可写 HealthKit、交接下周）→ 云同步 1.2 秒防抖异步；断网由 `NWPathMonitor` 重触发（`:418-437`），同步状态仅提示不阻塞。

### 2.5 训练计划

- 计划 Tab `ClubPlanHub`（`ProductArchitecture.swift:24-189`）：今日中心 7 日条 ↔ 周一起月历网格（`PlanCalendarRules` `PlanHubViews.swift:18-53`）、日摘要卡、交接卡、创建入口。
- 创建入口 `PlanCreationSheet`（`PlanManagement.swift:8-63`）：**自己安排 / AI 帮我安排 / 重复计划 / 我的模板 / AI 整理文字计划 / 补记**——即 V2 要求的"AI 计划 + 自定义计划"两条路径均已存在。
- AI 计划（`PlanView.swift:18-614`）：7/14/28 天、开始日期规则、实测体重参考；提交带 `profile` + `goal_context`（近 28 天 `ClubAIContext` `ClubHistory.swift:14-63`）。预览可逐动作编辑（`PlanExerciseEditor`）并持久化；**采纳需经 Diff sheet**（`adoptionSheet` `:571-594`，diff 由 `ClubPlanChangeRules.preview` `ClubHistory.swift:148-157` 生成）→ `store.applyAIPlan`（`AppStore.swift:1299-1394`）保留受保护日、稳定 UUID（`stableID` SHA256 `:1947-1951`）、记录计划历史。
- **计划版本化**：每次采纳写 `ClubPlanVersion` 快照 + 每日前后 `changes`（`ClubHistoryRules.recordPlan` `ClubHistory.swift:213-239`），`ClubPlanVersionsView` 可浏览（`ProductArchitecture.swift:191-348`）；生命周期 ended/archived 走不可变墓碑（`:259-301`）。
- 手动计划 `ManualPlan.swift`（28 天数组、模板、草稿存储+一次性迁移 `AppStore.swift:1040-1097`）；编辑器 `ManualPlanView.swift`（634 行）。
- 批量改期引擎 `shiftPlannedSchedule`（`AppStore.swift:2601-2743`，两阶段移动、冲突分类、指纹守卫）+ 单日提前 `advancePlannedWorkout`（`:1396-1452`，需先云同步确认 `:631-656`）。

### 2.6 饮食记录与识别

- 相机 `MealCamera.swift`（自定义 `AVCaptureSession`，串行队列，权限/中断处理）；照片降采样 ≤1400px JPEG q0.8（`MealEditorView.swift:955-971`）。
- 识别 `identify()`（`MealEditorView.swift:972-982`）提交 `kind:"food"` 任务（image_base64）；本地排队照片上限 24MB（`AIService.swift:435-441`），消费/成功后剥离 base64（`:288-305,792-794`）。加载态 `AILoadingCard` + 扫描动画 `LaserScanBeamOverlay`（`:666-670`）。**取消**："停止使用这次识别，改为手动记录" → `markConsumed(jobID)`（`:277-287`），迟到结果不覆盖（`AIService.swift:539-549`）。
- 语音 `MealSpeechInput.swift`：`SFSpeechRecognizer` 强制本地识别（`:57`）、60 秒上限、2000 字转写。**AVAudioSession 仅在此配置**：`setCategory(.record)`+`setActive(true)`（`:47-49`）/ `setActive(false, .notifyOthersOnDeactivation)`（`:109`）。全仓 grep 证实**无启动时/首页 setActive(true)**。
- 草稿确认流：餐食草稿（JSON+jpg）目录 + 恢复 + 多草稿选择器（`MealEditorView.swift:775-911`）；多餐识别 `meal_batch` 逐项审阅（`MealBatchReviewView.swift:37`，逐项幂等 id）；保存 `store.addMeal` 幂等（appliedAIJobs + 稳定餐食 id，`AppStore.swift:1657-1691`）；并发编辑字段级合并 `MealNutritionMerge`（`Models.swift:108-163`）。
- 文本理解 `MealDescriptionUnderstanding`（`MealSpeechInput.swift:123-217`）为规则式；识别需日期/餐次确认弹窗（`MealEditorView.swift:413-425`）。

### 2.7 HealthKit

- `HealthDataService`（`HealthData.swift:214-659`）。读取 12 类（steps/activeEnergy/heartRate/restingHeartRate/sleep/workout/bodyMass/bodyFat/leanBodyMass/height/BMI/waist，`:292-299`）；仅写 `HKWorkoutType`（opt-in，`HKWorkoutBuilder` + `HKMetadataKeySyncIdentifier` 幂等，明确"不伪造热量/心率"，`:316-396`）。
- **只按需查询**：仅 `HKStatisticsQuery`（`:513-543`）与 `HKSampleQuery`（`:561-579`），60 秒缓存；**无 HKAnchoredObjectQuery、无 HKObserverQuery、无后台交付**。
- 同意模型：HealthKit 数据本地保留，直到用户逐日确认"分享复盘"（`HealthShareConsent.issue` `:104-179`），共享摘要剥离本地字段（`:65-75`）。
- 身体面板：`BodyOverviewCard`（Home，`HealthOverview.swift:54-128`）**并非只显示体重**——用户可配置 7 项指标（默认睡眠/静息心率/步数/体重 `:61`）；`BodyOverviewView` 趋势图 **无 x 轴标签**（`:175-180`，可读性缺口）；`BodyWeightView` 的 `BodyTrendChart` 有日期轴（`:193-204`）。

### 2.8 会员与订阅（RevenueCat）

- `MembershipService`（`MembershipService.swift:46-592`）封装 **RevenueCat SDK**（StoreKit 2、Info.plist 公钥、`logIn("boji-<accountID>")` `:90,171-197`）。商品：`yuefu`（月）/`nianfu`（年）/`yongjiu`（永久）（`Info.plist:9-18`）；权益 `薄肌俱乐部_pro`。
- **权益判定**：服务端 `/me` 的 `membership.active` 为受保护 API 的权威；RevenueCat `CustomerInfo` 驱动购买 UI；购买成功→服务端核验之间有 60 秒 UI 宽限（`MembershipAccessPolicy` `:29-42`）+ 最多 12 次/60 秒的对账轮询 `POST /me/membership/verify`（`:546-577`）。硬门 `MembershipGateView`（`ProfileView.swift:344`）。

### 2.9 账号与云同步

- 登录**仅 Sign in with Apple**（`AccountService.swift:296-318`）；Bearer token 与 Apple userID 存 Keychain（`:520-586`）；凭证撤销监视（`:565-572`）。基址 `https://117.50.119.49/account/v1`（DEBUG 可覆盖）。
- **云同步 = 分区协议**（`AppStore.syncNow` `AppStore.swift:675-769` + `CloudSync.swift`）：`GET /me/sync` 清单（revision+分片哈希）→ `POST /me/sync/read`（≤64 分片/批，SHA256 校验）→ `POST /me/sync/uploads`（begin → ≤2MB×≤64 块 → commit）（`CloudPartitionClient` `CloudSync.swift:448-530`）；分片 = 每日 `d/<date>` + 每任务 `j/<hash>` + meta（`:356-393`）。合并为**通用三方 JSON 合并**（`CloudMerge.merge` `:107-188`，墓碑并集、可变观测 per-ID 最新获胜、版本链不可变集、专项规则 R01 互斥计划替换 `:147-164`）。冲突可导出备份（`AppStore.swift:706-710`）。餐食照片独立 `PUT/GET /me/media/<uuid>.jpg`（`:2164-2215`）。

### 2.10 俱乐部（成长季/徽章/Club Keepsake）

- `ClubSeasonService`（`ClubSeason.swift:239-416`）：`/club/current`、`/club/history`、`/club/collection`；加入季、任务进度（training_days/meal_days/weekly_reviews/meal_records/daily_reports/health_days）、奖励含**实物 Keepsake 申领/发货跟踪**（claim `:391-406`、updateClaim `:359-369`）；收藏缓存 AES-GCM 加密（`ClubDiskCache` `:6-84`）。
- 自动化 `ClubAutomationService`（`ClubAutomationService.swift:6-238`）：设置（daily/weekly/workout/partial + 时段）镜像到 `PUT /me/automation`；`evaluate()` 在会员+同意+已同步门控下提交**确定性 ID 任务**（`ClubAutomationRules.jobID` `ClubAutomation.swift:96-102`）：昨日/今日日报、训练后教练"锐评"、每周成长报告。
- 洞察 `ClubInsightRules.facts`（`ClubInsightRules.swift:50-147`，本地规则事实卡：训练摘要/营养跟进/身体最新值/连续缺练+schedule_shift 行动）+ `ClubInsightLedger`（`ClubInsightLedger.swift:102-`，版本链 ClubInsightEvent 存 DayLog，反馈动作 helpful/read/archive/dismiss-today `:15-28`，独立 `ClubActionRecord` 状态机 `:59-88`）。首页展示 top1（`HomeView.swift:721-777`），时间线 `ClubInsightTimelineView.swift:348`。
- 远程推送**默认编译期关闭**（`ClubRemotePush.swift:7` 门控 `BOJI_REMOTE_PUSH`；默认 no-op `ClubPushService` `:70-79`）；其余为本地通知（训练/餐/休息/周复盘/分析，带路由 userInfo `AppStore.swift:35-297`）。

### 2.11 设计系统

- `DesignTokens.swift`（1,365 行，0.15.0 引入）为权威 Token：颜色 `BojiColor`（浅/深自适应）——**`brandMist = #E3E7F0` 已存在**（`DesignTokens.swift:24-26`，注释"品牌雾蓝 #E3E7F0：信息性表面"）；间距 `BojiSpace` 6/8/12/14/18/24；圆角 28/32/22/16/capsule；字号角色 30/20/18/16/14/13/40/28/17 + `@ScaledMetric`；触控 44pt；按钮样式/动效/4 级触感。
- **一致性混杂**：Boji Token（新页面）、`ClubUI` 遗留 shim（`Design.swift:12-27`）、`FlowPalette`（计划页 `FlowDesign.swift`）三套并存；旧页面仍有硬编码 `.font(.subheadline)`、raw `Color.orange`（`HomeView.swift:141,280`、`NutritionView.swift:178-180`）。

### 2.12 功能开关与音频（历史问题定位）

- 远程配置**仅咨询性**：`ClubRemoteConfig` 解码 `ai_enabled/club_enabled/minimum_build/latest_build/announcement`（`AccountService.swift:142-166`），但**客户端从未读取 aiEnabled/clubEnabled**（全仓 grep 证实）——即"后台配置不生效"问题在客户端侧仍存在（服务端倒是在 `/club/*`、`/me/ai/jobs` 拦截了）。
- 本地开关：编译期 `BOJI_REMOTE_PUSH`、`BOJI_TESTFLIGHT`；DEBUG 环境变量若干（`BOJI_PREVIEW_TAB` 等，`BojiClubApp.swift:341-367`）。**无用户侧功能开关系统**。
- **首页音频中断机制定位**：首页 hero 卡循环播放**静音视频** `HomeWorkoutLoop.mp4`（`HomeWorkoutVideo.swift:5-27` AVQueuePlayer+AVPlayerLooper，`isMuted=true` `:11`，Home 出现即播 `HomeView.swift:254`）；**播放前未配置任何 AVAudioSession 类别，也从未使用 `.mixWithOthers`**——静音视频同样会激活默认非混音会话，从而暂停用户后台音乐。这是历史问题①的现存机制（代码无注释承认）。
- AI 提醒复现问题定位：`ClubAIAmbientPill` 的关闭仅 `@State dismissedID`（`DesignTokens.swift:943`）**未持久化**，视图重建（切 Tab/重启）即复位；任务进行中变体显式 `allowDismiss: false`（`:1003`）。对应历史问题③。

### 2.13 Info.plist / 权限 / 隐私清单

- 权限文案：麦克风、语音识别、相机、照片库、HealthKit 读写（最小化措辞，`Info.plist:51-62`）；ATS 允许本地网络；`NSSupportsLiveActivities`；URL Scheme `bojiclub`（`com.bojiclub.training` `:78-88`）；竖屏 iPhone；**无 UIBackgroundModes**。
- Entitlements：Sign in with Apple、HealthKit、app group `group.com.bojiclub.shared`（**无 push/iCloud**——远程推送开启需补 entitlement，与 BOJI_REMOTE_PUSH 默认关一致）。
- `PrivacyInfo.xcprivacy`：Required-reason API 三类；采集数据（姓名/电话/地址/用户 ID/健康/健身/照片/购买历史/设备 ID）均为 linked+app-functionality+**非跟踪**。
- 服务器为**裸 IP HTTPS**（`117.50.119.49`），ATS 未为其声明例外域——证书有效性/ATS 行为 UNVERIFIED，列为风险。

### 2.14 Widget

- `TodayTrainingWidget`（今日训练+营养摘要，app-group 快照）+ `TrainingLiveActivityWidget`（锁屏/灵动岛训练实时活动：组次、当前动作、休息倒计时 timerInterval 系统驱动、暂停态；点按深链 `bojiclub://training?date=`；旧活动向后兼容解码 `TrainingShared.swift:94-111`）。

---

## 3. AI Worker（backend/，Python）

### 3.1 服务形态

- `server.py`（1,156 行）：纯标准库 `ThreadingHTTPServer`，**仅绑定 127.0.0.1:8787**（`server.py:1113-1114`），文件头注明"Internal AI worker. Public clients must use the authenticated account proxy"。单共享 Bearer `APP_TOKEN`（`hmac.compare_digest`，`:952-953`；≥24 字符否则拒绝启动 `:1129-1131`）；未授权一律 404（端点隐藏 `:957,1000-1002`）；唯一免鉴权路由 `GET /health`。无 CORS（设计上仅内网）。
- 端点：`GET /health`；`GET /v1/jobs/{id}`、`POST /v1/jobs`、`POST /v1/jobs/{id}/retry`、`POST /v1/jobs/metadata`（≤50 批量）、`POST /v1/automation/prepare`、`POST /v1/account-quota/{usage,bind,erase}`、`POST /v1/admin/ai/{settings,providers}`、`GET /v1/admin/ai/{overview,providers,live,settings,tasks,tasks/{id}/audit,health}`、`DELETE /v1/jobs/{id}`（墓碑+清除，`:955-965`）。
- 任务引擎：SQLite（WAL + `secure_delete=ON`）`backend/.data/jobs.sqlite3`（生产 `/opt/bojiclub-ai/.data/jobs.sqlite3`，`report_versions_ca08.sql:1`）；调度线程 + `ThreadPoolExecutor(32)`；**cgroup v2 内存守卫**（预留 24MiB、85% 上限、可回收页缓存剔除，`server.py:27-64,846-862`）；120 秒运行租约 + 15 秒心跳 + 崩溃回收（`:426-439`）；每账号 pending 上限 8；配额按**北京时间日界**，仅成功完成计数（`:567-581`）。
- 保留策略：成功后 payload 清空 `{}`（`:473`）、失败 1 天后清（`:411`）、30 天任务墓碑化、90 天物理清除、attempts 90 天、审计 30 天；`report_archive` **只存校验后的结果与路由元数据，绝不存输入照片/会话/全量 profile**（`:298-299`）。

### 3.2 供应商与路由（ai_core.py，1,450 行）

- **三家供应商，全部 OpenAI 兼容 chat-completions；无 OpenAI/智谱/GLM**（`PROVIDER_DEFAULTS` `ai_core.py:1073-1077`）：
  - **LongCat** `LongCat-2.5-Preview`（priority 10，最先尝试）
  - **MiMo（小米）** `mimo-v2.6-flash`（priority 20，支持图片）
  - **DeepSeek** `deepseek-flash`（priority 30）
- 密钥：env `MIMO_API_KEY/DEEPSEEK_API_KEY/LONGCAT_API_KEY`（`backend/.env` 0600，`setup.py` 交互式录入不回显）；后台可热更新（`providers.json` 0600 原子替换 + 路由器热重载，`server.py:125-147`）。**代码中无任何硬编码密钥**（正则扫描 0 命中）。
- 传输：stdlib urllib；`NoRedirect` 处理器阻止 Authorization 头被转发到未知主机（`ai_core.py:1102-1105`）；响应体 ≤2MB；总预算 180s（计划/周报）/120s（其他），单次调用 ≤45-60s。
- 失败处理：供应商间优先级故障转移；HTTP 401/402/404→provider_config（熔断 300s）、429/5xx→upstream_N（3 次熔断 60s）；`invalid_output`/`request_blocked` 不污染供应商；任务级重试 ≤3 轮（30s/90s 退避）+ 已知失败原因注入修复提示重试。
- **同意域路由**（`ai_core.py:1276-1287`）：旧版请求照片仅发 MiMo、健康数据仅发 MiMo/DeepSeek（"Fail closed：故障转移不扩大接收方"）；`_routing_version==2` 解锁全部供应商；文本供应商不接图片任务。
- **无 SSE/流式**：全部单次阻塞请求/响应，客户端轮询取结果。

### 3.3 各核心模块

- `coach_core.py`（105 行）：有界对话。校验 `version:1`、规范 UUID `conversation_id`、问题 ≤1,200 字、历史 ≤12 轮严格角色交替 ≤16,000 字（`coach_core.py:21-26`）——**服务端不保存会话，历史每次由客户端携带**。上下文 ≤14 天记录（逐日经完整报告校验器再规范化）+ 未来计划 + purpose（dialogue/workout/weekly）。系统提示注入抗性；输出契约 `{kind, coach:{answer, source_ids, actions}}`；`clean_result` 拒绝编造来源、禁止宣称已修改（"已为你修改计划/会员…"）、禁止无依据质量断言、未成年人/孕期禁数字处方、actions ≤2 且限 7 项白名单（training/nutrition/body/plans/daily/weekly/schedule_shift），可选经 `adaptive_core` 校验的 `proposal`/`schedule_proposal`。
- `food_core.py`（63 行）：图片识别 = 照片以 `image_url` data URI 走 chat-completions（非专用视觉 API）；默认同意路由**仅 MiMo**。**纯 AI 估算，无食物数据库**；结果强制 `estimated: True`（`food_core.py:11,37,63`）；**总量永远由服务端按成分重算，不取模型值**（`:33-34`）；单位白名单、宏量质量守恒窗（±）、4/4/9 kcal 一致性、单餐上限、批 ≤6 餐 ≤40 成分。
- `adaptive_core.py`（122 行）：模型**只能提案**对自己已提交未来计划的参数级修改（weight/reps/durationSeconds/rest_seconds，≤6 处）；**加重需证据**（≥2 次相同动作/组数/逐组目标重量全部达成的已确认训练，且 ≤ max(2.5kg, +5%)，`:31-55`）；次数/秒数 ≤×1.2+1；改期提案只能移动到 28 天内空日。
- `automation_core.py`（1,146 行）：`prepare()` 服务端确定性决定生成哪些自动分析（昨日/今日日报——须有真实记录+已确认训练+源 revision 变化；保存后 1 天内的逐训练解读；每周报告——≥2 训练日或 ≥3 完整饮食日）；`source_revision` 为规范化载荷的 SHA-256 指纹（C07 版本化）；确定性任务 ID。注意：`:197-1146` 内嵌了一份与 `data_integrity_engine.py` 几乎相同的 31 规则副本（运行时未被 HTTP 路径使用）。
- `weekly_core.py`（317 行）：周复盘校验（体脂需实测来源、照片仅成人 ≤6 张 ≤550KB JPEG、未成年人 nutritionTarget 强制 generalGuidanceOnly）；`review_readiness` **入队前**做就绪检查；`adjust` 方案对目录/器械/星期校验且**硬性 ≤ 已确认历史容量的 120%**；疼痛主诉→禁止处方；合成文本剥离照片体脂/肌肉量断言。
- `plan_explanation.py`（207 行）+ `training_feedback.py`（136 行）：**确定性证据引擎**——解释的数值事实由服务端计算并锁死（散文仅允许既定数字集合），训练反馈颜色/状态由服务端按组 ID 对比冻结基线得出，模型只写文字且必须复述服务端结论。
- `data_integrity_engine.py`（910 行）：31 条规则（DI-001…DI-031）只读扫描 + 安全修复（D 自动/C 需确认/B 阻断）；**未被任何运行时模块 import**（独立参考实现）。
- 计划生成：模型从 678 项策展目录选动作（`curated_library.py`），服务端校验星期恰为 daysPerWeek、每次 3-5 动作、**生成计划重量强制 null**、居家日器械复检；7/14/28 天 = **服务端重复基础周，绝不用模型外推**（`ai_core.py:753-781`）。

### 3.4 与 account-server 的关系

- 单向 HTTP 代理 + 同一 APP_TOKEN + 无共享数据库（PHP=MariaDB，Python=SQLite）；用户身份以 HMAC 不透明 `quota_owner`（64 hex）传递（PHP 侧 `ai-response.php:4-6` 计算），Python 端**永不接触真实用户 ID**；账号注销调 `/v1/account-quota/erase` 清除。
- 自动化管道：`process-club-automation.php:93` → `/v1/automation/prepare` → 返回任务 → `POST /v1/jobs`。
- 管理后台 `admin/bootstrap.php:126-140` 以同 token 调 `/v1/admin/ai/*`。

---

## 4. account-server（PHP + MariaDB）

### 4.1 路由与 API 面

`public/index.php`（936 行）路由前缀 `/account/v1`（nginx `bojiclub-account-location.conf`，limit_req + 18m body 上限）：

| 分组 | 端点（证据 index.php 行号） |
|---|---|
| 配置 | `GET /config`（ETag+版本，`:383-394`） |
| 认证 | `POST /auth/apple/verify`（`:412-429`）、`/auth/apple/deletion-status`（`:403-410`）、`/auth/code/{request,verify}`（开发手机号，`:431-487`）、`/auth/logout`（`:920-924`） |
| 我 | `GET /me`（含异步 RevenueCat 刷新 `:499-505`）、`POST /me/membership/verify`（`:507-516`）、`DELETE /me`+`GET /me/deletion`（注销队列 `:518-527`）、`GET /me/storage`（`:494-496`） |
| 同步 | `GET/PUT /me/state`（revision 乐观锁、409 冲突返回远端状态 `:690-791`）、分区路由 `cloudPartRoutes`（`cloud-parts.php:329`：`/me/sync`、`/me/sync/read`、`/me/sync/uploads`…）、`GET/PUT/DELETE /me/media/{id}`（原子 journal 媒体存储 `:793-846`） |
| 业务命令 | `POST /me/commands`（`:709-714` → `commands.php`） |
| AI 代理 | `POST /me/ai/jobs`、`GET/DELETE /me/ai/jobs/{id}`、`POST /me/ai/jobs/{id}/retry`、`GET /me/ai/usage`、`GET /me/tasks`（恢复）、`POST/GET/DELETE /me/weekly/jobs/{id}`（`weekly.php`） |
| 自动化 | `GET/PUT /me/automation`（`automation.php:78-110`）、`PUT /me/push-device`（`club-push.php:135-163`） |
| 俱乐部 | `GET /club/current`（需会员 `:554-563`）、`/club/history`、`/club/collection`、`POST /club/seasons/{id}/join`（`:579-606`）、`POST /club/rewards/{id}/claim`（含库存/单件/截止校验 `:632-688`）、`/club/rewards/{id}/{cancel,received}`、`GET /club/rewards/{id}/image{,-info}`（sha256 校验 `:608-630`） |
| Webhook | `POST /webhooks/revenuecat`（`revenuecat.php:73-81`） |
| Onboarding | `PUT /me/onboarding`、`POST /me/onboarding/complete`（`:848-918`） |

### 4.2 数据库（MariaDB，schema.sql 34 表 + v59 分区同步 8 表）

关键表（`account-server/schema.sql` 行号）：

- 身份：`users`（phone+apple_subject，`:1-8`）、`verification_codes`、`sessions`（token_hash Bearer，`:23-33`）、`apple_auth_nonces`、`apple_tokens`
- 会员：`membership_entitlements`（权威投影，`:57-72`）、`membership_adjustments`（人工调整审计）、`membership_admin_grants`、`revenuecat_events`（webhook 去重审计，`:327-341`）、`revenuecat_subscriptions`（`:343-354`）、`revenuecat_member_checks`（REST 快照）
- **业务状态**：`app_states`（单 JSON 文档 + revision 乐观锁，`:123-129`）、分区表 `cloud_parts/cloud_meal_sources/cloud_media_refs/cloud_uploads/cloud_upload_parts/media_upload_events`（`sync-schema-v59.sql`）
- AI：`ai_user_jobs`（client/server 任务映射幂等，`:35-45`）、`ai_user_usage`
- 俱乐部：`club_seasons/tasks/reward_catalog/rewards/enrollments/reward_claims/virtual_grants/announcements`（`:143-272`）
- 推送：`notification_templates/plans/deliveries`、`club_push_settings/account_blocks/budget/devices/receipts`（`:510-566`）
- 自动化：`club_automation`（偏好+覆盖指纹+有界重试，`:477-492`）、`club_automation_runs`
- **架构表**：`data_operations`（操作审计：actor user/**ai**/system/admin、command_type、before/after version、diff_json、status succeeded/failed/**compensated**，`:568-583`）、`domain_outbox`（事务 Outbox：pending/processing/published/dead_letter、attempts、lease_token，`:585-602`）
- 媒体/注销：`user_media`、`deleted_media`、`media_cleanup_queue`、`account_deletions`（重试队列）
- 配置：`app_config`（draft/published/版本，`:409-418`）、`app_config_versions`（draft/publish/rollback 动作审计，`:420-430`）

### 4.3 业务命令通道（V2 Action Orchestrator 的现存雏形）

`public/commands.php`（260 行，"Unified Business Commands Handler (A2/A3 Architecture)"）：
- `POST /me/commands`，类型仅 `Schedule.Replace / Schedule.Move / Profile.Update`（`:35-38`）。
- **幂等**：commandId UUID 查 `data_operations`，同 id 不同载荷拒绝（`:54-69`）。
- **CAS 版本**：expectedVersions vs `days[date]._schedule_version`，冲突 409 带当前版本（`:100-112`）。
- **不变量**：已开始/已保存训练日不可覆盖/移动（`:116-118,148-153`）。
- 同事务写：app_states 更新 + `data_operations` 审计（actor 可为 'ai'，`:47`）+ `domain_outbox` 事件（ScheduleReplaced/ScheduleMoved/ProfileUpdated，`:230-245`）。
- Profile.Update 同步投影 `profiles` 表（R02，`:187-204`）。
- 局限：分区账号（_partitioned=2）被拒绝（`:80-83`）；Workout.Confirm 等类型显式未实现（注释 `:32-35`）。

**Outbox worker**（`process-domain-outbox.php`，82 行）：租约认领 ≤50 条、指数退避 30s·2ⁿ、5 次进死信、14 天清理——**但下游分发当前是空实现**（所有事件直接 `success=true`，`:47-56`），基础设施已就位、消费者未接。

### 4.4 会员权威链路（RevenueCat）

- Webhook（`revenuecat.php`）：`Authorization` 常量时间比较（`:5-9`）；事件 id 去重（`:52-53`）；app_user_id 格式 `boji-<id>`（`:10-13`）；TRANSFER 单目标+来源锁+REST 对账（`:109-156`）；过期/陈旧事件按 rank+时间戳拒绝（`:62-66`）；`recomputeMembership`（`:84-107`）= max(revenuecat_subscriptions, REST 快照, admin 授予) → `membership_entitlements`。
- REST 核验（`revenuecat-verify.php`）：`revenueCatVerifyMembership` 批量拉取订阅、快照写 `revenuecat_member_checks`、`revenueCatRefreshIfDue`。
- 服务端执行门：`requireActiveMembership`（club/AI/automation 入口调用）；`membership_enforcement` 配置可全局放宽。
- 商品：`bojiclub_halfyear_2990`、`bojiclub_yearly_4290`（deploy.sh 默认）+ 兼容列表（`revenuecat.php:30`）。

### 4.5 俱乐部进度与反刷量

`club-progress.php`：从同步状态构建前缀和索引；`training_days` 需"已完成组（有次数或时长）+ workoutSavedAt"（或 workoutSessions 逐会话核验，`:11-24`）；`weekly_reviews/daily_reports` **必须经 `verifiedAICompletions` 向 AI 服务核验任务真实成功**（`index.php:257-303`，批量 metadata）——AI 结果不能靠客户端声称。

### 4.6 推送（APNs）

- 自实现 APNs JWT（ES256 手工 DER→raw 签名，`club-push.php:8-36`）；token 缓存 50 分钟。
- 设备注册 `PUT /me/push-device`：偏好 enabled/daily/weekly/quiet/quiet_start/quiet_end/zone；换绑清理回执。
- **预算系统**（`club_push_budget`）：4 类（proactive/report/reminder/account）各自限额；proactive 每日默认 1 条（可 0-20，后台可调）；语义组去重（kind+日期+任务哈希）；失败允许接管重发不重复扣额（`:74-107`）；免打扰时段；账号级拉黑。
- iOS 侧默认编译关闭（见 §2.10），服务端能力已就绪。

### 4.7 管理后台

`admin/`：18 页（运营总览/成员/成长季/徽章/礼品/发货/消息中心/AI 服务中心/自动化任务/推送管理/存储与同步/系统状态/操作记录/系统配置/管理员与角色/安全设置/登录）；角色化写权限（`adminCanWriteAction`，`admin/index.php` writeProbe）；AI 实时统计代理 `/v1/admin/ai/live`；图片仅按库登记发放。README 注明：备份北京时间 03:25、保留 14 天、`runtime/backup-status.json`（**恢复演练未证实** UNVERIFIED）。

### 4.8 配置系统（现状"后台配置"）

`app-config.php`：仅 5 个键 `ai_enabled / club_enabled / minimum_build / latest_build / announcement`；draft→publish→rollback 三态 + 版本审计（`app_config_versions`）。服务端执行点：`/club/*` 入口（`index.php:395`）与 AI 任务提交（`weekly.php:42,136`）。**客户端未消费 ai_enabled/club_enabled**（§2.12）——"后台改了、App 不生效"的闭环缺口在客户端。

### 4.9 安全 posture

- 无提交密钥（config.php 部署时由 env 生成，deploy.sh 校验 24-128 字符；example 文件为空模板）。
- 全部预处理语句（PDO `ATTR_EMULATE_PREPARES=false`）；错误信息脱敏（`publicAIResponse` 剥 Traceback/Bearer/sk-，`ai-response.php:49-60`）；PHP 异常只记类名不记消息（`index.php:930-935`）。
- 上传校验：JPEG 魔数+尺寸上限、媒体 ID 正则、配额+磁盘预留、原子 journal 提交、清理队列。
- 注销：两阶段确认 + `account_deletions` 重试队列 + AI 侧 erase + 媒体目录清除；媒体照片不进管理后台身体复盘（README）。
- 动作库服务 `exercise-server/api.py`：**无鉴权**（公开只读数据，设计声明），nginx 限流 10r/s。

---

## 5. 部署与运行（包内证据；生产状态以部署记录为证，外部未复核 UNVERIFIED）

- 生产主机：`117.50.119.49`（**Rocky Linux 10.1、nginx、PHP 8.3.33、MariaDB 10.11**，app 根 `/opt/bojiclub-account`、AI `/opt/bojiclub-ai`——`docs/audits/boji-v2-quality/13_DEPLOYMENT_20261021.md`；注意包内 nginx conf/deploy.sh 写的是 php8.2-fpm/Debian 导向，与实际 Rocky 主机不完全一致）。曾用主机 `110.41.10.154`（2026-10-09→13）。**服务器规格 2 核约 2GB**（`AI-THROUGHPUT-V57-20261012.md:17`）。域名：`api.gongxiang.cloud` 为 Release 预定域名但 **NXDOMAIN**（`11_TESTFLIGHT_READINESS.md:49-53`）；`dongzuo.gongxiang.cloud` 动作库媒体。
- 最近一次完整部署记录（2026-10-21）：选择式文件部署 + `migrate-v2-quality.php`（drift→apply→SCHEMA_OK）+ 部署前备份 `/root/bojiclub-deploy-backups/20261021T010111Z/`（database.sql/config.php/nginx conf/code.tgz/SHA256）+ 线上验证矩阵（`/config` 200+ETag 304、`/me` 401/200、`/admin` 200）+ 测试会员 user_id 970105；**TestFlight/Release 上传未执行**。
- systemd 定时器（`account-server/deploy/`）：account-deletions、backup（每日 03:17+jitter）、club-automation、club-push、domain-outbox；`bojiclub-ai.service`（loopback 8787，包内未附 unit 文件）；`dongzuo-api.service`（127.0.0.1:8765，硬化+MemoryMax 220M）。
- 备份/恢复：`deploy/backup.py`（AES-256-GCM+scrypt 加密全量恢复包：MySQL dump --single-transaction、AI SQLite 快照、Apple .p8、nginx/php-fpm/systemd 配置；14 份保留；异地经 BOJI_OFFSITE_CMD）+ `restore.py` + 演练流程 `BACKUP-RECOVERY.md`；**实际恢复演练未执行过**（UNVERIFIED）。
- 标准部署脚本 `scripts/deploy-experience-sync.sh`：php lint → 跑服务端测试 → 比对线上 SHA-256（漂移即中止）→ 备份 → 原子 install → reload php-fpm → ERR-trap 自动回滚。Build 113 实际部署记录见 `docs/experience-upgrade-20261021/README.md:27-37`。
- `启动AI.command`（本机开发启动：`cd backend; python3 setup.py; python3 server.py`）；`scripts/check-*-on-mac.sh` 系列为编译/静态检查脚本（本副本无运行日志，未在解压目录执行过）。
- **安全备注（来自 PACKAGE-README.txt）**：部署过程中服务器 root 密码曾被共享，应轮换（列入 03 号风险 R-39）。

---

## 6. 与 V2 方案的架构对照速览（详见 02_GAP_ANALYSIS）

| V2 方案概念 | 现状对应 | 状态 |
|---|---|---|
| Club AI 首页/对话 | ClubAIHubView 分段 + ClubCoachView 任务轮询对话 | PARTIAL（无流式/无服务端会话/无卡片协议） |
| CardRegistry 动态卡 | 无（AI 报告卡为硬编码 SwiftUI，按 kind 分支） | MISSING |
| Composer 多模态输入框 | 分散（对话输入框/相机/语音各自入口） | MISSING（作为统一组件） |
| App Shell 双模式 + Sidebar | 5-Tab TabView | MISSING（结构不同） |
| Action Orchestrator / Proposal 状态机 | commands.php（3 命令）+ coach proposal/schedule_proposal 校验 + data_operations/domain_outbox | PARTIAL（有骨架，类型少、无通用状态机） |
| 事务 Outbox | domain_outbox + worker（消费者空实现） | PARTIAL |
| AI Gateway | account-server 代理 + ai_core 路由（3 供应商、熔断、同意域路由） | PARTIAL（无流式、无 token/成本台账按请求级） |
| Memory Engine | 无（历史仅客户端 6 组问答；insight ledger 为本地规则事实，非长期记忆） | MISSING |
| Insight Engine | ClubInsightRules（本地规则）+ automation prepare（服务端触发器） | PARTIAL（无排序评分/证据引用结构化） |
| 权威领域表（训练/营养/身体） | 单 JSON 文档 app_states + 三方合并 | CONFLICT（V2 假设领域表；现实是文档同步） |
| HealthKit 增量同步 | 按需 Statistics/Sample 查询 + 逐日分享同意 | PARTIAL（无 anchor/observer，V2 需评估是否必要） |
| 订阅权威链路 | RevenueCat webhook+REST+membership_entitlements | EXISTING（V2 可直接复用） |
| 俱乐部成长/发奖确定性 | club_progress 服务端计算 + claim 库存/单件校验 | EXISTING |
| Feature Flag | app_config（5 键，服务端生效）+ 客户端不消费 ai/club 开关 | PARTIAL |
| 主动程度（安静/平衡/积极） | automation daily/weekly/workout/partial + push quiet/budget | PARTIAL（语义不同） |
| 设计 Token #E3E7F0 | brandMist 已存在（DesignTokens.swift:24-26） | EXISTING（需统一 3 套并存系统） |

---

## 7. 审计方法、实测验证与限制

**本机实测结果（2026-10-23/24，Xcode 26.6）**——完整记录见 `docs/v2/evidence/phase0/test-baseline.md`：

| 验证项 | 命令 | 结果 |
|---|---|---|
| Python 离线回归 | `python3 -I tests/run_offline.py` | **640/640 OK**（21.0s） |
| Swift 规则回归链 | `python3 tests/run_swift_regressions.py …` | **29/52**（10 编译+13 运行失败——生成器与 Build 114 源码漂移，风险 R-41） |
| 主应用编译 | `xcodebuild … build`（iPhone 17 模拟器 Debug） | **BUILD SUCCEEDED** |
| XCUITest | `xcodebuild … test` | **21/21 passed** |
| PHP 套件（39+4 个） | `tests/run_php_suite.sh` | 未运行（本机无 php；文档记录 38/38） |

- 审计基于交付 zip 的静态代码阅读 + 上述可执行验证；**未访问**生产服务器、数据库、RevenueCat 控制台、App Store Connect——所有"已部署/已验收"陈述均为包内文档声称（外部 UNVERIFIED）。
- 本机工具链：Xcode 26.6 (17F113)、swift、python3 可用；**php 不可用**（影响本地运行 PHP 测试）。
- 无 .git：无法核对历史演进，仅能依赖包内 ~180 个过程文档。
- 大文件（SOURCE-MANIFEST.json 122KB、678 项动作清单等）只做结构抽样。
