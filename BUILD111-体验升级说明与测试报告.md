# 薄肌俱乐部 Build 111 体验升级说明与测试报告

日期：2026-10-18  
基线：Build 110（0.15.0）  
版本：`MARKETING_VERSION = 0.15.0`，`CURRENT_PROJECT_VERSION = 111`（App、Widget、UI Test 共 8 处构建设置）  
依据：《首页、计划、训练、记录与 Club AI Insights 体验升级方案-20261018》

## 一、交付范围

本轮按方案完成六个阶段，并落实用户确认的三项决策：

1. 首页：身体状态卡、沉浸式训练主卡、单条优先洞察摘要。
2. 计划：日历置顶、今天居中、周/月动画、日历内移动预览、休息日、创建入口分组。
3. 训练：紧凑登记、休息暂停/继续、跨五 Tab 迷你训练栏、进程重启恢复、Live Activity 当前动作/暂停状态。
4. Club AI：单层导航 Hub、优先洞察、今天/更早时间线、chip 筛选、共享依据披露、对话草稿与真实快捷问题。
5. 记录：多尺度趋势（3/6/12 月、自定义、累计）、确认训练口径、体重多尺度、报告入口。
6. 验收：完整深色模式、5 条 XCUITest 关键路径、Build 111 构建与截图。

## 二、关键改动

### 首页

- `bodyPanel` 改为“身体状态”：最近真实测量大数字、`BodyTrendChart` 真实点趋势、可选目标线/目标差、`查看趋势` 与直接 `WeightEntryEditor`；移除本周训练/热量/蛋白三列与“当前方向”。
- 主视觉卡改为 380pt（大字体 460pt）沉浸卡，按 `HomeTrainingState` 切换开始/继续/查看/休息日/无安排；保留训练/Club Keepsake 横滑与页码。
- `AIInsightsCard` 改为一条最高优先级洞察 + 最多两条短跟进 + “查看全部”“问 Club AI”；移除日报/周报重复入口。
- 删除死代码 `todayActionCard` 与旧日期详情。

### 计划

- `PlanCalendarRules`：以选中日期为中心的 7 天窗口、周一开头的月网格、周/月切换。
- `PlanWeekCard`：日历置顶、今天居中、选中日期 pill、展开/收起使用 `BojiMotion.cardExpand`、Reduce Motion 短淡入、切月保留选择。
- `ClubPlanHub`：移除大标题、独立当前计划卡和计划封面横滑轮播；周期摘要融入日历标题。
- `PlanDaySummaryCard` 按状态提供开始/查看/补记/调整/提前练/加练/设为休息日/查看去向。
- `PlanMoveSheet`：日历选目标日、硬/软冲突、替换显式确认、周期变化、历史保留说明；执行复用 `ClubShiftRules` 与 `shiftPlannedSchedule`（新增 `allowTodaySource`）。
- `setPlannedRestDay`：清空未开始安排、记录删除 ID、重算周期训练日，保护已开始/未确认记录。
- 创建入口：AI 主按钮、自由创建次按钮、动作库/查看我的计划/方案版本辅助行。

### 训练

- 训练卡展开状态上移到 `WorkoutView`，只展开当前动作；收起行 52pt 缩略图、70pt 行高。
- 休息条支持暂停/继续、+30/60/90/120、跳过；暂停剩余写入 `ClubRestResume.pausedRemaining`，重启后可恢复。
- `WorkoutPauseService` + `ClubWorkoutPauseStorage`：按账号/日期/session 本地持久化暂停与累计暂停；训练用时、迷你栏、Live Activity 共用。
- `MiniWorkoutBar`：78pt（大字体 96pt），已用时间、当前动作、组进度、休息倒计时、暂停/继续；通过 `miniWorkoutInset` 挂到五个 Tab，位于原生 Tab 上方；点击恢复对应日期训练。
- Live Activity `ContentState` 新增可选 `currentExerciseName/currentSetNumber/isPaused/pausedElapsedSeconds/restPausedRemaining`；服务在应用启动/回前台/暂停/组变化时 `sync`；锁屏与灵动岛显示当前动作、组进度、暂停/休息；旧 Activity 可解码。
- `Info.plist` 增加 `bojiclub://training?date=...`，Live Activity 点击回到对应训练。

### Club AI

- `ClubAIHubView` 改为单一 `NavigationStack`，移除“动态/报告/对话”分段；根视图 `ClubAIHomeView` 展示状态头、最高优先级洞察、最近跟进、查看全部/完整报告/问 Club AI。
- `ClubCoachView` 单导航标题 “Club AI”；移除大 intro 卡；快捷问题由 `ClubCoachRules.quickQuestions` 根据真实记录生成；输入草稿按账号/对话存 `UserDefaults`。
- 时间线筛选改为 `BojiChipRow`（全部/训练/饮食/身体/计划），阅读状态与时间范围收进菜单；今天/更早由 `ClubInsightTimelineRules` 分组。
- `ClubEvidenceDisclosure` 统一展示依据、记录日期、观察时间与 current/updated/withdrawn/expired 状态。
- 参数与日程提案保留拒绝/已应用/过期状态；日程提案继续走 `PlanMoveSheet`/顺延预览。

### 记录

- `ReviewTrendRules`：3/6/12 月、自定义（≤24 月）与累计；≥60 天按月，短区间按日；缺失桶省略、不补零。
- 指标：确认组、训练量、计时分钟、训练天数、饮食天数、热量、蛋白质、体重、测量次数；热量/蛋白只对有营养记录的天取平均，体重只取实测。
- `ReviewDashboardView` 月度回顾改为确认训练天数/确认组/饮食记录天数/实际称重；趋势卡使用 chip + 指标菜单 + 实际/计划柱、体重点线、目标虚线。
- `BodyWeightView` 改为 3/6/12 月与自定义；复用 `BodyTrendChart`，至少两点才连线。
- 报告历史/过时提示沿用 Build 110；报告入口保留在记录页。

### 深色模式

- `BojiColor` 全部改为 `UIColor` 动态语义色；页面/卡片/输入/日历/文字/分隔线/质量色随系统深浅切换。
- 移除 `.preferredColorScheme(.light)`；主按钮前景使用动态 pageBackground，保留影像上的白色文字与相机遮罩。
- `FlowPalette` 与品牌色资产（BrandAccent/BrandOnAccent 已有 dark 变体）统一。
- 审计并替换关键页面硬编码白/黑表面；相机、头像绘制等有意保留。

## 三、验证结果

环境：macOS 26.6.2、Xcode 26.6 (17F113)、Swift 6.3.3、iPhone 17 模拟器 (iOS 26.5)。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Swift 全量规则 | `sh scripts/check-upgrade-on-mac.sh` | 退出码 0，TestFlight simulator build `** BUILD SUCCEEDED **` |
| Phase 0/日历/训练/趋势规则 | 同上（`run_experience_v150.sh`） | **38 项通过** |
| Python 离线 | `python3 -I tests/run_offline.py` | **580 项通过** |
| UI 自动化（浅色） | `sh scripts/check-experience-v150-ui.sh` | **5/5 通过** |
| UI 自动化（深色） | 同上，系统外观 dark | **5/5 通过** |
| Debug 构建 | `xcodebuild ... -configuration Debug ... build` | `** BUILD SUCCEEDED **` |
| TestFlight 构建 | `xcodebuild ... -scheme BojiClub-TestFlight ... build` | `** BUILD SUCCEEDED **` |
| 工程 | `xcodebuild -list` | Targets：BojiClub / BojiClubWidget / BojiClubUITests |

UI 测试覆盖：
- `testFiveTabsAndHomeBodyCard`
- `testPlanCalendarExpandsAndOpensMovePreview`
- `testMiniWorkoutBarSurvivesTabsAndRelaunch`（含终止/重启恢复）
- `testClubAIUsesOneNavigationLayer`
- `testRecordsTrendScales`

截图：`build111-evidence/screenshots/`，浅色/深色各 6 张（home、plans、plansmonth、records、profile、club）。

## 四、兼容与数据安全

- **没有新增同步字段**：暂停、暂停休息、对话草稿全部存 `UserDefaults`；Build 110 云端 Schema 不需要变更。
- 现有 `SavedState/DayLog/WorkoutSession/PlanShiftRecord/PhaseReport` 可解码；旧 Live Activity 因新字段可选仍可解码。
- 休息/暂停键按账号、日期、session 隔离；切换账号或结束时清理。
- 计划移动复用既有 fingerprint、硬/软冲突、两阶段写入和回滚；休息日只改未来未开始安排。
- 趋势缺失桶省略；确认训练只用已确认 session；删除体重墓碑不计测量；不补零、不伪造曲线。
- 深色模式仅改语义 token 与表面色；未改变数据或交互契约。

## 五、未完成 / 明确延后

- **真机未验证**：Live Activity 灵动岛/锁屏、视频后台恢复、实际触控与动态字体仍需真机验收。
- **iOS 17 运行未验证**：本机只有 iOS 26.5 模拟器；工程仍以 iOS 17 为部署目标并已编译，未在 iOS 17 runtime 运行。
- **小屏未运行**：截图使用 iPhone 17；小屏/SE 尺寸需补跑。
- **Live Activity 内交互暂停**（AppIntents）延后；App 内暂停会同步更新。
- **跨设备暂停恢复**延后（需同步 Schema）。
- **Club AI 图片理解**延后（服务端当前无 vision 输入）；照片入口仍指向餐食流程。
- **自定义趋势 >24 个月/亚日粒度**延后。
- **服务端**：Build 111 不改变同步契约，本轮未重新部署；服务器保持 Build 110 已部署版本。

## 六、验收状态

| 状态 | 结果 |
| --- | --- |
| 源码已修 | 六个阶段全部实现；深色模式与 UI 测试 target 已加入 |
| 本机测试通过 | Swift 全量通过；Python 580 项通过；Build 111 规则 38 项通过 |
| 模拟器验证 | 浅色/深色 5 条 UI 测试通过；5 个入口截图完成 |
| 真机验证 | **未执行** |
| 生产部署 | 服务端无变更，未重新部署；App 未发布 TestFlight/App Store |
