# BUILD140 · 本轮改造与验收（UI 大改 · 原生组件 · 玻璃质感）

2026-11-08 建档。基线：0.15.9 / Build 139。本轮由 Chief 担任验收负责人，各成员修改完成后交 Chief 验收，不合格重新派活，直至验收通过。

本文档是本轮的唯一进度台账，包含三部分：**A. Bug 清单**、**B. 改造清单**、**C. 验收记录表**。各成员负责往对应表格里更新，改一项勾一项。

---

## 0. 本轮验收通过标准（Chief 定）

| 编号 | 标准 | 说明 |
|---|---|---|
| ① | 无崩溃、无明显 bug | A 表全部关闭或降级为"延后"并经 Chief 同意 |
| ② | 操作流程顺 | 登录 → 首页 → 训练 → 记录 → 同步/支付主线无卡壳 |
| ③ | 全部改用 iOS 原生组件 + iOS 26/27 原生玻璃质感 | 不再自绘自建控件；最低系统 iOS 17，老系统自动降级磨砂（Design.swift 已有 glassEffect 先例） |
| ④ | 视频自然融入界面 | 素材：`design-assets\brand-video.mp4`（由用户提供的视频转存，2 MB） |
| ⑤ | 动效高级华丽但不廉价 | 用原生动画/转场，节奏统一，见界面设计的动效规范 |

素材与参考：
- 品牌视频：`design-assets\brand-video.mp4`
- 用户原始素材：`C:\Users\biccy\Downloads\kling_20261017_VIDEO_主体_年轻东亚男性__5195_0 (1).mp4`
- 用户诉求原话：bug 多、流程不通顺、UI 与交互不满意；要 iOS 原生组件 + iOS 26/27 原生玻璃效果，不要自绘自建组件；视频融入界面提升质感；设计制作动画特效提升高级感、华丽感。

---

## A. Bug 清单（测试验收维护，其他人可追加）

填写格式：编号 / 所在页面或功能 / 复现步骤 / 严重程度（P0 崩溃·P1 功能不通·P2 明显瑕疵·P3 体验小问题）/ 负责人 / 状态（待处理·处理中·已修复待验·已验收关闭）/ 备注。

> 本轮无 Xcode／真机安装链路未定，以下复现步骤均为**源码级静态核对**，标「待模拟器/真机复核」，不代表已实际复现。

| 编号 | 页面/功能 | 复现步骤（静态核对） | 严重度 | 负责人 | 状态 | 备注 |
|---|---|---|---|---|---|---|
| BUG-001 | 通知深链（训练提醒等） | 训练进行中（或 AI 会话可见时）点推送通知：`BojiClubApp.swift:218` 的 `.sheet(item:)` Binding 在 `store.trainingInterfacePresented`/`store.clubAIInterfacePresented` 为真、或 `route.kind == "training"` 时直接返回 nil，通知被静默吞掉，无任何跳转或提示 | P1 | 苹果开发 | 待处理 | 苹果开发提供，测试验收已核对源码确认；建议改为可跳转并给「已跳转」反馈 |
| BUG-002 | 登录→首页入口状态机 | 登录后依次过 `account.phase`→`MembershipGateView`→`IndependentProfileOnboardingView`→`FirstLaunchWalkthroughView`→主壳，四层任一状态回写不及时即卡在门页 | P2 | 苹果开发 | 待处理 | 苹果开发提供，待模拟器复核 |
| BUG-003 | 训练登记输入 | 训练中切换重量/次数输入：自绘 `ClubNumericKeypad` 与系统键盘（keypadWeight 开关）并存，输入串轨且 VoiceOver 不可达 | P1 | 苹果开发 | 待处理 | 与 B1 的 IOS-001 改造项同源，改造后自动关闭 |
| BUG-004 | 组间休息状态 | 暂停/恢复休息并跨午夜或跨时区：`pauseService.state` 与 `restDeadlines` 双源（`ClubAIShell.swift:166-172`），提醒取消与恢复重排边界多，是卡顿高发区 | P2 | 苹果开发 | 待处理 | 待真机/跨日复核 |
| BUG-005 | 品牌视频未融入界面 | 主壳空态 Hero 卡 `heroGlassCard`（`ClubAIShell.swift:1172`）仍是渐变+TimelineView 流光占位，源码注释明写「视频资产待补」；`design-assets/brand-video.mp4` 在工程内无任何引用 | P1 | 苹果开发／界面设计 | 待处理 | 直接对应验收标准④；素材已入库，技术位建议见苹果开发清单第四节 |
| BUG-006 | 侧栏无障碍审计 | 默认侧栏自动审计仍报 3 个 `element=nil` 对比度失败 + 2 个「大字号可能裁切」预测（`docs/native-ui-20261024/diagnostics/sidebar-ax-triage.md`） | P2 | 苹果开发 | 待处理 | 上一轮未关闭项；草稿标题实测 15.81:1 非误报，但未知项无法定位 |
| BUG-007 | 滚动性能回归 | 相同 SE3 模拟器 Debug 前后对比：滚动 CPU 0.304→0.448 秒（+47.2%），指令数 +38%（`docs/native-ui-20261024/performance/performance-comparison.md`） | P2 | 苹果开发 | 待处理 | 未做采样归因；影响「华丽动效」的流畅度观感 |
| BUG-008 | 顶栏工作区选择器小屏溢出 | iPhone SE（375pt）下 `ClubModeCapsulePicker` 分段选择器 `maxWidth: 300`，加左 44pt 侧栏钮 + 右 44pt 更多钮 = 388pt > 375pt，可能压缩/截断 | P3 | 苹果开发 | 待处理 | 仅大字号走 `.menu` 降级；小屏待复核 |
| BUG-009 | 强制解包风险点 | 静态扫描 31 处 `!`，多数有前置 guard；风险相对高的：`AppStore.swift:2111`（`state.days[key]!.meals[index]`）、`ExerciseLibraryView.swift:143/168/178`（`components.url!`）、`MembershipService.swift:240`（`self.notice!`）、`HealthViews.swift:206`（`URL(string:)!`） | P3 | 苹果开发 | 待处理 | 未发现必然崩溃路径，建议随改造一并加 guard |

> 用户直接在群里反馈的具体 bug 和流程卡壳点，由测试验收转记到此表。
>
> 另：`KNOWN-ISSUES.md` 列出的功能差额（E6 距离计量、D6 提醒频率学习、E7 围度/体脂独立流程、漏练补排、行动状态机全面接入、草稿并发分叉）属**已知未实现功能**，不计入本轮 bug 编号，单独跟踪。

## B. 改造清单（按负责人分表）

### B1. 苹果开发 · 自绘控件 → 原生组件 + 玻璃改造

| 编号 | 现状（自绘/自建控件或流程不通点） | 目标（原生组件/玻璃方案） | 涉及文件 | 状态 | 备注 |
|---|---|---|---|---|---|
| IOS-001 | LiquidCheckbox 自绘圆+波纹勾选 | 原生 Toggle 语义 + symbolEffect(.bounce.up) + 触感 | DesignTokens.swift:673、TrainingRegistrationViews.swift:293/298 | 待处理 | 摸底文档 A 节 |
| IOS-002 | ClubNumericKeypad 自绘数字键盘 | 系统键盘 decimalPad + 原生 TextField | Experience123.swift:141、TrainingRegistrationViews.swift:630 | 待处理 | VoiceOver 不可达 |
| IOS-003 | TrainingNumericInput125 包 UITextField | 原生 TextField + formatted 数值约束 | WorkoutExperience125.swift:169/78/84 | 待处理 |  |
| IOS-004 | SmartWeightStepper 自绘磁吸步进胶囊 | 原生 Stepper/Menu + 系统材质 | DesignTokens.swift:814 | 待处理 |  |
| IOS-005 | 23 处直写 .regularMaterial/.ultraThinMaterial | 收口 clubGlassEffect（iOS 26 自动 glassEffect） | 见摸底文档 C 节 | 待处理 | 纯收口，不改视觉语义 |
| IOS-006 | ClubActivityMark/ClubWaitBar/AIWaitProgress 手绘 TimelineView | 原生 ProgressView（不确定态） | Design.swift:331/509/540 | 待处理 |  |
| IOS-007 | BreathingPulseHalo 手绘呼吸环 | 原生 Gauge(.accessoryCircularCapacity) + symbolEffect | DesignTokens.swift:746 | 待处理 |  |
| IOS-008 | LaserScanBeamOverlay 手绘激光扫描线 | 系统进度语义（ProgressView+识别文案） | DesignTokens.swift:888、MealEditorView.swift:876 | 待处理 |  |
| IOS-009 | ConfettiView 手绘彩带粒子 | symbolEffect(.celebrate)/系统庆祝 | OnboardingView.swift:1324/1293 | 待处理 |  |
| IOS-010 | 首次引导轨道环/渐变卫星手绘 | glassEffect + SF Symbols 重做 | FirstLaunchWalkthroughView.swift:223-530/794-810 | 待处理 | 等 DES 动效规范 |
| IOS-011 | 训练/AI 界面呈现时通知深链被屏蔽（sheet 返回 nil） | 训练进行中点通知可见提示或跳转 | BojiClubApp.swift:218 | 待处理 | P1 流程断点 |
| IOS-012 | 登录→会员门→引导→首启 walkthrough 四层状态机回写不及时卡门 | 状态收口+卡门可恢复提示 | BojiClubApp.swift、ClubAIShell.swift | 待处理 |  |
| IOS-013 | 组间休息 pauseService+restDeadlines 双状态 | 单源事实+跨午夜边界回归 | ClubAIShell.swift:166-172 | 待处理 |  |
| IOS-014 | 品牌视频融入技术位预留 | AVKit/VideoPlayer + 玻璃边框（位置等 DES 规范） | 待定 | 待处理 | 素材 design-assets/brand-video.mp4 |

### B2. 界面设计 · 视觉与动效规范（规范产出后贴链接）

| 编号 | 规范项（材质/层次/模糊/动效节奏/视频融合方案） | 交付物 | 状态 | 备注 |
|---|---|---|---|---|
| DES-001 | 「iOS 原生组件 + 玻璃质感」视觉与动效规范：系统分层降级（iOS 26 glassEffect / iOS 17-25 磨砂 / 增强对比度不透明）、材质三层体系（内容面/浮动玻璃/强调玻璃，含圆角、描边、阴影、密度值）、z 层次约定、动效节奏表（时长/曲线/进场/流光/华丽感红线）、组件规格速查、验收自查清单 | [0.16.0-原生玻璃与动效规范.md](0.16.0-原生玻璃与动效规范.md) | 已交付待验 | 供苹果开发落地、测试验收按 §7 自查 |
| DES-002 | 视频融入方案：素材已解析为 960×960 / 10 秒 / 2.1MB 方形视频；给出 A 首页 Hero 玻璃卡底层视频（推荐）、B 启动过场、C 训练完成页氛围底三个候选位 + 统一播放规格（静音循环、离开暂停、减少动态效果显示静态帧、渐变护字） | 同上 §5 | 已交付待拍板 | 最终选 A/B/C 由 Chief 拍板，定后我出对应页面视觉稿 |

### B3. 后端开发 · 接口/数据侧流程卡顿问题

> 摸底结论（2026-11-08，后端开发）：账号服务（PHP）与 AI 后端（Python）代码本身有较多防护，但有 8 处会在真实链路里造成卡顿/停摆，按优先级排列如下。

| 编号 | 问题（登录/同步/支付回调等） | 影响的流程 | 方案 | 状态 | 备注 |
|---|---|---|---|---|---|
| BE-001 | 会员核验在请求路径上同步调用 RevenueCat：`requireActiveMembership → revenueCatRefreshIfDue → revenueCatVerifyMembership`，一次 4 个 HTTPS 请求、deadline 12 秒；付费用户每 5 分钟后的第一个受限请求最多卡 12 秒。购买后 `/me/membership/verify` 强制刷新同样同步阻塞。 | 购买后"核验中"长时间转圈；会员功能页面（任务/AI/记录）偶发卡死 | 核验改为后台异步（参照 `/me` 的 `respondThen`），请求路径只读本地 `membership_entitlements`；客户端轮询 202 状态 | 待处理 | index.php:352、revenuecat.php:25、revenuecat-verify.php:131 |
| BE-002 | 登录强依赖服务端配置与 Apple 联网：`apple_client_ids` 缺失直接 503「Apple 登录尚未配置」；公钥缓存过期/首次登录时同步联网 `appleid.apple.com`（5 秒超时），网络差即登录失败。 | Apple 登录入口不可用或转圈 5 秒 | 部署配置核查；公钥缓存预热 + 失败时明确重试提示（区分"配置缺失"与"网络暂不可用"） | 待处理 | apple-auth.php:62、apple-key-cache.php:38 |
| BE-003 | 支付回调强依赖 `revenuecat_webhook_authorization`（≥24 字符），缺失时全部事件 401 被拒；TRANSFER 等异常事件直接 503，只能等 RevenueCat 重投，无本地对账/补单入口。 | 付款成功但权益不到账或延迟 | 配置核查；回调失败告警 + 本地对账/补单脚本 | 待处理 | revenuecat.php:7、revenuecat.php:111 |
| BE-004 | 域命令连续失败 6 次即标记 `blocked`（前台断网 12 分钟即可触发），云同步遇到 blocked 命令直接抛「有一项修改需要处理」并中止。 | 弱网/多设备后同步停摆，用户不知如何处理 | blocked 改为指数退避自动重试（最长 24h）；或在同步中自动合并版本冲突而非中止 | 待处理 | AppStore.swift:2642、AppStore.swift:765/793 |
| BE-005 | AI 完成状态核验用 1 秒 / 2 秒超时的同步 HTTP 打本地 worker（`verifiedAICompletion` / `verifiedAICompletions`），位于 insights、club-progress 请求路径。worker 繁忙时核验失败 → 已完成报告不被标记 → 页面显示「处理中」或重复生成。 | AI 报告/复盘状态不同步、重复生成 | 状态由 worker 回调/定时任务写入；或延长超时并允许降级标记 | 待处理 | ai-response.php:84/124、insights.php:60、club-progress.php:72 |
| BE-006 | 旧账号首次分片化迁移在第一个 `/me/sync` 请求里同步完成（`cloudPartEnsure`），数据量大时首同步长时间无反馈；旧数据总量 >15MB 直接返回 426 要求更新 App。 | 老用户升级后首次同步卡住/失败 | 迁移放后台 + 进度提示；426 时给明确更新引导 | 待处理 | cloud-parts.php:119、cloud-parts.php:177 |
| BE-007 | 云同步提交锁按用户文件锁，第二台设备提交返回 429 + `Retry-After: 5`；客户端虽会 5 秒后自动重试，但连续 3 次冲突会中止本次同步。 | 多设备同时使用时偶发同步失败提示 | 服务端排队合并；或延长客户端重试窗口 | 待处理 | cloud-parts.php:72、AppStore.swift:770/810 |
| BE-008 | AI worker 未配置模型 Key 时直接 `SystemExit` 退出，所有 AI 功能不可用且无明确错误暴露给客户端。 | AI 分析全部失败 | 部署核查 + 健康检查告警（`/api/v1/health` 已具备） | 待处理 | backend/server.py:1322 |

### B4. 运维支付 · 真机安装链路

| 编号 | 事项（签名/分发安装/需要的账号证书） | 状态 | 备注 |
|---|---|---|---|
| OPS-001 | 真机安装链路三选一，待用户拍板：1. TestFlight（推荐，免费 Apple ID 可建 API Key，90 天有效，首次需等苹果审核）；2. Ad-hoc 直装（最快当天上真机，需 $99 开发者账号 + iPhone UDID，7 天重签）；3. 模拟器 MobAI 分享（零账号，可快速看 UI 动效，测不了相机/健康/推送真机能力） | 等用户选择 | 现 dist 里的 `BojiClub-4938f036.ipa` 为未签名 Debug 包（无签名/描述文件，代码在 debug dylib 里），**任何真机都装不上**，选好链路前每轮构建只能模拟器验收 |
| OPS-002 | builder 已登录 GitHub，未登录 Apple；仓库无证书与描述文件 | 待处理 | 链路选定后由运维支付配置并同步构建/验证命令 |

---

## C. 验收记录表（Chief 验收时填写）

每轮验收一行：轮次 / 交付构建（Build 号 + IPA）/ 验收日期 / 结果（通过·不通过）/ 发现的问题 / 处置（重新派活给谁）。

| 轮次 | 构建 | 日期 | 结果 | 发现的问题 | 处置 |
|---|---|---|---|---|---|
| 第 1 轮 |  |  |  |  |  |

---

## D. 验收检查表（测试验收维护）

来源：界面设计《0.16.0-原生玻璃与动效规范》§7 + Chief 的 5 条验收标准 + A 表 bug 关闭情况。每轮验收逐项打勾并留证据（截图/日志/构建号）。

| 编号 | 检查项 | 判定标准 | 环境 | 状态 | 证据 |
|---|---|---|---|---|---|
| ACC-01 | 全控件系统化 | 无自绘按钮/弹窗/开关/键盘/步进；`LiquidCheckbox`、`ClubNumericKeypad`、`TrainingNumericInput125`、`SmartWeightStepper` 全部替换 | 源码 + 模拟器 | 待处理 | — |
| ACC-02 | 玻璃分层正确 | iOS 26 真机见玻璃折射；iOS 17–25 见系统磨砂；增强对比度/减少透明度为不透明+描边 | iOS 26 真机 + iOS 17 模拟器 | 待处理 | — |
| ACC-03 | 玻璃数量合规 | 每屏玻璃件 ≤ 3，普通页 ≤ 1；玻璃下必有可辨识内容层 | 截图 | 待处理 | — |
| ACC-04 | 视频融入（标准④） | 静音循环、离开页面暂停并归零、减少动态效果/低电量为静态首帧、文字有渐变护字、单播放器复用 | 真机/模拟器 | 待处理 | 待定视频位 A/B/C |
| ACC-05 | 动效合规 | 减少动态效果下无位移无循环；动效 ≤ 0.5s（流光除外且低频非循环）；同屏运动元素 ≤ 2 | 真机/模拟器 | 待处理 | — |
| ACC-06 | 触控与深浅色 | 触控区 ≥ 44pt；深浅色两套均通过 | 真机/模拟器 | 待处理 | — |
| ACC-07 | 主线流程顺（标准②） | 登录 → 首页 → 训练 → 记录 → 同步/支付 无卡壳；BUG-001~004 关闭 | 真机 | 待处理 | — |
| ACC-08 | 性能不回退 | 滚动 CPU 不高于基线（BUG-007：+47.2% 需归因并优化） | 同机同配置对比 | 待处理 | — |
| ACC-09 | 无障碍 | 侧栏自动审计全部通过（BUG-006 的 3 对比度 + 2 裁切） | 真机/模拟器 | 待处理 | — |
| ACC-10 | A 表 bug 清零 | BUG-001~009 全部「已验收关闭」或经 Chief 同意延后 | — | 待处理 | — |

### 测试环境限制（测试验收备注）

1. 本机 Windows 无 Xcode，无法跑 XCTest／XCUITest 与 iOS 17 模拟器；ACC-02 的「iOS 17–25 磨砂」一项当前**没有可执行环境**，需运维支付确认能否提供 iOS 17 模拟器或真机，否则只能做源码级降级分支核对。
2. ACC-02/04/05/06/07/09 都需要真机或模拟器实际画面，依赖运维支付的真机安装链路（B4）。
3. 当前 `dist/BojiClub-4938f036.ipa` 为未签名 Debug 包，不可装真机，不能作为验收构建。

---

## 进度速览（文档管理维护）

| 事项 | 负责人 | 状态 |
|---|---|---|
| Bug 全量排查清单（首轮 BUG-001~009） | 测试验收 | 已完成首轮，待真机复核 |
| 自绘控件与流程不通点清单 | 苹果开发 | 进行中 |
| 接口/数据侧问题清单 | 后端开发 | 已完成摸底，8 项入 B3 表 |
| 视觉与动效规范（含视频融合方案） | 界面设计 | 已交付（DES-001/002），待 Chief 验收；视频方案 A/B/C 待拍板 |
| 真机安装链路 | 运维支付 | 链路三选一待用户拍板（见 B4 OPS-001）；链路定前真机验收无法进行 |
| 本文档 | 文档管理 | 已建档，待各表填充 |

## 变更记录

- 2026-11-08：建档（BUILD140），基线 Build 139 / 0.15.9，验收标准与四张台账表就位。
- 2026-11-08：测试验收填入 A 表首轮 BUG-001~009（源码级静态核对，待模拟器/真机复核）；转记苹果开发 5 条流程不通点，其中 BUG-001 通知深链已核对源码确认。
- 2026-11-08：界面设计交付《0.16.0-原生玻璃与动效规范》（DES-001/002）；测试验收据其 §7 建立 D 表验收检查表 ACC-01~10，并记录 3 条测试环境限制。
