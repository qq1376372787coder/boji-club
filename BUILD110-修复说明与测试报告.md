# 薄肌俱乐部 Build 110 修复说明与测试报告

日期：2026-10-18  
基线：`BojiClub-0.15.0-build109-visual-fix-20261018`  
版本：`0.15.0`，`CURRENT_PROJECT_VERSION = 110`（App 与 Widget 全部 6 处构建设置一致）  
范围：Build 109 审查报告中的 11 项缺陷、云端嵌套 Schema、分块/整包同步一致性、Club AI 日程提案闭环、阶段报告历史与过时标记，以及在 macOS/Xcode 上的构建与回归。

> 本报告区分五种状态：**源码已修**、**本机测试通过**、**模拟器验证**、**真机验证**、**生产部署**。未执行的验收不会写成已完成。

---

## 1. 修复清单

### P1-1 跨周/跨月顺延的周期归属

**改动文件**：`BojiClub/PlanShiftViews.swift`、`BojiClub/AppStore.swift`、`BojiClub/DailyExperience.swift`、`account-server/public/cloud-validation.php`、`account-server/public/index.php`

**原因**：原实现把目标日直接标记为源周期的 `start/endDate`，但源周期只覆盖 `start..start+6`。跨周后目标日的 key 不在该区间内，客户端 `ownedIntervals` 与服务端 `cloudExperienceValid` 都会出现归属不一致；旧云端数据也可能已经带有越界标记。

**解决方式**：
- 顺延前先确定每个目标日真正归属的周期：
  - 目标日已有覆盖它的周期 → 使用目标所在周期；
  - 目标日仍在源周期的七天窗口内 → 使用源周期；
  - 否则按源周期周界对齐，创建目标所在周的合法七天周期（`ClubShiftRules.shiftWeekAnchor`）。
- 执行后只重算与本次移动相关的周期，避免覆盖其他计划；源日清空后保留周期标记并重算 `plannedDates`。
- `PlanShiftRecord` 新增可选字段 `sourceCycles`（目标日→来源周期）、`effectScope`、`reason`，保留来源计划依据与生效范围；旧记录无这些键仍可解码。
- 服务端新增 `cloudNormalizeCycleOwnership`：对历史越界周期标记做修复（移除越界标记、清理越界/重复 `plannedDates`），不删除任何训练记录；随后仍执行严格校验。

**风险**：历史数据中原本越界的周期标记会被服务端修正；客户端旧版本不认识的三个新字段由服务端按可选字段接受，不会阻断同步。

### P1-2 旧草稿/模板迁移事务安全

**改动文件**：`BojiClub/AppStore.swift`、`BojiClub/ManualPlanView.swift`、`BojiClub/ManualPlan.swift`

**原因**：原迁移在任何读取失败后仍写入“迁移完成”标记，导致下一次不再重试；落盘失败时也未恢复已修改的内存状态；空白新草稿可能覆盖无法读取的旧 `draft.json`。

**解决方式**：
- 只有所有待迁移内容成功读取并 `persist` 成功后才写完成标记。
- 任何读取/解码/落盘失败都恢复迁移前内存快照，保留原文件并保持未完成状态，下次安全重试。
- 草稿读取失败时按账号记录恢复阻断，`ManualPlanView` 不创建空白草稿、不自动保存，显示可重试错误。
- 模板文件失败与草稿失败分开：模板失败不阻塞新草稿，但仍不写完成标记。
- `planMigrationNotice` 记录所属账号，切换账号时不再显示上一个账号的问题；成功后清除。
- 云端异常草稿（`days != 28`、周期非法）在进入界面前被过滤，避免数组下标越界；界面提示原记录已保留。

**风险**：迁移会比以前更“保守”（可能延后完成标记），这是为了避免误标完成与数据覆盖；原文件始终保留。

### P1-3 云端嵌套 Schema 与整包/分块一致性

**改动文件**：`account-server/public/cloud-validation.php`、`account-server/public/index.php`、`account-server/public/cloud-parts.php`、`BojiClub/AppStore.swift`

**原因**：`planDraft.days`、阶段报告趋势点等使用 `json` 通配，畸形嵌套可通过；分块同步只在提交时做结构校验，没有执行整包同步的语义校验；`meta` 分块缺少 `days` 时无法通过 `decodedState`。

**解决方式**：
- 新增严格 Schema：`planDraftDay`、`planDraftMovement`、`trendPoint`、`trendResult`、`scheduleProposal`、`scheduleMove`；`suggestedForProfile` 改为完整 `profile`；`planDraft.version` 改为 `identityVersion`。
- 新增语义校验：草稿必须 28 天、每日动作/组数/重量/次数/秒数/休息上限、逐组目标上限；趋势点必须落在报告区间内，`sampleCount` 与点数一致；日程提案 1–7 项、from/to 唯一且不相等。
- `decodedState` 统一调用 `cloudExperienceValid`，整包与分块提交（`cloudPartSyncDay`、`cloudPartCommit`）都经过同一组结构 + 语义校验。
- `state.days` Schema 改为可选，但 `decodedState($input, requireDays: true)` 仍强制整包必须有 `days`；仅 meta 分块使用 `requireDays: false`。
- 拒绝发生在事务/提交前，失败会回滚，原云端状态不被覆盖。

**风险**：旧客户端上传的历史数据若含越界周期标记，会先被服务端规范化再校验；不会删除记录。`sampleCount` 与趋势点数量一致性依赖客户端生成规则，已由 Build 110 测试覆盖。

### P2-1 自由计划的休息日与占位日

**改动文件**：`BojiClub/ManualPlan.swift`、`BojiClub/ManualPlanView.swift`

**原因**：页面提示“清空标题”，但校验仍按 `placeholder == true` 拦截，用户按提示操作无法预览。

**解决方式**：
- 新增明确“设为休息日”操作，一次清空标题、待配置标记和动作（仅改草稿）。
- `placeholderCount` 只统计“仍有标题但没有动作”的待配置日；用户清空标题后该日按休息日处理。
- 预览页按 `isRestDay` 显示休息日。

### P2-2 删除体重仍计入报告覆盖

**改动文件**：`BojiClub/DailyExperience.swift`、`BojiClub/TrendAnalysis.swift`

**原因**：删除体重留下 `kilograms == nil` 的墓碑记录，报告用 `bodyWeight != nil` 判断，仍算一天实际记录/测量。

**解决方式**：
- `BodyWeightEntry.hasMeasurement` 统一要求“有效且数值存在”。
- 阶段报告的覆盖天数、实测天数、上一阶段覆盖判定全部改用该口径。

### P2-3 自定义动作身份大小写不一致

**改动文件**：`BojiClub/TrendAnalysis.swift`、`BojiClub/ClubWorkoutSummary.swift`、`BojiClub/ClubWorkoutSummaryView.swift`

**原因**：训练总结使用 `uuidString.lowercased()`，趋势使用 `uuidString`，同一自定义动作可能被拆成两个 identity。

**解决方式**：
- 新增 `ClubExerciseIdentity`，统一自定义 UUID 小写、library/query 去空白并小写。
- 训练总结、趋势分析、阶段报告、训练总结页筛选全部调用同一实现。
- 旧数据无需迁移：identity 每次从动作记录重新计算。

### P2-4 同一天第二场未确认训练隐藏第一场已确认成绩

**改动文件**：`BojiClub/Models.swift`、`BojiClub/TrendAnalysis.swift`、`BojiClub/ClubInsightRules.swift`、`BojiClub/ClubInsightLedger.swift`、`BojiClub/JourneyRules.swift`、`BojiClub/DailyExperience.swift`、`BojiClub/ClubAutomationService.swift`

**原因**：趋势与阶段报告按整天 `isTrainingConfirmed` 过滤；同日一场未确认会让另一场已确认训练也暂时消失。

**解决方式**：
- `DayLog` 新增 `confirmedWorkoutSessions`、`hasConfirmedTraining`、`confirmedCompletedSets`。
- `TrainingEvidence.confirmedSlices` 按场次拆分，只采用 `savedAt != nil` 的场次；旧数据无场次时沿用整天确认。
- 趋势、阶段报告的完成天数/完成组、训练洞察、周复盘就绪度、自动化统计改用已确认场次口径。
- 首页“待确认”等整天状态仍保留整天语义，避免把未确认场次误报为已完成。

### P2-5 自由计划描述/意图未进入正式版本

**改动文件**：`BojiClub/ManualPlan.swift`、`BojiClub/ClubHistory.swift`、`BojiClub/ProductArchitecture.swift`、`BojiClub/AIService.swift`、`account-server/public/cloud-validation.php`

**解决方式**：
- `AIResult` 新增可选 `plan_description`、`plan_intent`、`plan_pattern`。
- 自由计划 `result()` 写入描述、意图、编排方式；`ClubPlanVersion` 新增同名可选字段与 `notes`。
- 版本详情显示描述、意图、编排方式；旧版本只显示其已有的 `notes`，不补造。
- 服务端 `planVersion`/`result` Schema 接受这些可选字段。

### P2-6 计划卡未按被点选周期进入详情

**改动文件**：`BojiClub/ProductArchitecture.swift`、`BojiClub/TrainingPlansView.swift`

**解决方式**：
- 新增 `PlanListRoute(cycleStart:)`；每张计划封面卡传入自己的 `cycle.start`。
- `TrainingPlansView` 新增 `initialCycleStart`，优先按被点选周期定位。
- “查看我的计划”仍使用默认焦点。

### P2-7 无计划用户被兼容占位周期误判为已有计划

**改动文件**：`BojiClub/ProductArchitecture.swift`

**解决方式**：
- `hasCurrentPlan` 只认 `plannedDates` 非空且未结束的周期，或未来实际有动作的日期。
- 摘要区分“当前计划”和“即将开始”；未来计划不再伪装成当前计划；只有历史计划时不显示当前计划摘要。

### Club AI 闭环

**改动文件**：`backend/adaptive_core.py`、`backend/coach_core.py`、`BojiClub/ClubCoachView.swift`、`BojiClub/ClubAdaptive.swift`、`BojiClub/ClubInsightLedger.swift`、`BojiClub/AppStore.swift`、`account-server/public/cloud-validation.php`

**已实现**：
- 服务端（Python AI 服务）新增 `clean_schedule_proposal`：模型只能对 `upcoming` 中尚未开始的日期提出 `from→to`，目标必须在请求日期后 1–28 天，from/to 分别唯一；`baseline` 由服务端从 `upcoming` 生成，不信任模型输出。
- Club AI 提示词新增日程提案约束与输出格式；`clean_result` 输出 `schedule_proposal`。
- 服务端云端 Schema 增加 `scheduleProposal`，拒绝重复、from==to、超过 7 项等畸形提案。
- 客户端提案卡新增“不采用”与“已拒绝”状态；行动状态机新增 `rejected`（客户端与服务端 Schema 一致）。
- 阶段报告新增 `evidenceDigest`；详情页显示“依据已变化，报告可能过时”，并列出同一区间的历史版本。
- 过去漏练的重排入口沿用已有计划跟进洞察（`schedule_shift` action）与顺延预览，不覆盖过去实际记录。

**仍受外部依赖限制**：
- 生产 AI 服务需要部署本次 `backend/` 变更后，真实模型才会受约束地产生 `schedule_proposal`；本地已用单元测试验证清洗器。
- 提醒去重的稳定事件 ID 已有实现（洞察账本 digest + 事件 ID），本轮未新增推送服务端事件表。

---

## 2. 编译修复（Build 109 基线遗留）

在 Xcode 26.6 / Swift 6.3 下，基线存在以下编译错误，已修复：

| 文件 | 问题 | 修复 |
| --- | --- | --- |
| `TrainingRegistrationViews.swift` / `WorkoutView.swift` | 属性名 `set` 被解析为 setter 关键字 | 重命名为 `trainingSet`，更新调用点 |
| `DesignTokens.swift` | `.white`/`.red` 在 switch 分支缺少上下文类型 | 显式 `Color.white`/`Color.red` |
| `BojiComponentGalleryView.swift` | `Text + Text` 在新 SDK 不可用 | 改为 `HStack` |
| `PlanHubViews.swift` | `0..<optional ?? 0` 优先级错误；多语句函数缺少 `return` | 加括号与显式 `return` |
| `AppStore.swift` | `slots.contains(\.enabled)` 在 Swift 6 需要 `where:` | 改为闭包 |
| `PlanShiftViews.swift` | 跨文件 extension 访问 `private` 状态/持久化 | 将顺延执行移入 `AppStore.swift`，保持私有边界 |
| 测试脚本 | `.sh` 为 CRLF；若干测试夹具标记/变量与 Build 109 源码不一致 | 统一 LF；更新夹具，保留等价或更强断言 |

---

## 3. 本机执行的验证

环境：macOS 26.6.2，Xcode 26.6 (17F113)，Apple Swift 6.3.3，iPhone 17 模拟器 (iOS 26.5)。

### 3.1 Xcode 工程

```bash
xcodebuild -version
# Xcode 26.6 / Build version 17F113

xcodebuild -list -project BojiClub.xcodeproj
# Targets: BojiClub, BojiClubWidget
# Schemes: BojiClub, BojiClub-TestFlight, BojiClubWidget, RevenueCatUI, ...
```

### 3.2 完整脚本回归

```bash
sh scripts/check-upgrade-on-mac.sh
```

结果：**退出码 0**，全部脚本通过，末尾 `** BUILD SUCCEEDED **`。包含：

- `run_repair_v77.sh`、`run_upgrade_v140.sh`、`run_manual_plan.sh`、`run_history.sh`、`run_insight_ledger.sh`、`run_goal_context.sh`、`run_plan_changes.sh`、`run_workout_summary.sh`、`run_automation.sh`、`run_coach.sh`、`run_plan_followup.sh`、`run_adaptive.sh`、`run_retry_v106.sh`、`run_compile_v107.sh`
- 新增 `run_build109.sh`：42 项针对本轮缺陷的断言
- TestFlight Scheme / iOS Simulator 构建

### 3.3 Python 离线总入口

```bash
python3 -I tests/run_offline.py
```

结果：**Ran 574 tests — OK**。  
（入口位于 `tests/run_offline.py`；仓库根目录没有同名脚本。）

### 3.4 Debug / TestFlight 构建

```bash
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/boji-debug-build109 CODE_SIGNING_ALLOWED=NO build
# ** BUILD SUCCEEDED **

xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/boji-upgrade-build107 CODE_SIGNING_ALLOWED=NO build
# ** BUILD SUCCEEDED **
```

### 3.5 模拟器运行与截图

Debug 构建已安装到 iPhone 17 模拟器（iOS 26.5），使用 DEBUG 预览账号（`account.preview-enabled=complete`）启动，截图见 `build110-evidence/screenshots/`：

- `home.png`：首页（空计划、视频首帧、Club AI Insights、原生 TabView）
- `plans.png`：计划页空状态（AI 制定 / 自由创建 / 查看我的计划）
- `records.png`：记录页空状态
- `club.png`：俱乐部页
- `profile.png`：自己页

**限制**：本机没有可用的触控注入工具（无 `idb`/`cliclick`，辅助访问权限不可用），因此未自动完成“点计划卡进入指定周期、顺延预览、训练登记、滚动到底”等交互截图；这些需要人工或 XCUITest 在模拟器/真机补验。

### 3.6 新增测试覆盖

`tests/run_build109.sh`（42 项）：

- 顺延锚点：同周保持源周期；跨周目标进入下一周合法七天周期。
- 休息日：`setRestDay` 一次清空占位/标题/动作；清空标题后校验通过。
- 体重墓碑：不计覆盖天数、不计实测次数；修改源记录后报告标记过时。
- 同日多场：已确认场次在另一场未确认时仍进入趋势、阶段报告只计已确认组。
- 自定义身份：含 A–F 的 UUID 统一小写，跨三天仍匹配为同一趋势。
- 计划版本：描述、意图、编排方式、notes 进入 `ClubPlanVersion`。

`tests/test_coach.py` 新增 3 组日程提案测试：合法提案保留服务端 baseline；外来/过去/重复/超量提案被拒；未授权或缺 upcoming 时拒绝。

`tests/test_build109_validation.php`：新增云端 Schema/语义/周期规范化/拒绝状态用例（**本机未执行**，见下）。

### 3.7 PHP 验证

本机没有 `php` 可执行文件，无法在本地执行；已在生产服务器（PHP 8.3.33）上完成：

```bash
php -l /opt/bojiclub-account/public/cloud-validation.php
php -l /opt/bojiclub-account/public/index.php
php -l /opt/bojiclub-account/public/cloud-parts.php
php /tmp/build110-upload/test-live.php
```

结果：3 个文件均无语法错误；新增云端 Schema/语义测试 **PASS 22**。

服务器上另有 22 个纯 PHP 回归测试（`test_repair_v77`、`test_club_history`、`test_club_insights`、`test_plan_changes`、`test_workout_insights`、`test_plan_explanation`、`test_automation_contract`、`test_build106`、`test_cloud_scope_v73`、`test_cycle_v75`、`test_experience_v21/v25`、`test_multi_meal`、`test_onboarding_plan_preview`、`test_phase1/2/3`、`test_repair_v38/v46/v48`、`test_training_feedback_v63`、`test_ai_stability`）全部通过：**22/22**。

### 3.8 生产部署记录（2026-10-18）

服务器：`117.50.119.49`，root，Linux 6.12 / PHP 8.3.33 / nginx + php-fpm + MariaDB；AI 服务为 `bojiclub-ai.service`（127.0.0.1:8787）。

**部署基线说明**：服务器上已有 2026-10-17 的较新版本（包含 R04 分块语义校验、嵌套 `planMovement/planDraftDay/phaseTrend` Schema、`schedule_shift` action）。因此没有用包内旧文件直接覆盖，而是以服务器现版本为基线，叠加 Build 110 改动后再部署。

已部署文件：

| 服务器路径 | 变更 |
| --- | --- |
| `/opt/bojiclub-account/public/cloud-validation.php` | 保留 R04 validator；新增严格草稿/阶段报告/日程提案语义校验、新增可选字段、周期规范化、provenance 合并 |
| `/opt/bojiclub-account/public/index.php` | `decodedState(requireDays)` 支持 meta-only 分块提交；days 可选处理 |
| `/opt/bojiclub-account/public/cloud-parts.php` | meta 使用 `requireDays=false`；AI job 日程提案语义校验 |
| `/opt/bojiclub-ai/adaptive_core.py` | 日程提案目标窗口 1–28 天、类型/重复校验、规则文案更新 |

备份（回滚点）：

```text
/opt/bojiclub-account/.backups/build110-20261018-020432/
/opt/bojiclub-ai/.backups/build110-20261018-020432/
```

服务操作与验证：

```bash
systemctl reload php-fpm
systemctl restart bojiclub-ai
systemctl is-active php-fpm nginx bojiclub-ai   # active / active / active
curl -sS http://127.0.0.1:8787/health           # {"status":"ok","version":"0.4"}
curl -k -sS -o /dev/null -w '%{http_code}' https://117.50.119.49/account/v1/me  # 401（路由正常）
```

线上 PHP 测试 22 项通过；AI 日程提案清洗测试通过（接受 1–28 天合法移动，拒绝外来/过去/同日/超窗提案）。

**未覆盖**：没有真实账号令牌，因此未执行一次完整的“App→HTTPS→整包/分块提交→云端读回”端到端同步；需要在有测试账号时补验。

---

## 4. 数据迁移、兼容与回滚

### 4.1 兼容

- 所有新增客户端字段均为可选：`PlanShiftRecord.sourceCycles/effectScope/reason`、`ClubPlanVersion.planDescription/planIntent/planPattern/notes`、`AIResult.plan_*`、`PhaseReport.evidenceDigest`。旧数据解码为 `nil`。
- `ClubActionRecord` 新增 `rejected`，旧值 `pending/completed/failed/expired/reference` 继续有效。
- 服务端 Schema 对上述字段均为可选；旧客户端上传不会因缺少新字段被拒。
- 云端异常草稿在客户端被过滤，不会越界；原记录保留。

### 4.2 迁移

- 旧草稿/模板迁移改为事务式：失败不写完成标记、恢复内存、保留原文件。
- 服务端在合并时修复历史越界周期标记（只改归属，不删训练记录）。
- 不通过清空用户数据解决兼容问题。

### 4.3 回滚

- 源码回滚：恢复 Build 109 包即可；Build 110 写入的云端新增字段均为可选，旧客户端会忽略。
- 服务端回滚：使用 `/opt/bojiclub-account/.backups/build110-20261018-020432/` 与 `/opt/bojiclub-ai/.backups/build110-20261018-020432/` 中的原文件覆盖，然后 `systemctl reload php-fpm && systemctl restart bojiclub-ai`。已规范化的历史周期标记不会恢复，但训练记录完整，旧客户端会按自身规则重新推导周期。
- 本地草稿：迁移始终保留原文件；如需回滚，删除“迁移完成”标记（`manual-plan-sync-migrated.v1.<账号>`）即可触发重新迁移。

---

## 5. 敏感信息与交付完整性

- 本次修改未新增任何密钥、`.env`、生产配置、私钥或真实用户数据。
- 截图使用 DEBUG 预览账号（`-1001`），不是真实账号。
- 交付包不应包含：`.DS_Store`、`DerivedData`、`.build`、临时截图原文件、生产服务端配置。
- 建议在打包后执行：

```bash
unzip -t BojiClub-0.15.0-build110.zip
```

并复核 `BojiClub.xcodeproj/project.pbxproj` 中 6 处 `CURRENT_PROJECT_VERSION = 110`、`MARKETING_VERSION = 0.15.0`。

---

## 6. 验收状态汇总

| 状态 | 结果 |
| --- | --- |
| 源码已修 | 11 项审查缺陷、云端 Schema、同步一致性、Club AI 日程提案、报告历史/过时标记、编译错误均已修改 |
| 本机测试通过 | Swift 全部脚本通过；Python 574 项通过；新增 Build 109 42 项通过 |
| 模拟器验证 | Debug 构建已运行并截取 5 个顶层入口；交互路径未自动化 |
| 真机验证 | **未执行** |
| 生产部署 | **服务端已部署**（账户 PHP + AI 服务）；App 二进制未发布 |
| PHP 语法/测试 | **已执行**：3 个文件 lint 通过；线上 22 项纯 PHP 回归 + 新增 22 项 Schema 校验通过 |
| 端到端同步 | **未执行**（缺少测试账号令牌） |

结论：服务端 Build 110 已上线并通过语法、单元与健康检查；App 二进制仍处于源码/模拟器构建阶段，尚未发布 TestFlight/App Store，也尚未做真机验收。真实账号的整包/分块同步与 Club AI 提案需在测试账号下补验。
