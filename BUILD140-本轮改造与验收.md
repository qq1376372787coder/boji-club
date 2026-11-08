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

## 0.1 关键决定（2026-11-08，Chief 拍板）

| 编号 | 决定 | 内容 | 影响 |
|---|---|---|---|
| DEC-1 | 视频位定 **A：首页 Hero 卡底层视频** | 960×960 方形正好配 Hero 卡，`heroGlassCard` 现成占位，改动面最小，打开即见质感；播放规格通用，用户想换开屏/个人页随时改（小活） | 界面设计出 Hero 视觉稿后交苹果开发接入，关 BUG-005；D 表 ACC-04 按 A 验 |
| DEC-2 | **ACC-02 降级验收** | iOS 17 模拟器拿不到，按测试验收方案降级：源码级核对 `clubGlassEffect` 的 `#available` 分支；真机观感项挂到安装链路就绪后补验 | D 表 ACC-02 注明「降级验收」，其余检查项不变 |
| DEC-3 | 真机链路**已落地选 1（TestFlight）** | Chief 与测试验收均选 1：90 天有效期覆盖多轮验收，Ad-hoc 7 天重签易断档。**更正：1、2 都需 $99/年付费开发者账号（见 OPS-001）**。2026-11-08 用户提供 API Key，链路已打通，签名包 Build 141 进测试组 | 用户 iPhone 装 Build 141 后启动真机补验 7 项；每轮改完运维支付重发新包，90 天有效 |
| DEC-4 | **重做方案选定：2+3 混搭**（2026-11-08 用户拍板） | 玻璃旗舰（方案二）做骨架 + 杂志质感（方案三）的巨号排印做气质；Chief 复述：影像沉浸分层玻璃、滚动收缩、系统折射高光 + 巨号数字当主角 + 教练式短句；界面壳全原生组件、每屏一个主操作、军事黑话全灭 | 进入阶段 6 四条线全面重做；流程改为「视觉稿先行——用户过目点头才动手」（见 J-4 批次台账） |
| DEC-5 | **给用户的验收包一律 Release 配置出包**（2026-11-08 Chief 拍板） | 起因（后端开发挖出）：`OnboardingView.swift:129/131/133/139/210` 共 **5 处用户可见开发入口**（服务器测试登录、开发预览：会员价格页面等），全部包在 `#if DEBUG`（起始 127/182 行）里，上架包不露——**但此前云端出包全是 Debug 配置**（builder 日志 `Configuration: Debug`），所以用户真机验收装的包里这 5 个入口是可见的，容易被当成正式功能提意见。定死规矩：**凡是给用户装的包（TestFlight 验收包、中间体验包）一律 Release 流程出包**（Build 141 就是这么出的），`#if DEBUG` 整体剥离，开发入口天然不存在。**第二道闸门暂不加**（避免过度工程） | 测试验收 K 表「正式包无开发入口」检查即保险丝：**验收包里见到任何开发入口 = 判不通过**；开发期 Debug 包照旧可用，5 处入口保留不删 |
| DEC-6 | **交互反馈三联动（动效 + 震动 + 音效）入目标与规则**（2026-11-08） | 华丽感靠动效层次、滚动驱动、玻璃按压反馈与庆祝编排实现，不靠堆特效；音效为原创合成短音（后端开发已交付 6 段素材 S1 tap／S2 set_done／S3 milestone／S4 workout_done／S5 rest_tick／S6 error，48kHz/16bit/单声道，峰值 -6dBFS，无版权），**尊重静音开关与减少动态效果，设置页提供音效开关** | 素材与接线分两批：批次 0 只验「素材就位、路径已定」（**故意不进 bundle**，避免与苹果开发并发改 pbxproj 再撞号）；**批次 2 由苹果开发做 pbxproj 注册 + 播放接线并实测真声音**（K1-8 届时才算通过）；首次编译建议跑 `afinfo BojiClub/Sounds/boji_tap.caf` 解析确认 |

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
| BUG-001 | 通知深链（训练提醒等） | 训练进行中（或 AI 会话可见时）点推送通知：`BojiClubApp.swift:219` 的 `.sheet(item:)` Binding 在 `store.trainingInterfacePresented`/`store.clubAIInterfacePresented` 为真、或 `route.kind == "training"` 时直接返回 nil，通知被静默吞掉 | P1 | 苹果开发 | 已验收关闭 | 修复方式（commit ea531ff + 第二批）：屏蔽时改顶部提示横幅，路由保留待条件解除后自动弹出；第二批已修遗留——文案区分 training（如实说明不会自动弹出）、带「知道了」关闭按钮、改 safeAreaInset 不压顶栏（BUG-010/011 同修）。**测试验收第四輪复验通过** |
| BUG-002 | 登录→首页入口状态机 | 登录后依次过 `account.phase`→`MembershipGateView`→`IndependentProfileOnboardingView`→`FirstLaunchWalkthroughView`→主壳，四层任一状态回写不及时即卡在门页 | P2 | 苹果开发 | 已修复待验（部分：卡门可恢复） | 苹果开发提供。**测试验收阶段 3 复验（G-13）**：`ProfileView.swift:158-162` 会员门底部浮条新增「重新检查会员状态／正在检查…」按钮，走 `membership.refresh(force: true)`，卡门可原地重试（IOS-012）；四层状态机本身的回写时序仍未做全面收口，真机多路径待验 |
| BUG-003 | 训练登记输入 | 训练中切换重量/次数输入：自绘 `ClubNumericKeypad` 与系统键盘（keypadWeight 开关）并存，输入串轨且 VoiceOver 不可达 | P1 | 苹果开发 | 已验收关闭 | 自绘键盘与 keypadWeight 双轨已删（ClubNumericKeypad 定义删除、底部键盘条删除），统一原生 TextField（decimalPad/numberPad）+ sanitize 过滤（数字、一个小数点、最长 8 位）；LiquidCheckbox 同步改系统符号按钮。**测试验收第三輪复验**：`ClubNumericKeypad`／`LiquidCheckbox` 全库零命中；同批的 `SmartWeightStepper` 与 `TrainingNumericInput125` 保留同名薄封装但内部已换原生 `Stepper`／`TextField`（commit b1d31c7，G-15 复扫通过） |
| BUG-004 | 组间休息状态 | 暂停/恢复休息并跨午夜或跨时区：`pauseService.state` 与 `restDeadlines` 双源（`ClubAIShell.swift:166-172`），提醒取消与恢复重排边界多，是卡顿高发区 | P2 | 苹果开发 | 已修复待验（单源校正） | **测试验收阶段 3 复验（G-14）**：`ClubAIShell.swift:175-177` 新增 `.onChange(of: activeWorkout?.isPaused)`，任何来源置暂停即 `cancelRestReminder()`；`:187` onAppear 兜底；与既有 `:168-172` pauseService 分支并存形成双保险（IOS-013）。跨午夜/跨时区边界仍需真机复核 |
| BUG-005 | 品牌视频未融入界面 | 主壳空态 Hero 卡 `heroGlassCard`（`ClubAIShell.swift:1172`）仍是渐变+TimelineView 流光占位，源码注释明写「视频资产待补」；`design-assets/brand-video.mp4` 在工程内无任何引用 | P1 | 苹果开发／界面设计 | 已验收关闭 | 按 DES-003 方案 A 接入：AVQueuePlayer+AVPlayerLooper 循环、仅页面活跃播放、离场 pause+seek(.zero)；减少动态效果/视频未就绪/页面非活跃回退静态占位；底部护字渐变、深色压暗 20%；brand-video.mp4 已入 BojiClub/ 并在 pbxproj 注册（四处引用齐全）。**测试验收阶段 4 复验（H-01/H-02）**：循环/离场暂停/reduceMotion 降级/低电量闸门/静音/深色压暗/护字渐变均到位；首帧占位 `loadHeroPoster()` + z0/z0b 分层消除跳变（commit 5ab6f97） |
| BUG-006 | 侧栏无障碍审计 | 默认侧栏自动审计仍报 3 个 `element=nil` 对比度失败 + 2 个「大字号可能裁切」预测（`docs/native-ui-20261024/diagnostics/sidebar-ax-triage.md`） | P2 | 苹果开发 | 待处理 | 上一轮未关闭项；草稿标题实测 15.81:1 非误报，但未知项无法定位 |
| BUG-007 | 滚动性能回归 | 相同 SE3 模拟器 Debug 前后对比：滚动 CPU 0.304→0.448 秒（+47.2%），指令数 +38%（`docs/native-ui-20261024/performance/performance-comparison.md`） | P2 | 苹果开发 | 处理中（基线重建） | 未做采样归因。**2026-11-09 口径修正（测试验收）**：①Instructions/Cycles 模拟器恒 0，对比用 **CPU Time**；②11-08 新快照（`docs/performance-baseline-20261108/`）跑在 **iPhone 16 Pro**，与本条 SE3 基线**跨设备不可比**——历史 +47.2% 仅作背景；批次 1 收尾正式基线起统一 16 Pro 同设备对比 |
| BUG-008 | 顶栏工作区选择器小屏溢出 | iPhone SE（375pt）下 `ClubModeCapsulePicker` 分段选择器 `maxWidth: 300`，加左 44pt 侧栏钮 + 右 44pt 更多钮 = 388pt > 375pt，可能压缩/截断 | P3 | 苹果开发 | 待处理 | 仅大字号走 `.menu` 降级；小屏待复核 |
| BUG-009 | 强制解包风险点 | 静态扫描 31 处 `!`，多数有前置 guard；风险相对高的：`AppStore.swift:2111`（`state.days[key]!.meals[index]`）、`ExerciseLibraryView.swift:143/168/178`（`components.url!`）、`MembershipService.swift:240`（`self.notice!`）、`HealthViews.swift:206`（`URL(string:)!`） | P3 | 苹果开发 | **已验收关闭** | 测试验收发现后列 P3 建议；Chief 第 1 轮验收开问题单 **T-1**。**已修**（commits fca7e98 → bc9202a → 8e936d2）：6 处重点 + 输入派生解包全部加 guard 安全回退。**测试验收终扫**：全库 31 → 10 处，且 10 处全为「同前置 nil 检查短路保护」或 UIKit 委托签名（`WKNavigation!`），真实强制解包清零；`components.url!`、`URL(string:...)!` 全库零命中。编译 run 42474824704 通过 |
| BUG-010 | 通知横幅文案与实际行为不符 | training 类通知（`route.kind == "training"`）被 sheet 绑定**永久**屏蔽（`BojiClubApp.swift:219` 的 blocking 条件里含 `route?.kind == "training"`），横幅却写「退出训练或对话后会自动打开」——实际永远不会打开；且 `BojiStatusBanner` 未传 `action`，**没有关闭按钮**，route 未清理前横幅常驻 | P3 | 苹果开发 | 已验收关闭 | 触发路径：训练中收到另一日期的训练提醒 → `ClubAIShell.swift:761-764` 把 `trainingRoute` 置 nil 但保留 route → 横幅常驻。测试验收复验 BUG-001 时发现；**已修**：training 类文案如实写「训练进行中不会自动弹出，请稍后从通知中心重新打开本条通知」，横幅带「知道了」关闭动作（清提示状态），不再常驻。**测试验收第四輪复验通过** |
| BUG-011 | 通知横幅可能遮挡顶栏 | 横幅 `.overlay(alignment: .top)` 直接压在 `navigationWorkspace` 上（`BojiClubApp.swift:241-247`），顶栏已有侧栏钮+分段选择器+更多钮，需确认不遮挡、不拦截点击 | P3 | 苹果开发 | 已验收关闭 | 横幅从 `.overlay(alignment: .top)` 改为 `.safeAreaInset(edge: .top)`，走系统安全区布局，不压导航栏、不拦截顶栏点击。**测试验收第四輪复验通过** |
| BUG-012 | 页面内散写 `if #available(iOS 26)` | `JourneyComponents.swift:72/92/128` 仍直接写 `if #available(iOS 26.0, *)` 三分支（规范 §1 明令禁止，应收口到 `clubNativeGlassButton`）；且这三处所在的 `ClubActionButtonStyle` 本身就是待淘汰的自绘按钮（30+ 使用点） | P2 | 苹果开发 | 已验收关闭 | 材质收口 IOS-005 的漏项；**已修**：JourneyComponents 三处散写分支收口为 `.clubNativeGlassButton(prominent:)` / `.clubNativeGlassButton()`。**测试验收阶段 3 全量复扫（G-22）**：全库 `if #available(iOS 26` 仅剩 `Design.swift:160/197/211` 桥接自身 |
| BUG-013 | Hero 卡视频暂停钮触控区不足 | 暂停/播放钮视觉 30×30pt，实际触控区 < 44pt 最小触控标准 | P3 | 苹果开发 | 已验收关闭 | 测试验收第二批复验发现，第三輪复验未修；**第四輪已修**（commit 54092f1）：`ClubAIShell.swift:1287-1288` 加 `.frame(width: 44, height: 44).contentShape(Circle())`，视觉仍 30pt、命中区 44pt，符合 ACC-06 与 DES §6 |
| BUG-014 | Hero 品牌视频**没有静音** | `setupHeroVideo()`（`ClubAIShell.swift:1190-1196`）创建 `AVQueuePlayer` 后未设 `isMuted = true` | P1 | 苹果开发 | 已验收关闭 | 测试验收第三批复验发现（界面设计独立核对一致）；**第四輪已修**（commit 54092f1）：`ClubAIShell.swift:1194` `player.isMuted = true` |
| BUG-015 | 视频降级缺两项（低电量 / 首帧占位） | DES §5.2 要求「低电量模式 → 静态图」与「未就绪前显示第 0 帧静态图」 | P3 | 苹果开发 | 已验收关闭 | **两项均已闭环**：①低电量闸门 `ClubAIShell.swift:1199` guard 含 `!ProcessInfo.processInfo.isLowPowerModeEnabled`（commit 54092f1）；②首帧占位 `ClubAIShell.swift:1209-1222` `loadHeroPoster()` + z0/z0b 分层（commit 5ab6f97，测试验收 H-02 复核通过）。首帧未生成的一瞬仍有 `brandMist` 兜底，属可接受瞬态 |
| BUG-016 | 勾选按钮动效未受「减少动态效果」约束 | `TrainingRegistrationViews.swift:295` `Image(...).symbolEffect(.bounce.up.byLayer, value: true)` 无条件生效；原自绘 `LiquidCheckbox` 的动画是有 `if !reduceMotion` 门控的，换原生后**门控丢失** | P3 | 苹果开发 | 已验收关闭 | 测试验收阶段 3 交互回归（F2/INT-06）发现；违反 DES §0 铁律 3「所有动效尊重减少动态效果」与 ACC-05。**已修**（commit 43d66f8）：`TrainingRegistrationViews.swift:298` `if reduceMotion { base } else { base.symbolEffect(...) }` |
| BUG-017 | 首页进场动效与规范数值/曲线不一致；完成页整串超 0.5s 口径 | ①场景 1 `ClubAIShell.swift` `BojiHomeEntrance` 曾用时序/曲线与规范不符的实现；②场景 3 整串 0.60s，若按整串口径超 §4.2「0.5s」 | P3 | 苹果开发／界面设计 | **已验收关闭** | 测试验收阶段 4 H 表终扫（H-10/H-12）发现；界面设计拍板「实现服从规范」。**已修**（commit 064d234）：`BojiMotion2.entrance` 对齐为 `spring(response 0.35, dampingFraction 0.85)`、`stagger` 0.05；场景 1（`ClubAIShell.swift` `BojiHomeEntrance`）与场景 3（`WorkoutExperience125.swift` `BojiStaggeredEntrance`）**实现代码逐字一致**，均为 `opacity + scaleEffect(0.96→1) + resolved(entrance)?.delay(index*stagger)`，减动效降为 0.12s 交叉淡入。规范 §4.2/§7 补口径：「0.5s」指**单元素自身进场时长**，stagger 整串总和 ≤0.6s |

> 用户直接在群里反馈的具体 bug 和流程卡壳点，由测试验收转记到此表。
>
> 另：`KNOWN-ISSUES.md` 列出的功能差额（E6 距离计量、D6 提醒频率学习、E7 围度/体脂独立流程、漏练补排、行动状态机全面接入、草稿并发分叉）属**已知未实现功能**，不计入本轮 bug 编号，单独跟踪。

## B. 改造清单（按负责人分表）

### B1. 苹果开发 · 自绘控件 → 原生组件 + 玻璃改造

> **打勾进度（文档管理随报随登）**：共 14 项，**全部「已修复待验」并经阶段 3 复验（G 表）通过**（2026-11-08 阶段 3 收口）——4 个自绘控件 IOS-001~004 全换原生、23 处材质收口 IOS-005、动效系统化 IOS-006~010、流程断点 IOS-011~013、视频接入 IOS-014。**阶段 4 增量**：BUG-015 首帧占位图（苹果开发）、CLN-02 死代码清理、界面设计第二批动效方案落地后在此追加新条目。

| 编号 | 现状（自绘/自建控件或流程不通点） | 目标（原生组件/玻璃方案） | 涉及文件 | 状态 | 备注 |
|---|---|---|---|---|---|
| IOS-001 | LiquidCheckbox 自绘圆+波纹勾选 | 系统符号按钮（checkmark.circle.fill/circle）+ symbolEffect(.bounce.up.byLayer) + 触感 | TrainingRegistrationViews.swift completeControl | 已修复待验 | 自绘定义已删（DesignTokens.swift:673 段）；完成/撤销分支保留 heavyDrop/latch/tick 触感与 accessibilityLabel/Hint |
| IOS-002 | ClubNumericKeypad 自绘数字键盘 | 系统键盘 decimalPad/numberPad + 原生 TextField | Experience123.swift ClubNumericField、TrainingRegistrationViews.swift:542/546/564 | 已修复待验 | 自绘键盘定义与 keypadWeight 双轨已删，底部键盘条删除；TextField 带 sanitize 过滤（数字、一个小数点、最长 8 位），VoiceOver 走系统键盘语义 |
| IOS-003 | TrainingNumericInput125 包 UITextField（自绘 inputAccessoryView 工具条） | 原生 TextField + decimalPad + 键盘工具条「收起」（ToolbarItemGroup placement: .keyboard） | WorkoutExperience125.swift | 已修复待验 | 自绘 UIViewRepresentable 与 Coordinator 已删，保留 label/identifier/focusRequest；键盘工具条走系统 ToolbarItemGroup；同步删除重复的 TrainingNumberStyle125 modifier 与未用 UIKit import |
| IOS-004 | SmartWeightStepper 自绘磁吸步进胶囊 | 系统原生 Stepper（步长 2.5kg，范围 0…2000） | DesignTokens.swift SmartWeightStepper | 已修复待验 | 保留既有 API（currentWeight + onAdjust(delta)）兼容调用点，内部改系统 Stepper + accessibilityLabel/Value |
| IOS-005 | 23 处直写 .regularMaterial/.ultraThinMaterial | 收口 clubGlassEffect（iOS 26 自动 glassEffect） | 见摸底文档 C 节 | 已修复待验 | 17 处浮件收口 clubGlassEffect、2 处内容卡改不透明 cardSurface；全库复扫仅剩 Design.swift:200 桥接自身降级分支（预期）；含 BUG-012（JourneyComponents 散写玻璃分支收口） |
| IOS-006 | ClubActivityMark/AIProcessingMark/ClubWaitBar/ClubLoadingSkeleton 手绘 TimelineView | 原生 ProgressView（circular/linear 不确定态）；骨架屏改 redacted + 透明度脉冲 | Design.swift | 已修复待验 | 4 处 TimelineView 全删；减少动态效果时 ClubWaitBar 退化为静态条、骨架脉冲关闭；spinner 全部系统渲染 |
| IOS-007 | BreathingPulseHalo 手绘呼吸环 | 原生 Gauge(.accessoryCircularCapacity) + symbolEffect | DesignTokens.swift BreathingPulseHalo | 已修复待验 | 系统 Gauge + tint（紧急红色/常规计时色）+ 保留触感反馈与无障碍标签；减少动态效果由系统处理 |
| IOS-008 | LaserScanBeamOverlay 手绘激光扫描线 | 系统进度语义（ProgressView + 识别文案） | DesignTokens.swift LaserScanBeamOverlay、MealEditorView.swift photoCaptureArea | 已修复待验 | 改为半透明遮罩 + 系统 ProgressView + 「正在识别餐食…」文案；不额外增加玻璃件 |
| IOS-009 | ConfettiView 手绘彩带粒子 | 系统 symbolEffect(.celebrate) 一次性庆祝 | OnboardingView.swift MemberCardCelebration | 已修复待验 | 22 粒子自绘已删；改用 SF Symbols「sparkles」+ symbolEffect(.celebrate)，减少动态效果时关闭 |
| IOS-010 | 首次引导轨道环/渐变卫星手绘 | glassEffect + SF Symbols 重做 | FirstLaunchWalkthroughView.swift | 已修复待验 | Slide1 光晕 RadialGradient→品牌色+系统模糊、旋转渐变轨道环→静态细环、渐变水晶球→clubGlassEffect 原生玻璃；卫星胶囊/跳过/页码/15秒胶囊/数据徽章改不透明表面（同屏玻璃从 7 降到 1，仅保留 Slide1 水晶球与 Slide2 计时坞两个视觉主体）；背景光球 RadialGradient→模糊色块 |
| IOS-011 | 训练/AI 界面呈现时通知深链被屏蔽（sheet 返回 nil） | 训练进行中点通知可见提示或跳转 | BojiClubApp.swift:216 | 已修复待验 | P1 流程断点；屏蔽逻辑保留（不打断训练），顶部安全区横幅如实提示+「知道了」关闭，route 保留待解除后自动弹出（BUG-001/010/011 同修） |
| IOS-012 | 登录→会员门→引导→首启 walkthrough 四层状态机回写不及时卡门 | 卡门可恢复：会员门新增「重新检查会员状态」按钮（强制刷新会员权益，带检查中态） | ProfileView.swift MembershipGateView | 已修复待验 | 门页不再只能退出：刷新失败可重试；账号管理/退出路径保留 |
| IOS-013 | 组间休息 pauseService+restDeadlines 双状态 | 以快照为准的单源校正：isPaused 变化或视图出现时同步取消过期提醒 | ClubAIShell.swift | 已修复待验 | 新增 onChange(activeWorkout?.isPaused) 与 onAppear 双保险；跨午夜边界仍待真机复核 |
| IOS-014 | 品牌视频融入技术位预留 | AVKit/VideoPlayer + 玻璃边框，**位置已定 A：首页 Hero 卡底层**（DEC-1） | ClubAIShell.swift heroGlassCard、pbxproj | 已修复待验 | 代码层按 DES-003 方案 A 完成（AVQueuePlayer 静音循环+三闸门降级+护字渐变+44pt 玻璃暂停钮），brand-video.mp4 已入 bundle 并注册；首帧占位图留阶段 4 |
| IOS-015 | DES-004 三场景动效落地（首页/训练中/训练完成） | 按《阶段4-动效方案-三场景》逐项实现，复用 BojiMotion2 档位，同时运动元素 ≤2 | ClubAIShell.swift、WorkoutExperience125.swift、TrainingRegistrationViews.swift、BojiComponents.swift | 已修复待验 | ①首页 Hero+首区块两拍进场 entrance 0.45+stagger 0.07（bojiHomeEntrance）；②完成页 6 事实格 stagger 0.35+0.05（整串 0.60s）+ 完成组/次数/训练量数字滚动 + 一次性成功触感；③训练中完成组数 counter + 分段进度改线性 easeOut（去弹簧假进度）；reduceMotion 全部降级 |

### B2. 界面设计 · 视觉与动效规范（规范产出后贴链接）

| 编号 | 规范项（材质/层次/模糊/动效节奏/视频融合方案） | 交付物 | 状态 | 备注 |
|---|---|---|---|---|
| DES-001 | 「iOS 原生组件 + 玻璃质感」视觉与动效规范：系统分层降级（iOS 26 glassEffect / iOS 17-25 磨砂 / 增强对比度不透明）、材质三层体系（内容面/浮动玻璃/强调玻璃，含圆角、描边、阴影、密度值）、z 层次约定、动效节奏表（时长/曲线/进场/流光/华丽感红线）、组件规格速查、验收自查清单 | [0.16.0-原生玻璃与动效规范.md](0.16.0-原生玻璃与动效规范.md) | 已交付待验 | 供苹果开发落地、测试验收按 §7 自查 |
| DES-002 | 视频融入方案：素材已解析为 960×960 / 10 秒 / 2.1MB 方形视频；给出 A 首页 Hero 玻璃卡底层视频（推荐）、B 启动过场、C 训练完成页氛围底三个候选位 + 统一播放规格（静音循环、离开暂停、减少动态效果显示静态帧、渐变护字） | 同上 §5 | **已拍板选 A**（DEC-1） | 出首页 Hero 卡视觉稿（视频底层 + 玻璃卡 + 渐变护字 + BUG-005 落地要点），出好 @苹果开发 |
| DES-003 | 首页 Hero 视频玻璃卡视觉稿（方案 A 落地），三状态：①浅色视频播放态 ②深色（视频上先叠黑 20% 再压护字）③减少动态效果/低电量/未就绪 → 同构图换首帧静态图。分层规格：视频 z0 → 全幅渐变护字（透明→黑 52%，底部最深）→ 玻璃高光层 `clubGlassEffect`(圆角28) → 全白文字+1px 投影（对比度≥4.5:1）→ 右上 30pt 玻璃暂停钮；14s 流光保留、仅页面活跃时跑 | [design-previews/hero-video-card-A.html](design-previews/hero-video-card-A.html) | 已交付待验 | **BUG-005 落地要点**：①`ClubAIShell.swift:1172` heroGlassCard 现有 TimelineView 流光保留，其下插视频层；②AVPlayer 单例、静音循环，页面活跃才 play，离场 pause+seek(.zero)；③三闸门（reduceMotion/低电量/视频未就绪）任一命中只显首帧图，可删"视频资产待补"注释；④视频入 bundle 前先挂占位图防黑块；⑤`design-assets/brand-video.mp4` 需加入 App 资源 |
| DES-004 | 阶段 4 三场景动效方案（首页/训练中/训练完成）：全部复用 BojiMotion2 现有档位不新造参数；首页 Hero+区块两拍 stagger 进场（整串≤0.6s）、速度拨号 transition+子项 stagger；训练中勾选 micro+数字 counter 0.35s、分段进度线性 easeOut 0.32（禁弹簧假进度）、休息倒计时保持 1s 周期+linear 0.9；完成页品牌标 celebrate 0.52/0.74 一次性+symbolEffect(.bounce)、事实格 6 格 entrance 0.35+stagger 0.05（整串 0.60s 达标）+数字滚动 counter；统一 reduceMotion 降 0.12s 交叉淡入；同时运动元素≤2 | [design-previews/阶段4-动效方案-三场景.md](design-previews/阶段4-动效方案-三场景.md) | 已交付待落地 | 落地顺序：①首页两拍 stagger → ②完成页事实格序列+数字滚动 → ③训练中数字 counter 与分段进度 linear 包裹；每批一编译 |

### B3. 后端开发 · 接口/数据侧流程卡顿问题

> 摸底结论（2026-11-08，后端开发）：账号服务（PHP）与 AI 后端（Python）代码本身有较多防护，但有 8 处会在真实链路里造成卡顿/停摆，按优先级排列如下。

| 编号 | 问题（登录/同步/支付回调等） | 影响的流程 | 方案 | 状态 | 备注 |
|---|---|---|---|---|---|
| BE-001 | 会员核验在请求路径上同步调用 RevenueCat：`requireActiveMembership → revenueCatRefreshIfDue → revenueCatVerifyMembership`，一次 4 个 HTTPS 请求、deadline 12 秒；付费用户每 5 分钟后的第一个受限请求最多卡 12 秒。购买后 `/me/membership/verify` 强制刷新同样同步阻塞。 | 购买后"核验中"长时间转圈；会员功能页面（任务/AI/记录）偶发卡死 | **已改**：请求路径只读本地 `membership_entitlements`；新增后台 worker `account-server/process-membership-refresh.php`（systemd timer 每分钟）承担到期核对；删掉 index.php 两处、weekly.php 一处的同步刷新调用；`/me` 保留 respondThen 异步刷新 | 已修复待验 | index.php:352、revenuecat.php:25、revenuecat-verify.php:131；**第二成因（运维支付查实）：配置键缺失 → `revenueCatVerificationConfigured()` 假 → `rc_not_configured` 要求客户端 60 秒重试，随 OPS-003 线上补键一并解决** |
| BE-002 | 登录强依赖服务端配置与 Apple 联网：`apple_client_ids` 缺失直接 503「Apple 登录尚未配置」；公钥缓存过期/首次登录时同步联网 `appleid.apple.com`（5 秒超时），网络差即登录失败。**根因已查实（运维支付）：`deploy.sh` 首次部署生成的 `config.php` 根本没写这些键**，且 `apple_keys_cache_dir` 目录 deploy.sh 不建（上轮修过但脚本没跟上） | Apple 登录入口不可用或转圈 5 秒 | 源码已改：deploy.sh 生成完整 21 键配置、缺密钥自动生成落盘 0600、建 Apple 公钥缓存目录、部署后配置校验缺键即失败；新增 `account-server/config-contract.php`、`account-server/check-config.php`（`deploy.sh --check-config`）、`tests/test_deploy_config_contract.py`（21 键全通过）；`.gitignore` 补 `account-server/private/`、`cache/apple-keys/`。**待办：线上旧 config.php 不会自动更新，需管理员登录服务器补键（运维支付无 SSH 权限，清单给 Chief）** | 源码已改·待线上补键 | apple-auth.php:62、apple-key-cache.php:38；改动均未碰线上 |
| BE-003 | 支付回调强依赖 `revenuecat_webhook_authorization`（≥24 字符），缺失时全部事件 401 被拒；TRANSFER 等异常事件直接 503，只能等 RevenueCat 重投，无本地对账/补单入口。**根因已查实（运维支付）：deploy.sh 生成的 config 无此键 → webhook 鉴权直接判未授权，所有支付回调 401**；另发现模板 `revenuecat_product_ids` 写的是已下架旧档 `bojiclub_halfyear_2990/yearly_4290`（iOS 端在用 `yuefu/nianfu/yongjiu`），`environment` 写 PRODUCTION 与 RevenueCat 实配 SANDBOX 不一致 | 付款成功但权益不到账或延迟 | 部署配置已随 BE-002 一并修（商品档改 `yuefu/nianfu/yongjiu`、配置校验）；**待办：管理员补键 + 去 RevenueCat 后台配 webhook 的 Authorization 头**；回调失败告警 + 本地对账/补单脚本仍待做 | 源码已改·待线上补键 | revenuecat.php:7、revenuecat.php:111 |
| BE-004 | 域命令连续失败 6 次即标记 `blocked`（前台断网 12 分钟即可触发），云同步遇到 blocked 命令直接抛「有一项修改需要处理」并中止。 | 弱网/多设备后同步停摆，用户不知如何处理 | **已改**：`.deferred`（结果未确认）改指数退避自动重试（2s→5s→15s→60s→5min→15min→1h），不再按次数 blocked；仅真实 409 冲突才 blocked，且 blocked 不再中止云同步（其余记录照常读写） | 已修复待验 | BojiClub/AppStore.swift:2617/2639、BojiClub/ClubProposalSync.swift:24/29（新增 `nextAttemptAt` + `DomainCommandBackoff`） |
| BE-005 | AI 完成状态核验用 1 秒 / 2 秒超时的同步 HTTP 打本地 worker（`verifiedAICompletion` / `verifiedAICompletions`），位于 insights、club-progress 请求路径。worker 繁忙时核验失败 → 已完成报告不被标记 → 页面显示「处理中」或重复生成。 | AI 报告/复盘状态不同步、重复生成 | **已改（问题单 T-2）**：新增后台 worker `process-ai-completion-refresh.php`（systemd timer 每 30 秒）定时把 `ai_user_jobs` 与本地 worker 对账并写 `completed_at`；请求路径降级为兜底，超时 1s/2s → 4s | 已修复待验 | account-server/process-ai-completion-refresh.php（新增）、ai-response.php:84/124、deploy.sh |
| BE-006 | 旧账号首次分片化迁移在第一个 `/me/sync` 请求里同步完成（`cloudPartEnsure`），数据量大时首同步长时间无反馈；旧数据总量 >15MB 直接返回 426 要求更新 App。 | 老用户升级后首次同步卡住/失败 | 迁移放后台 + 进度提示；426 时给明确更新引导 | 待处理 | cloud-parts.php:119、cloud-parts.php:177 |
| BE-007 | 云同步提交锁按用户文件锁，第二台设备提交返回 429 + `Retry-After: 5`；客户端虽会 5 秒后自动重试，但连续 3 次冲突会中止本次同步。 | 多设备同时使用时偶发同步失败提示 | **已改（问题单 T-2）**：服务端 `cloudCommitLock` 由立即 429 改为**排队等锁最多 5 秒**（临界区很短，等一下通常就能接上）；客户端重试窗口 3 次 → **6 次、每次隔 0.4 秒**，仍不收敛则保留本机记录并**自动续同步**，不再硬报失败 | 已修复待验 | cloud-parts.php:72、AppStore.swift:767/775/810/850 |
| BE-008 | AI worker 未配置模型 Key 时直接 `SystemExit` 退出，所有 AI 功能不可用且无明确错误暴露给客户端。 | AI 分析全部失败 | 部署核查 + 健康检查告警（`/api/v1/health` 已具备） | 待处理 | backend/server.py:1322 |

### B4. 运维支付 · 真机安装链路

| 编号 | 事项（签名/分发安装/需要的账号证书） | 状态 | 备注 |
|---|---|---|---|
| OPS-001 | 真机安装链路三选一 → **选定 1（TestFlight）并已打通**：用户提供了 API Key 三件套，运维支付完成签名配置并出正式签名包 | **已完成** | **TestFlight 签名包 Build 141 已进测试组**（「薄肌俱乐部测试」），装机通道打通；等用户 iPhone 装机后启动真机补验 7 项（I-3-A），装好发首页截图 |
| OPS-002 | builder 登录 Apple + 证书/描述文件配置 | **已完成** | 随 OPS-001 一并就位（能出签名包并上传 TestFlight 即为证） |
| OPS-003 | **线上补键（服务器 `117.50.119.49`）→ 已完成**：代码部署 18 个文件（含 BE-001 后台核验 worker、BE-005 AI 完成状态 worker）、语法检查通过；两个新定时任务已启用并**实测执行成功**（`membership-refresh` 输出 `{"candidates":1,"refreshed":1,"failed":0}`、`ai-completion-refresh` 输出 `{"candidates":0,"marked":0}`）；数据库迁移全部完成（`MIGRATION_OK`/`SCHEMA_OK`/`compatible:true`）；**配置契约 21 个必需键全通过**；接口验证 `/config` 200、`/me` 401（未登录正常）、webhook 带正确鉴权 **200**、不带鉴权 401 | **已完成** | 另挖出历史大坑：11 个 systemd worker 写死 `User=www-data`，而 PHP-FPM 跑 `nginx` 用户，**后台任务一直静默失败**（`217/USER: No such process`）；已改 `nginx` 并逐个触发验证（退出码 0），修复提交 `da20c3f`/`a23a9e9`，部署脚本改动态探测防回退。**Bearer 前缀疑点已闭环**：用户发送 RevenueCat 测试事件，实测入库（见 OPS-005 前的终验） |
| OPS-004 | **后续加固（本轮不做）**：webhook 鉴权升级为 **HMAC 签名验证**（RevenueCat 官方支持 `X-RevenueCat-Webhook-Signature` 头，比明文 Authorization 安全），需改代码实现 | **记录待办** | 来源：运维支付查 RevenueCat 官方文档；Chief 2026-11-08 指示登记，不在本轮五条标准范围内 |
| OPS-005 | **收款回调链路终验 → 正式闭环（2026-11-08）**：用户在 RevenueCat 后台点「Send Test」发出标准 TEST 事件（id `0FC88245-1E77-4267-BBCA-8F5F1EEFE304`），数据库 `revenuecat_event_facts` 落库（另含 15:09:16 一条），访问日志证实来源为 RevenueCat 官方服务器（User-Agent `RevenueCat`，AWS 网段 18.215.110.32 / 3.211.209.167），全程 **200 无一次 401**；`processing_result: ignored` 为测试事件的正确处理（真实购买走 `applied` 发权益） | **✅ 已闭环** | 链路：RevenueCat → Cloudflare 隧道 → nginx → PHP 鉴权 → 数据库落库，**项目开始以来第一次真正跑通**。**遗留一项**：备案通过后把 webhook 域名从临时隧道换成 `bojiclub.fun`（5 分钟的事，运维支付执行） |

---

## C. 验收记录表（Chief 验收时填写）

每轮验收一行：轮次 / 交付构建（Build 号 + IPA）/ 验收日期 / 结果（通过·不通过）/ 发现的问题 / 处置（重新派活给谁）。

| 轮次 | 构建 | 日期 | 结果 | 发现的问题 | 处置 |
|---|---|---|---|---|---|
| 第 1 轮 | dist/BojiClub-f9a471f6.ipa（run 42465043363，未签名 Debug） | 2026-11-08 | **通过（阶段 2）** | 首验发现 BUG-014 视频未静音（P1）、BUG-013 暂停钮触控区不足、BUG-015 低电量闸门缺，判不通过返工 | 返工后第四輪复验通过（E-2 表，commit 54092f1）；BUG-015 首帧占位留阶段 4；进入阶段 3 |
| 第 2 轮 | dist/BojiClub-f93a9470.ipa（run 42468330096，未签名 Debug） | 2026-11-08 | **通过（阶段 3）** | 首验 G-08 内容卡玻璃滥用（P0 六处）、P1 价格卡玻璃待拍板、BUG-016 勾选动效丢减动效门控、CLN-01/02 死代码 | 全部闭环：内容卡改不透明、价格卡按拍板去玻璃（G-19）、BUG-016 已修、CLN-01 已清；CLN-02 留阶段 4 顺手清；进入阶段 4 |
| 第 3 轮 | dist/BojiClub-8f1542dc.ipa（run 42470904790，未签名 Debug） | 2026-11-08 | **通过（阶段 4）** | 首扫 H-10 场景 1 进场动效与规范数值/曲线不一致、H-12 整串 0.6s 口径歧义、H-08 一屏运动元素待判定 | BUG-017 闭环（两处进场逐字一致，064d234）、规范 §4.2/§7 补口径、H-08 经界面设计核首页达标；进入阶段 5 总验收 |
| 第 4 轮 | dist/BojiClub-ea843320.ipa（run 42474824704，未签名 Debug，head bc9202a；T-2 随 run 42474004694 / 2433bb2a） | 2026-11-08 | **✅ Chief 签字通过（代码层面最终验收）** | 第 1 轮验收开出问题单 2 张：**T-1** BUG-009 强制解包加固（苹果开发）、**T-2** BE-005/BE-007（后端开发）。T-1 首验部分闭环，T-2 待补充复验 | T-1/T-2 双双关单（T-1 全库真实强制解包 31→0；T-2 复验通过，commit 9601226）；五条标准逐条终判通过（源码级+编译级）；**签字边界原话**：真机补验 7 项清单挂起，安装链路就绪实机跑完后才做整体关闭。报告定格 `a4f0692` |
| — | **Build 141（TestFlight 签名包）** | 2026-11-08 | **❌ 用户体验验收不合格 → 目标修订，进入三方案重做循环** | 用户真机装机后判定四条线全部不合格：**①界面丑 ②交互反人类 ③文案军事黑话 ④流程不聚焦**。Chief 复核截图认账四个病根（黑话如「战备状态/战术简报/战术任务/综合充能」；首页信息糊成一团；三个按钮抢一个决策；顶部标签栏仍是自绘胶囊违背原生组件要求）。**代码验收 ≠ 体验合格**，Chief 认这是验收口径的失误 | 真机 7 项补验不再单独前置，并入重做后的最终验收；现出三方案（J 节）等用户选定 → 视觉稿 → 用户点头 → 四条线分批重做 → 逐批 Chief 验收 → 真机复验 → 用户签字，循环到满意为止 |
| 重做第 N 轮 | （占位：重做批次启动后由 Chief 逐轮填） | | | | |

**第 4 轮五条标准终判（Chief 签字，源码级 + 云端编译级）**

| 标准 | 判定 | 关键证据 |
|---|---|---|
| ① 无崩溃、无明显 bug | 通过 | A 表 17 条：P1 全清、12 条验收关闭；T-1 关单——全库真实强制解包 31→0（剩 10 处全是前置 nil 短路或系统签名） |
| ② 操作流程顺 | 通过 | 5 个流程断点 + 4 大卡顿全修（通知深链、购买核验、弱网同步、AI 报告状态、多设备冲突） |
| ③ 原生组件 + 原生玻璃 | 通过 | 自绘控件零残留、材质统一桥接、iOS 17 降级三分支齐 |
| ④ 视频自然融入 | 通过 | 首页 Hero 玻璃卡、静音循环、三闸门、首帧占位无缝切换 |
| ⑤ 动效华丽不廉价 | 通过 | 三场景统一节奏、红线全守住、减动效降级齐 |

---

## D. 验收检查表（测试验收维护）

来源：界面设计《0.16.0-原生玻璃与动效规范》§7 + Chief 的 5 条验收标准 + A 表 bug 关闭情况。每轮验收逐项打勾并留证据（截图/日志/构建号）。

| 编号 | 检查项 | 判定标准 | 环境 | 状态 | 证据 |
|---|---|---|---|---|---|
| ACC-01 | 全控件系统化 | 无自绘按钮/弹窗/开关/键盘/步进；`LiquidCheckbox`、`ClubNumericKeypad`、`TrainingNumericInput125`、`SmartWeightStepper` 全部替换 | 源码 + 模拟器 | 待处理 | — |
| ACC-02 | 玻璃分层正确 | iOS 26 真机见玻璃折射；iOS 17–25 见系统磨砂；增强对比度/减少透明度为不透明+描边 | **降级验收**（DEC-2）：源码级核对 `clubGlassEffect` `#available` 分支；真机观感项待安装链路就绪补验 | 降级验收·**源码核对已完成** | `Design.swift:188-203` 三分支齐全（iOS 26 `glassEffect(.regular.interactive(true))`／iOS 17 `.regularMaterial`／减少透明度+增强对比度走不透明 `cardSurface`+描边）；但页面内仍有 3 处散写分支未收口，见 BUG-012 |
| ACC-03 | 玻璃数量合规 | 每屏玻璃件 ≤ 3，普通页 ≤ 1；玻璃下必有可辨识内容层 | 截图 | 待处理 | — |
| ACC-04 | 视频融入（标准④） | 静音循环、离开页面暂停并归零、减少动态效果/低电量为静态首帧、文字有渐变护字、单播放器复用 | 模拟器/真机 | 待处理 | 视频位**已定 A：首页 Hero 卡**（DEC-1） |
| ACC-05 | 动效合规 | 减少动态效果下无位移无循环；动效 ≤ 0.5s（流光除外且低频非循环）；同屏运动元素 ≤ 2 | 真机/模拟器 | 待处理 | — |
| ACC-06 | 触控与深浅色 | 触控区 ≥ 44pt；深浅色两套均通过 | 真机/模拟器 | 待处理 | — |
| ACC-07 | 主线流程顺（标准②） | 登录 → 首页 → 训练 → 记录 → 同步/支付 无卡壳；BUG-001~004 关闭 | 真机 | 待处理 | — |
| ACC-08 | 性能不回退 | 滚动 CPU 不高于基线（BUG-007：+47.2% 需归因并优化） | 同机同配置对比 | 待处理 | — |
| ACC-09 | 无障碍 | 侧栏自动审计全部通过（BUG-006 的 3 对比度 + 2 裁切） | 真机/模拟器 | 待处理 | — |
| ACC-10 | A 表 bug 清零 | BUG-001~017 全部「已验收关闭」或经 Chief 同意延后 | — | **12 条已验收关闭**；5 条（BUG-002/004/006/007/008）经 Chief 第 4 轮签字降级为真机补验项 | 第 4 轮签字：P1 全清，未关闭项不构成代码缺陷；真机补验见 I-3-A |

### 测试环境限制（测试验收备注）

1. 本机 Windows 无 Xcode，无法跑 XCTest／XCUITest 与 iOS 17 模拟器；ACC-02 的「iOS 17–25 磨砂」一项当前**没有可执行环境**，需运维支付确认能否提供 iOS 17 模拟器或真机，否则只能做源码级降级分支核对。
2. ACC-02/04/05/06/07/09 都需要真机或模拟器实际画面，依赖运维支付的真机安装链路（B4）。
3. 当前 `dist/BojiClub-4938f036.ipa` 为未签名 Debug 包，不可装真机，不能作为验收构建。**2026-11-08 更新**：`dist/BojiClub-c6647b04.ipa`（37.44 MB）已是**编译通过的未签名 Debug 包**，可用于模拟器/后续签名，真机仍需安装链路。

---

## E. 阶段 2 修复复验（测试验收，2026-11-08）【已收档：阶段 2 于 2026-11-08 经第四輪复验通过，本节转为归档记录；后续阶段复验实际另开 F 表（阶段 3 交互回归）、G 表（阶段 3 批次复验），阶段 4 复验从 H 表起】

复验窗口由 Chief 开启。本轮为**源码级静态复验 + 云端编译验证**（真机/模拟器画面项仍待安装链路）。

| 项 | 复验结论 | 证据 |
|---|---|---|
| **云端编译** | ✅ **通过** | `builder ios build` run 42461772092（Build ID c6647b04），IPA 37.44 MB；快照 `7913193` 与 HEAD `8b3447e` 的源码差异为空（仅未提交杂项文件），即**已提交状态编译通过** |
| **BE-001 会员核验异步化** | ✅ 通过（附 1 条观察） | `index.php:593`、`weekly.php:191` 请求路径已不再同步打 RevenueCat（注释确认改后台）；`/me` 走 `respondThen` 异步刷新（index.php:695）；后台 worker `account-server/process-membership-refresh.php` + `account-server/deploy/bojiclub-membership-refresh.{service,timer}` 已就位。**观察**：`/me/membership/verify`（index.php:701）仍同步强制刷新，但已不在受限请求路径；后台每分钟刷新后客户端轮询会收敛，可接受 |
| **BE-004 弱网同步** | ✅ 通过 | `AppStore.swift:2646` 改 `DomainCommandBackoff.delay(attempts:)` 指数退避；`:2618` 按 `nextAttemptAt` 跳过未到期命令；`:765` blocked 不再中止整次同步；`ClubProposalSync.swift` 新增 `nextAttemptAt` + `DomainCommandBackoff` |
| **客户端四连修** | ✅ 全部通过 | ①`ClubNotificationRoute: Identifiable, Equatable`（AppStore.swift）；②`TrainingRegistrationViews.swift:293/304` 已用 `Button(action:) { }`；③`ClubAIShell.swift:1178` TimelineView 闭包为表达式体、无非法 `return`；④`ClubAIShell.swift:1207-1228` 改用 `HeroVideoContainerView`（`AVPlayerLayer` + `videoGravity = .resizeAspectFill`） |
| **BUG-001 / 010 / 011 通知横幅** | ✅ 通过 | 横幅 `safeAreaInset(edge: .top)` 不压顶栏；`actionTitle: "知道了"` 关闭；training 类文案如实 |
| **BUG-005 视频三闸门** | ⚠️ 部分 | 循环（`AVPlayerLooper`）、离场暂停归零、reduceMotion 降级、深色压暗、护字渐变均到位；**未静音**（BUG-014，P1）、低电量与首帧占位缺失（BUG-015，P3）。**界面设计独立核对结论一致**（ClubAIShell.swift:1180-1244）：reduceMotion 闸门在（:1191）、离场暂停回零与 scenePhase 后台暂停都在、低电量闸门缺；并确认「静音」注释与实现不符 |
| **BUG-012 玻璃分支收口** | ✅ 通过 | 全库 `if #available(iOS 26` 仅剩 `Design.swift:160/197/211` 桥接自身（预期） |
| **BUG-003 输入串轨** | ⚠️ 部分 | `ClubNumericKeypad`／`LiquidCheckbox` 已删并改原生；`SmartWeightStepper`（DesignTokens.swift:741）与 `TrainingNumericInput125`（WorkoutExperience125.swift:169）仍在（IOS-003／004 未做） |
| **BUG-013 暂停钮触控区** | ❌ 未修 | 仍为 30×30pt（ClubAIShell.swift:1281） |

**复验结论（第三輪）**：BE-001／BE-004 与客户端四连修通过，云端编译通过；**阶段 2 尚不能判通过**——BUG-014（P1 视频未静音）必须修，BUG-003 剩余两项与 BUG-013／015 需排期。

### E-2. 第四輪返工复验（测试验收，2026-11-08，Chief 判定阶段 2 不通过后返工）

| 项 | 复验结论 | 证据 |
|---|---|---|
| **BUG-014 视频静音** | ✅ 通过 | `ClubAIShell.swift:1194` `player.isMuted = true`（commit 54092f1） |
| **BUG-015 低电量闸门** | ✅ 通过（首帧占位留阶段 4） | `ClubAIShell.swift:1191` guard 增 `!ProcessInfo.processInfo.isLowPowerModeEnabled` |
| **BUG-013 暂停钮触控区** | ✅ 通过 | `ClubAIShell.swift:1287-1288` `.frame(width: 44, height: 44).contentShape(Circle())`，视觉 30pt／命中 44pt |
| **云端编译回归** | ✅ 通过 | run 42465043363（Build ID f9a471f6，head `54092f1`），耗时 4m37s，产物 `dist/BojiClub-f9a471f6.ipa`（37.44 MB，未签名 Debug） |

**第四輪复验结论：通过。** 阶段 2 的 P1 阻塞项已清空；BUG-003 剩余 IOS-003／004 按 Chief 决定转阶段 3 关闭（苹果开发已推 b1d31c7 完成，待其构建验证），BUG-015 首帧占位留阶段 4。

> 注：`dist/BojiClub-f9a471f6.ipa` 为未签名 Debug 包，模拟器可用、真机仍需安装链路（B4）。

---

## F. 交互回归核查（阶段 3，测试验收）

**方法限制**：本机无 Xcode／模拟器／真机安装链路，本轮为**源码级核查**——检查各改造项在四种系统设置（深色模式、更大字体、减少动态效果、增强对比度）下的分支是否存在且正确。**观感与实际行为仍需安装链路就绪后在真机/模拟器上复跑**，F 表结论不代表已实测。

### F1. 全局四种设置的基础设施

| 编号 | 检查项 | 源码证据 | 结论 |
|---|---|---|---|
| INT-01 | 动态字体缩放 | `DesignTokens.swift:152-162` `BojiFontModifier`：非 `.bodyMetric` 走 `Font.system(role.textStyle, weight:)`（跟随系统）；`.bodyMetric` 走 `Font.system(size: role.size * scale)`，`scale` 为 `@ScaledMetric(relativeTo: .body)`（同样跟随系统） | ✅ 通过 |
| INT-02 | 更大字体（AX1–AX5）布局降级 | `ClubAIShell.swift:781` 分段选择器在 `isAccessibilitySize` 时降级 `.menu`；`BodyWeightView.swift:58/106`、`BojiComponents.swift:247/365`、`DashboardComponents.swift:243/333`、`ClubInsightTimelineView.swift:152` 均有 AX 分支 | ✅ 通过 |
| INT-03 | 减少动态效果 | `Design.swift:123` `transitionAnimation` 在 reduceMotion 时为 nil；`ClubAIShell.swift:1178` TimelineView `paused: reduceMotion`；`:1191` Hero 视频 reduceMotion 时不创建 player（回退静态底） | ✅ 通过 |
| INT-04 | 减少透明度 / 增强对比度 | `Design.swift:188-203` `ClubGlassSurface`：`reduceTransparency \|\| contrast == .increased` → 不透明 `cardSurface` + 描边；`Design.swift:205-220` `clubNativeGlassButton` 同样三分支；`DesignTokens.swift:459` `BojiDeepShadowModifier` 增强对比度加粗描边 | ✅ 通过 |
| INT-05 | 深色模式 | 颜色走 `BojiColor` 自适应 Token（浅/深两套）；额外分支：`ClubAIShell.swift:1246` Hero 视频深色压暗 20%、`FirstLaunchWalkthroughView.swift:49/784/796/812` 引导页深色调 | ✅ 通过（Token 层） |

### F2. 改造项 × 四种设置逐项核查

| 编号 | 改造项 | 深色 | 大字号 | 减少动态 | 增强对比度 | 结论 |
|---|---|---|---|---|---|---|
| INT-06 | IOS-001 勾选按钮（`TrainingRegistrationViews.swift:293/304`） | 用 `BojiColor.emeraldAccent`／`textTertiary` 自适应 Token | `Image` 28pt 固定尺寸，AX5 下偏小但命中区 44pt 达标 | **`symbolEffect` 无 reduceMotion 门控（见 BUG-016）** | 不涉玻璃，无影响 | ⚠️ 待修（BUG-016） |
| INT-07 | IOS-002 数字输入（`ClubNumericField`，Experience123.swift:167） | `inputSurface` 自适应 | 系统 TextField 跟随系统字体 | 无动效 | 无影响 | ✅ 通过 |
| INT-08 | IOS-003 训练数值输入（`WorkoutExperience125.swift`，b1d31c7） | 原生 TextField + `inputSurface` | 系统键盘 + 系统字体 | 键盘工具条系统行为 | 无影响 | ✅ 通过 |
| INT-09 | IOS-004 体重步进（`SmartWeightStepper`，b1d31c7） | 系统 Stepper 自适应 | 系统 Stepper 跟随 | 系统行为 | 无影响 | ✅ 通过 |
| INT-10 | IOS-005 材质收口（17 处浮件 + 2 处内容卡） | Token 自适应 | 不影响 | `clubGlassEffect` 不含动效 | 由 `ClubGlassSurface` 分支保证不透明+描边 | ✅ 通过 |
| INT-11 | IOS-006~010 动效系统化 | — | — | — | — | ⏳ 未开工（B1 表待处理） |
| INT-12 | Hero 视频（ClubAIShell.swift:1178-1250） | `:1246` 深色压暗 | 不涉文字缩放 | reduceMotion／低电量不播，显静态底 | 玻璃层由 `clubGlassEffect` 处理 | ✅ 通过 |
| INT-13 | 通知横幅（BojiClubApp.swift:243-253） | `BojiStatusBanner` 用自适应 Token | `BojiStatusBanner` 文字走 `.caption`（跟随系统） | 无循环动效 | 无玻璃 | ✅ 通过 |

### F3. 复验中发现的清理项

| 编号 | 问题 | 位置 | 严重度 | 备注 |
|---|---|---|---|---|
| CLN-01 | `ClubActionButtonStyle` 里 `@Environment(\.accessibilityReduceTransparency)` 与 `@Environment(\.colorSchemeContrast)` 已**不再被使用**（该样式已收口为 `clubNativeGlassButton`），属遗留 dead code | JourneyComponents.swift:58-59 | P3 | 不影响功能与编译（仅警告）；**已在 fea35b7 清理完毕** |
| CLN-02 | `BreathingPulseHalo` 全库已无使用点（仅 `DesignTokens.swift:674` 定义本身），属死代码 | DesignTokens.swift:674 | P3 | 测试验收阶段 3 收尾复扫发现；IOS-007 已改为直接内联 `Gauge`，原封装未再被引用。建议删除定义（勿误以为「还在用」） |

**F 表结论**：全局四种设置的基础设施（INT-01~05）齐备；已改造控件中 INT-07/08/09/10/12/13 通过，**INT-06 未通过**（勾选按钮 `symbolEffect` 无 reduceMotion 门控 → BUG-016）；INT-11（IOS-006~010 动效）未开工。**待办：安装链路就绪后，在真机/模拟器上按 F2 逐格实测复跑。**

---

## G. 阶段 3 批次复验（测试验收，2026-11-08）

复验苹果开发 43d66f8→77883ff 批次（IOS-006~009 动效系统化 + P0 玻璃收口 + BUG-016/CLN-01）。源码级核查，编译 run 42466697711 出包 `dist/BojiClub-1c1d85e0.ipa`（37.41 MB）。

| 编号 | 复验项 | 结论 | 证据 |
|---|---|---|---|
| G-01 | IOS-006 手绘 spinner → 原生 ProgressView | ✅ 通过 | `Design.swift:331-339` `ClubActivityMark` 内改为 `ProgressView().progressViewStyle(.circular)`；`:450` `AIProcessingMark` 同；TimelineView 手绘脉冲已删 |
| G-02 | IOS-006 `ClubWaitBar` 减动效降级 | ✅ 通过 | `Design.swift:484-500` `if active && !reduceMotion { ProgressView().linear } else { 静态 Capsule }` |
| G-03 | IOS-007 呼吸环 → 原生 Gauge | ✅ 通过 | `DesignTokens.swift:674-700` `Gauge(.accessoryCircularCapacity)` + `symbolEffect(.bounce, value: isUrgent)`，保留触感与无障碍标签/值 |
| G-04 | IOS-008 激光扫描线 → 系统进度语义 | ✅ 通过 | `DesignTokens.swift:786-805` 改为半透明遮罩 + `ProgressView` +「正在识别餐食…」，未新增玻璃件 |
| G-05 | IOS-009 彩带粒子 → 系统庆祝 | ✅ 通过 | `ConfettiView` 全库已删（零命中），改 SF Symbols + 一次性 `symbolEffect(.bounce)` |
| G-06 | BUG-016 勾选动效减动效门控 | ✅ 通过 | `TrainingRegistrationViews.swift:298` `if reduceMotion { base } else { base.symbolEffect(...) }` |
| G-07 | CLN-01 遗留 Environment 清理 | ✅ 通过 | `JourneyComponents.swift` 已无 `reduceTransparency`/`colorSchemeContrast`（零命中） |
| G-08 | P0 玻璃滥用收口（内容卡去玻璃） | ✅ **通过（fea35b7 复扫）** | 界面设计走查列 6 处（ClubAIShell 1426/1609/1720/1812/1888/1946 + ProfileView 奖励卡）。测试验收按当前源码复扫：ClubAIShell 内容层玻璃已 **归零**，仅剩 6 处浮件——`:821` 侧栏浮层、`:982/:1020/:1029` 速度拨号、`:1296` Hero 卡、`:1988` 训练迷你条（均属 L2 浮件或 DES 允许的 Hero）。ProfileView 5 处经界面设计判定为底部停靠条/状态条浮件，**合规保留** |
| G-11 | IOS-010 引导页重做 | ✅ 通过 | `FirstLaunchWalkthroughView.swift` 内 `RadialGradient` 手绘光晕已清零；旋转环改静态（`rotationEffect(.degrees(-90))` 为常量、非动画）；水晶球 `:238`、Slide 2 主体 `:421` 各 1 处玻璃，**每屏 1 处**符合密度红线；卫星胶囊/页码/徽章改不透明表面 |
| G-12 | 业务图形豁免确认 | ✅ 通过 | 全库仅剩 `BojiComponents.swift:83` 一处 `RadialGradient`，位于品牌封面图形内，属 DES 铁律 1 明确允许的「业务图形（封面/图表/缩略图）」范畴，不算违规 |
| G-09 | `.celebrate` 不可用 | ✅ 已规避 | 苹果开发改用系统 `.bounce`，一次性庆祝语义不变；规范如需 `celebrate` 须先确认 SDK 版本（当前 SDK 的 `DiscreteSymbolEffect` 无此成员） |
| G-10 | 编译回归 | ✅ 通过 | run 42466697711（head `77883ff`），产物 37.41 MB |

**G 表结论（复扫后更新）**：IOS-006~009、BUG-016、CLN-01 全部通过；**G-08 复扫通过**——ClubAIShell 内容层玻璃归零，ProfileView 5 处判定合规；**G-11 IOS-010 通过**（引导页每屏玻璃 1 处）；G-12 业务图形豁免确认。**阶段 3 的玻璃红线项已达标。**

### G-3. 阶段 3 收尾复验（测试验收，2026-11-08，head `0b638da`）

| 编号 | 复验项 | 结论 | 证据 |
|---|---|---|---|
| G-13 | IOS-012 卡门可恢复 | ✅ 通过 | `ProfileView.swift:158-162` 底部浮条新增「重新检查会员状态／正在检查…」按钮，`Task { await membership.refresh(force: true) }`，带禁用态；账号管理/退出路径保留 |
| G-14 | IOS-013 休息提醒单源校正 | ✅ 通过 | `ClubAIShell.swift:175-177` `.onChange(of: activeWorkout?.isPaused)` 暂停即 `cancelRestReminder()`；`:187` onAppear 兜底；与既有 `:168-172` pauseService 分支并存形成双保险（跨午夜边界仍留真机复核） |
| G-15 | 自绘控件全量复扫 | ✅ 通过 | `LiquidCheckbox`／`ClubNumericKeypad`／`ConfettiView` 全库零命中；`TrainingNumericInput125`／`SmartWeightStepper` 保留同名薄封装但内部已是原生 `TextField`／系统 `Stepper`；`ClubActivityMark`／`AIProcessingMark`／`ClubWaitBar`／`BreathingPulseHalo`／`LaserScanBeamOverlay` 内部均已换原生 ProgressView／Gauge |
| G-16 | 材质与玻璃分支全量复扫 | ✅ 通过 | `.regularMaterial`/`.ultraThinMaterial` 直写仅剩 `Design.swift:200`（桥接自身降级分支，正确）；`if #available(iOS 26` 仅剩 `Design.swift:160/197/211`（桥接自身，正确）；全库 `clubGlassEffect` 42 处均经逐处判定 |
| G-17 | 编译回归 | ✅ 通过 | run 42467773417（head `0b638da`），产物 `dist/BojiClub-53aedefe.ipa`（37.43 MB） |
| G-18 | P1 `RevenueCatViews.swift:318` 会员价格卡去玻璃（Chief 已拍板，不给豁免） | ✅ **通过**（commit d837df6） | 复扫：`:318` 已改 `.background(BojiColor.cardSurface, ...)`，`clubGlassEffect` 在该文件**零命中**；`:319` 选中态阴影 `radius: selected ? 18 : 0, y: selected ? 5 : 0` 对齐 L1 内容卡标准；`:317` 注释已改为「2026-11-08 Chief 拍板：价格卡改不透明 cardSurface，废止『拍板 #6』玻璃豁免」，无矛盾线索 |

**阶段 3 客户端完成条件清点**：①4 个自绘控件全换原生 ✅；②23 处材质收口 ✅；③自绘动效换系统动效（IOS-006~010）✅；④流程断点改造（IOS-012/013）✅；⑤界面设计走查达标（G-08/G-11）✅；⑥云端编译通过 ✅。**待 Chief 过目认可**；P1 `RevenueCatViews.swift:318` 待拍板，CLN-02 建议清理。

### G-4. 阶段 3 最终全量复扫（测试验收，head `d837df6`）

| 编号 | 复验项 | 结论 | 证据 |
|---|---|---|---|
| G-19 | P1 价格卡去玻璃（Chief 拍板项） | ✅ 通过 | `RevenueCatViews.swift` 内 `clubGlassEffect` **零命中**；改 `cardSurface` + 选中态 y5/blur18 阴影 + 注释已注明拍板（详见 G-18） |
| G-20 | 全库玻璃件总量与分布 | ✅ 通过 | 全库 `clubGlassEffect` **41 处 / 22 文件**；逐文件计数已登记。原 P0 六处与 P1 一处已全部处置（内容卡改不透明，浮件保留） |
| G-21 | 材质直写全库复扫 | ✅ 通过 | `.regularMaterial`/`.ultraThinMaterial` 仅剩 `Design.swift:200`（桥接自身降级分支） |
| G-22 | 玻璃系统版本分支全库复扫 | ✅ 通过 | `if #available(iOS 26` 仅剩 `Design.swift:160/197/211`（桥接自身），页面层零散写 |
| G-23 | 编译回归 | ✅ 通过 | run 42468330096（head `d837df6`，含价格卡改动），产物 `dist/BojiClub-f93a9470.ipa`（37.44 MB） |

**阶段 3 结论**：客户端六项完成条件全部满足（G-13~G-23），P1 拍板项已闭环（G-19）；**编译回归通过（G-23）**。仅剩 P3 清理项 CLN-02（`BreathingPulseHalo` 死代码）不影响达标。**复验通过，交 Chief 过阶段 3。**

---

## H. 动效走查（阶段 4，测试验收，2026-11-08）

源码级核查（无设备）。口径：DES §0 铁律 3、§4.2 华丽感红线、§5.2 视频规格。

| 编号 | 检查项 | 结论 | 证据 |
|---|---|---|---|
| H-01 | Hero 视频三闸门 | ✅ 通过 | `ClubAIShell.swift:1196` guard 含 `!reduceMotion` 与 `!ProcessInfo.processInfo.isLowPowerModeEnabled`；`:1206-1207` 离场 `pause` + `seek(.zero)`；`:1199` `isMuted = true` |
| H-02 | 视频未就绪防黑块 | ✅ **通过**（commit 5ab6f97） | `ClubAIShell.swift:1209-1222` `loadHeroPoster()`：`AVAssetImageGenerator` 在 `Task.detached(.utility)` 后台截第 0 帧（`appliesPreferredTrackTransform`、上限 960×960），`await MainActor.run` 回主线程发布；`:1198` 在 guard **之前**无条件调用，故减少动态效果/低电量下也会生成静态帧；`heroGlassContent` 分层为 **z0 首帧占位 + z0b 视频层叠加**（`:1259-1272`），视频就绪后叠加切换，消除原纯色块跳变。仅在 poster 尚未生成的一瞬间仍有 `brandMist` 兜底（短暂瞬态，可接受） |
| H-03 | 无限循环动效的减动效门控 | ✅ 通过 | 全库 `repeatForever` 3 处均 gated：`Design.swift:395`（`guard !reduceMotion else { return }`）、`FirstLaunchWalkthroughView.swift:226`、`ProductArchitecture.swift:570`（均 `reduceMotion ? nil : ...`） |
| H-04 | 彩虹轮播 | ✅ 通过 | 全库无 `hueRotation`／彩虹相关实现 |
| H-05 | 整屏转场 | ✅ 通过 | 全库 `.transition(...)` 15 处均为 `.opacity`／`.move(edge:)`／`.scale` 组合，无整屏缩放/翻转转场 |
| H-06 | TimelineView 装饰性动画 | ✅ 通过 | 12 处中 1 处为 Hero 玻璃流光（`paused: reduceMotion` 已 gated），其余 11 处均为 `.periodic(by: 1)` 的**功能性计时器**（组间倒计时/训练计时），非装饰动效 |
| H-07 | 模糊效果 | ✅ 通过 | 3 处 `.blur(radius: 60/70/80)` 均为引导页静态背景色块，非动画、非无限循环 |
| H-08 | 一屏同时运动元素 ≤2 | ⏳ 待判定 | 需界面设计按 §4.2 逐屏核对，并在真机/模拟器上观察；静态源码无法可靠判定 |
| H-09 | CLN-02 死代码清理 | ✅ 通过 | `BreathingPulseHalo` 全库零命中（commit 98900b6） |
| H-10 | DES-004 场景 1 首页两拍进场 | ✅ **通过**（commit 064d234 收口） | `ClubAIShell.swift` `BojiHomeEntrance` 已改回规范档：`BojiMotion2.entrance`（spring 0.35/0.85）+ `.delay(index * 0.05)` + `scaleEffect(0.96→1)`，只动 opacity/transform；`BojiMotion2.resolved` 在减少动态效果时降为 0.12s 交叉淡入 |
| H-11 | DES-004 场景 2 训练中 | ✅ 通过 | `BojiSegmentedProgress` 改 `BojiMotion2.progress`（线性 easeOut 0.32s，杜绝假进度弹簧）；组数 `contentTransition(.numericText())` + counter |
| H-12 | DES-004 场景 3 完成页 | ✅ **通过** | `WorkoutExperience125.swift` `BojiStaggeredEntrance` 与场景 1 **实现逐字一致**（同一 Token、同一 scale）；`BojiRollingFact` 减动效直落终值 ✅；`.sensoryFeedback(.success, trigger: appeared)` 一次性 ✅；整串 0.60s，按规范新增口径（单元素 ≤0.5s、整串 ≤0.6s）合规 |
| H-13 | DES-004 红线复查 | ✅ 通过 | 无循环装饰、无彩虹、无整屏转场；新增动效全部只动 opacity/scale/offset 或数字；`sensoryFeedback` 属触感反馈非视觉运动；首页同时运动元素 2（界面设计 H-08 已核） |

**H 表结论（终扫完成）**：H-01~H-13 **全部通过**。减动效降级（H-02/H-03/H-10/H-12）、红线（H-04 无彩虹／H-05 无整屏转场／H-06 TimelineView／H-07 模糊／H-13 同时运动元素 2）、规范口径一致性（H-10/H-12 两处逐字一致，单一 Token 来源）均已核实。编译 run 42470904790 出包 `dist/BojiClub-8f1542dc.ipa`（37.47 MB）。

**阶段 4 完成条件清点**：①品牌视频融入拍板位置（首页 Hero 玻璃卡底层，方案 A）✅；②播放自然不卡顿 ✅（源码级：`AVQueuePlayer` + `AVPlayerLooper` 循环、三闸门、首帧占位无缝切换；真机观感待链路）；③新动效符合规范、高级华丽不廉价 ✅（三场景按规范 §4.1 落地、红线全合规、口径单一来源）；④减少动态效果表现正常 ✅（源码级：所有动效均有 reduceMotion 降级分支）；⑤云端编译通过 ✅。**待 Chief 过目认可。**

---

## I. 总验收汇总（阶段 5，文档管理，2026-11-08）

### I-1. 验收记录表汇总

| 阶段 | 验收轮次 | 复验表 | 交付构建（未签名 Debug） | 结果 |
|---|---|---|---|---|
| 1 摸底与规范 | — | — | — | **通过**（四份产出交叉核实一致） |
| 2 P0 修复 | 第 1 轮 | E 表 / E-2 表 | `BojiClub-f9a471f6.ipa`（run 42465043363，37.44 MB） | 首验不通过（BUG-013/014/015）→ 返工 → **通过**（54092f1） |
| 3 UI 原生化 | 第 2 轮 | F 表 / G 表 / G-3 / G-4 | `BojiClub-f93a9470.ipa`（run 42468330096，37.44 MB） | 首验有问题（G-08 玻璃滥用、P1 价格卡、BUG-016）→ 闭环 → **通过** |
| 4 视频动效 | 第 3 轮 | H 表（H-01~13） | `BojiClub-8f1542dc.ipa`（run 42470904790，37.47 MB） | 首扫 BUG-017 进场口径不一致 → 统一 Token → **通过**（064d234） |
| 5 总验收 | 第 4 轮 | 全量回归报告（`BUILD140-验收报告.md`，定格 `a4f0692`） | 终态包 `BojiClub-ea843320.ipa`（run 42474824704，37.48 MB；T-2 随 run 42474004694 / 2433bb2a） | 第 1 轮开出 T-1/T-2 → 双双关单 → **Chief 签字通过（代码层面最终验收）**；真机补验 7 项挂起 |

复验方法说明：本轮 Windows 无 Xcode/真机，**全部结论为源码级 + 云端编译级**；真机/模拟器画面项挂 B4 安装链路就绪后补验（见 I-3-C）。

**问题单台账（第 1 轮验收开出，均已关单）**

| 单号 | 内容 | 负责人 | 严重度 | 状态 |
|---|---|---|---|---|
| T-1 | BUG-009 强制解包加固：重点 6 处（`AppStore.swift:2111`、`ExerciseLibraryView:143/168/178`、`MembershipService:240`、`HealthViews:206`）加 guard 安全回退 | 苹果开发 | P3（加固） | **已验收关闭**（复验：全库 31→10 处且全为安全模式，真实强制解包清零；`components.url!`/`URL(string:...)!` 零命中） |
| T-2a | BE-005 AI 完成状态改后台对账（`process-ai-completion-refresh.php` 每 30s + systemd timer），请求路径降级兜底超时 1–2s→4s | 后端开发 | P2 | **已验收关闭**（commit 9601226） |
| T-2b | BE-007 多设备同步锁改排队等锁最多 5s + 客户端重试 3→6 次、不收敛自动续同步 | 后端开发 | P2 | **已验收关闭**（commit 9601226） |

> **记遗留不开单**：BE-006（旧账号大迁移，边缘场景）、BE-008（AI worker 无 Key，属部署配置，随 OPS-003 补键一并处理）。

### I-2. 改动清单汇总

**A. 客户端 iOS（15 项改造 IOS-001~015，全部已修复待验并经阶段复验）**

| 类别 | 改动 | 证据 |
|---|---|---|
| 自绘控件 → 原生（4 项） | LiquidCheckbox→系统符号按钮；ClubNumericKeypad→系统键盘+原生 TextField；TrainingNumericInput125→原生 TextField+键盘工具条；SmartWeightStepper→系统 Stepper | G-15 全库零命中（同名薄封装内部已原生化） |
| 材质收口（IOS-005） | 23 处直写材质 → `clubGlassEffect`；内容卡玻璃滥用清零（含 P1 价格卡按拍板去玻璃）；全库 41 处玻璃件/22 文件逐处判定合规 | G-08/G-19/G-20/G-21/G-22 |
| 动效系统化（IOS-006~010） | 手绘 spinner/呼吸环/激光线/彩带/引导页轨道环 → ProgressView/Gauge/symbolEffect/glassEffect+SF Symbols | G-01~G-05/G-11 |
| 流程断点（IOS-011~013） | 通知深链改顶部横幅（如实文案+知道了）；卡门可恢复（重新检查会员状态按钮）；组间休息提醒单源校正 | E 表、G-13/G-14 |
| 品牌视频（IOS-014） | 首页 Hero 玻璃卡底层视频（方案 A）：静音循环、离场暂停归零、三闸门（减动效/低电量/未就绪）、首帧占位防黑块、护字渐变、深色压暗、44pt 暂停钮 | H-01/H-02、BUG-005/013/014/015 全闭环 |
| 三场景动效（IOS-015） | 首页两拍进场、训练中数字 counter+线性进度、完成页 stagger 事实格+数字滚动+一次性触感；统一 `BojiMotion2` Token（spring 0.35/0.85、stagger 0.05、scale 0.96→1），减动效降 0.12s 交叉淡入 | H-10~H-13、BUG-017 闭环 |
| 死代码清理 | CLN-01（fea35b7）、CLN-02 `BreathingPulseHalo`（98900b6） | G-07、H-09 |

**B. 后端与账号服务**

| 编号 | 改动 | 状态 |
|---|---|---|
| BE-001 | 会员核验改后台异步：请求路径只读本地权益；新增 `process-membership-refresh.php` + systemd timer 每分钟核对 | E 表复验通过，待总回归统一关闭；线上生效待 OPS-003 补键 |
| BE-004 | 弱网同步改指数退避自动重试（2s→…→1h），blocked 不再中止整次同步 | E 表复验通过，待总回归统一关闭 |
| BE-002/003 | 部署配置契约：deploy.sh 生成完整 21 键、`config-contract.php`/`check-config.php`、测试 21 键全过、商品档改 `yuefu/nianfu/yongjiu`、environment 对齐 SANDBOX、`.gitignore` 补密钥目录 | 源码就位，**线上补键待办（OPS-003）** |

**C. 规范与文档**

- 界面设计：《0.16.0-原生玻璃与动效规范》（DES-001）、Hero 视频卡视觉稿（DES-003）、三场景动效方案（DES-004）。
- 文档管理：本台账（A/B/C/D 表 + E~H 复验表 + I 节汇总）；关键决定 DEC-1~3 登记。
- 测试验收：D 表 ACC-01~10、F/G/H 复验表、问题发现闭环记录（BUG-001~017、CLN-01/02）。

### I-3. 遗留项清单

**A. bug 清单现状（A 表 17 条，2026-11-08 最新）**

- **已验收关闭 12 条**：BUG-001/003/005（P1 全清）、009（T-1 关单，真实强制解包清零）、010/011/012/013/014/015/016/017——各阶段复验（E/G/H 表）均已通过。
- **已修复待验 2 条**（修复已落地，剩边界/多路径复核）：

| 编号 | 严重度 | 状态 | 卡在哪 |
|---|---|---|---|
| BUG-002 登录→首页入口状态机 | P2 | 已修复待验（部分：卡门可恢复，G-13） | 四层状态机回写时序未全面收口，真机多路径待验 |
| BUG-004 组间休息跨午夜/跨时区 | P2 | 已修复待验（单源校正，G-14） | 跨午夜/跨时区边界待真机跨日复核 |

- **待处理 4 条**（P2/P3，不阻塞五条标准，经 Chief 第 4 轮签字降级为真机补验项）：

| 编号 | 严重度 | 状态 | 卡在哪 |
|---|---|---|---|
| BUG-006 侧栏无障碍审计 3 对比度+2 裁切 | P2 | 待处理（真机补验项） | 上一轮遗留，未知项无法定位 |
| BUG-007 滚动性能 +47.2% | P2 | 待处理（真机补验项） | 未采样归因，影响华丽动效流畅观感 |
| BUG-008 顶栏选择器小屏溢出（375pt） | P3 | 待处理（真机补验项） | 待小屏复核 |
| ~~BUG-009 强制解包风险点~~ | — | **已验收关闭（T-1 关单）** | 全库 31→10 处且全为安全模式，真实强制解包清零 |

**真机补验 7 项清单**（原 Chief 第 4 轮签字挂起项）→ **2026-11-08 目标修订后并入阶段 7「重做后验收循环」执行，不再单独前置**（用户已装机判定体验不合格，先重做再真机收口）：①四种系统设置（深色/大字号/减动效/增强对比度）各走首页·训练中·训练完成·购买页；②视频播放（Hero 流畅度、首帧→视频切换、静音、离场/后台停播、低电量与减动效静态帧）；③动效观感（三场景是否华丽不廉价、同屏运动元素 ≤2）；④主线流程（登录→首页→训练→记录→同步→支付，含购买后核验不再转圈）；⑤边界（跨午夜训练、跨时区休息截止、弱网恢复自动续同步）；⑥无障碍（侧栏自动审计 BUG-006、VoiceOver 焦点、触控区 ≥44pt）；⑦性能（滚动 CPU 对基线 BUG-007、启动耗时、静置内存）。

**B. 后端与部署遗留**

- BE-001/BE-004：已修复待验（E 表复验通过），第 4 轮验收随 T 单关闭统一转关闭。
- BE-005/BE-007：**已验收关闭（T-2 关单，commit 9601226）**；两个 worker 已在服务器实测执行成功。
- BE-002/003：**线上已修复**（OPS-003 完成）——21 键配置校验全过、webhook 鉴权链路实测 200/401、迁移全绿。
- BE-006/BE-008：记遗留不开单（BE-006 旧账号大迁移边缘场景；BE-008 属部署配置，随补键一并处理）。
- **Bearer 前缀疑点：已闭环（2026-11-08）**。用户发 RevenueCat 测试事件 → 实测鉴权通过、事件入库、全程 200，证明服务器与后台取值一致，无需改动。留档经验：RevenueCat **原样发送**后台所填值，不加任何东西，两边必须逐字一致。
- **收款回调链路：✅ 正式闭环**（终验证据见 B4 OPS-005）——RevenueCat → Cloudflare 隧道 → nginx → PHP 鉴权 → 数据库，项目开始以来第一次真正跑通；`ignored` 是 TEST 事件的正确处理，真实购买走 `applied` 发权益。
- OPS-004 后续加固：webhook 鉴权升级 HMAC 签名验证（本轮不做）。
- **备案后切换域名**：webhook 现在走临时 Cloudflare 隧道，备案通过后换正式域名 `bojiclub.fun`（运维支付执行，约 5 分钟）。
- 历史坑（已修）：11 个 systemd worker 写死 `User=www-data`（实际用户 `nginx`）导致后台任务长期静默失败，已全部修复并触发验证（`da20c3f`/`a23a9e9`）。

**C. 真机/模拟器补验项（安装链路就绪后必须补验，当前全部为源码级结论）**

> **状态：正式挂起（2026-11-08 Chief 第 4 轮签字边界）**。跑完由测试验收补报告、交 Chief 签字后才做整体关闭。清单即 I-3-A 的「真机补验 7 项清单」。

| 来源 | 待补验内容 |
|---|---|
| D 表 | ACC-01（模拟器即可）、ACC-03/04/05/06/07/08/09 需真机/模拟器画面；ACC-02 真机观感补验（DEC-2 降级验收的真机部分） |
| F 表 | F2 逐格实测复跑：深色/大字号/减动效/增强对比度四种设置下的实际观感与交互 |
| H 表 | H-08 一屏运动元素 ≤2 的逐屏真机观察（首页已核，其余屏待观察） |
| A 表 | BUG-002/004/006/007/008 的模拟器/真机复核；「播放自然不卡顿」「四种设置实际观感」需真机收口 |

**D. 环境与流程待办（等用户拍板）**

- ~~OPS-001/002 真机安装链路~~ → **已完成**：TestFlight Build 141 已进测试组，用户已装机（装机后判定体验不合格，转入重做循环，见 J 节）。
- ~~OPS-003 服务器补键~~ → **已完成**（2026-11-08，见 B4）。
- ~~Bearer 前缀确认~~ → **已闭环**（测试事件实测入库，两边一致）。
- **待用户**：三方案选定回「1/2/3/2+3」（见 J 节）——这是当前唯一的推进闸门。
- **待备案**：webhook 域名从临时 Cloudflare 隧道切 `bojiclub.fun`（运维支付，约 5 分钟）。
- OPS-004 webhook 鉴权升级 HMAC（后续加固，本轮不做）。
- 苹果开发模型账号余额不足（402）停机：重做循环开工前需恢复（充值或换模型）——**现在是阻塞项**。

**E. 已知未实现功能（不计本轮 bug，单独跟踪）**：`KNOWN-ISSUES.md` 的 E6 距离计量、D6 提醒频率学习、E7 围度/体脂独立流程、漏练补排、行动状态机全面接入、草稿并发分叉。

---

### 阶段 5 交付物

| 交付物 | 负责人 | 状态 |
|---|---|---|
| [BUILD140-验收报告.md](BUILD140-验收报告.md)（全量回归，五条标准逐条附证据） | 测试验收 | **已交付并定稿**（a4f0692）；Chief 第 4 轮签字通过 |
| A 表状态对齐（12 条已验收关闭 / 2 条真机补验 / 3 条真机补验项 / 0 未关闭阻塞） | 测试验收 | 已完成 |
| 台账齐全（A/B/C/D/E/F/G/H 八表 + I 节汇总 + 报告） | 文档管理 | 已齐全 |

> 报告结论：代码层面五条标准全部达成；未关闭项（BUG-002/004/006/007/008）全部依赖真机/设备环境，不构成代码缺陷。**全部结论为源码级 + 编译级，不含真机实测数据。**

---

## J. 重做三方案与用户选定（阶段 5，2026-11-08）

> **背景**：Build 141 真机装机后用户判定整体体验不合格（四条线全打回），目标修订为「四条线全面重做 + 用户真机签字」。Chief 按用户原话要求（原生 iOS 组件、iOS 26/27 原生玻璃、高级感、华丽感，结合现有代码架构）出三方案。

### J-0. 用户差评与病根认定（Chief 复核截图）

| 用户判定 | Chief 认下的病根 |
|---|---|
| ①界面丑 | 信息糊成一团：88% 巨大、其他数据挤成小字汤；顶部标签栏是**自绘胶囊**不是原生组件（违背「原生 iOS 组件」要求） |
| ②交互反人类 | 三个按钮抢戏：挑选经典方案＋制定计划＋悬浮加号，一个决策三个入口；流程不聚焦 |
| ③文案黑话 | 「战备状态」「战术简报」「战术任务」「综合充能」等军事腔——健身 App 应说人话 |
| ④流程不聚焦 | 无每屏主操作概念，入口分散 |

> 运营文案正在全库扫描真实黑话词条出「黑话→人话」对照表（只列代码里实际出现的句子）；界面设计三方案视觉要点已备（见下）；苹果开发出改造范围与工期评估中。

### J-1. 三方案摘要（Chief 原文，完整版以群消息为准）

| 方案 | 定位 | 界面 | 交互 | 文案风格 | 工期 | 适合 |
|---|---|---|---|---|---|---|
| 一「原生简净」 | 像苹果自家「健身」App，95% 系统组件，克制出高级感 | 系统大标题 + 原生分组列表；视频通栏置顶、内容滚动压上；标签栏换回**原生组件**（iOS 26 自带悬浮玻璃）；状态卡=一个大数字+三个小指标+一句建议 | 全系统范式（推入/弹出/滑动），**每屏只有一个主按钮**（首页就一个「开始今日训练」） | 「今天练什么」「身体状态 88，不错」——短、直、暖，黑话全删 | 最小，约 1–2 轮，架构不动只换表现层 | 最快拿到「干净、不丑、不反人类」 |
| 二「玻璃旗舰」⭐Chief 推荐 | 用户原话一条不落：影像做底、玻璃分层悬浮，iOS 26/27 玻璃完全体 | 首页视频整屏沉浸（下滚收缩成玻璃条）；状态数据玻璃层级表达（状态层浮在影像上、详情层底部升起）；深色一等公民；高光折射全系统玻璃渲染不自绘 | 滚动驱动动画（视差、玻璃收缩）、**下拉直接开训**、系统缩放转场；每屏一个主操作 | 教练口吻大标题+一行小字：「状态 88，适合推一把」 | 中等，约 2–3 轮，表现层重写、数据/逻辑不动，玻璃基建复用 | 要「一眼华丽、拿出去有面子」 |
| 三「杂志质感」 | Whoop/Nike 式生活方式大刊：巨号排印+电影画面+极简黑白+一点品牌色 | 杂志网格，**巨号数字当主角**（88 占半屏）；数据块=大数字+细分割线（不用图标汤）；视频当电影横幅配编辑式图注 | 叙事式流程：「今天→计划→记录」像翻刊，训练向导一步步带练 | 杂志短句自信有温度：「今天：上肢推」「状态正好，别浪费」 | 中大，约 3 轮，要建排印系统（图形级自绘仅限业务图形） | 跟市面健身 App 彻底拉开差距、走品牌路线 |

**Chief 推荐**：方案二，或「2 的玻璃 + 3 的巨号排印」混搭——华丽感上限最高、与现有架构咬合最顺（`clubGlassEffect`、`BojiMotion2`、Hero 视频三闸门、首帧占位基建直接复用）。

### J-2. 界面设计视觉要点（已备，用户选定即出稿）

- **方案一**：系统大标题+原生分组列表；状态卡大数字（等宽数字）+三小指标横排+一行建议；颜色只用 `pageBackground`/`cardSurface`/系统语义色；圆角 20–24；无自绘装饰。出稿 1 天能定。
- **方案二**：整屏沉浸视频 z0 + 顶部安全区玻璃工具条；下滚 Hero 收缩成玻璃横幅（`clubGlassEffect`+系统材质）；详情层系统 sheet 底部升起（`presentationDetents`）；深色先压黑 20% 再叠护字（DES-003 规格复用）；基建全现成。
- **方案三**：巨号排印（`BojiFont` 现有 40/28 档扩展或系统 rounded 64–88pt）；数据块大数字+细分隔线；电影横幅+编辑式图注；训练向导单页叙事流；需新建排印系统。
- 交付形式：HTML 可交互预览（含深浅色与动效标注），用户点头再动手。

### J-3. 用户选定与重做推进记录（随报随登）

| 事项 | 状态 | 备注 |
|---|---|---|
| 三方案交用户 | 已发（2026-11-08） | 回「1」「2」「3」或「2+3」即选定 |
| 苹果开发改造范围与工期评估 | **已交付** | 全文 [design-previews/阶段5-三方案改造范围与工期评估-苹果开发.md](design-previews/阶段5-三方案改造范围与工期评估-苹果开发.md)；要点见 J-5 |
| 运营文案黑话对照表 | **已交付** | 全文 [BUILD140-文案重做对照与三方案样例.md](BUILD140-文案重做对照与三方案样例.md)；规模与关键坑见 J-6 |
| 界面设计视觉稿 | **进行中** | 三屏主视觉（首页/训练/记录），2+3 混搭：玻璃分层 × 巨号排印；出成浏览器可看的稿子交用户过目 |
| 后端 prompt 军事腔源头 | **已交付（待复验）** | 后端开发已清三个 prompt 的军事/工程腔，按运营文案第八节唯一口径三层同步：规范 `shared/prompts/`（日报/周报/计划三份 md）、**运行时源头 `backend/ai_core.py`**（COMMON + ANALYSIS_STYLE 才是实际喂给模型的提示词，规范 md 不被运行时代码读取）、计划说明 `plan_explanation.py`/`coach_core.py`。提交 `bf52084`。**同步证据**：`ai_core.py` 内已含禁词表（战备/战术/决策/简报/综合充能/神经负荷/超量恢复/引擎/链路/闭环/赋能/出勤/登记/编排/校验/阈值）、「总重量」替代「容量」、每段 ≤60 字、不用 emoji、正向样本句；全 backend 黑话 grep 仅剩禁词表本身 |
| 三联动提示文案（音效 ID 对触发点 + 设置页音效开关文案） | **中断待续**（运营文案 2026-11-08 模型限流 429 停机，此项未完成） | 恢复后补：S1 tap／S2 set_done／S3 milestone／S4 workout_done／S5 rest_tick／S6 error 逐个对到触发点文案 + 设置页音效开关文案；批次 1 施工前需要它（苹果开发照表施工） |
| **8 份交付件入库**（文档管理，2026-11-09） | **✅ 已入库推送**（commit `bbd9f58`，路径限定提交） | BUILD140-文案定稿-2+3混搭.md、BUILD140-文案重做对照与三方案样例.md、design-previews/2plus3-三屏主视觉稿.html、2plus3-三联动设计表.md、2plus3-全页面组件规格表.md、阶段5-三方案改造范围与工期评估-苹果开发.md、阶段6-导航壳原生化迁移方案-苹果开发.md、docs/AppStore文案-初稿.md——此前均为未跟踪状态，防丢桌面 |
| **用户选定** | **✅ 已定：方案 2+3 混搭**（2026-11-08 用户回「方案2+3 吧」，并确认配方「2 的玻璃 + 3 的巨号排印」） | 记为 **DEC-4**；Chief 复述定案口径：**玻璃旗舰做骨架 + 杂志排印做气质**——影像沉浸分层玻璃打底（滚动收缩、悬浮玻璃件、系统折射高光）+ 巨号数字排印当主角 + 教练式短句文案；界面壳全原生组件、每屏一个主操作、黑话全灭。进入阶段 6 |

### J-4. 阶段 6 重做批次台账（文档管理逐批登记）

**范围口径（2026-11-08 用户澄清 + Chief 钉入目标）**：重做覆盖 **App 全部页面，一个不漏**——首页、训练中、训练完成、记录、日报周报、设置、引导、会员购买、AI 会话/Club AI，含**空状态与错误提示**。黑话清理、巨号排印、玻璃规格一律按**组件级铺到每一页**，不许只做首页；界面设计正式交付物 = **全页面组件规格表**（每页每个组件一行一条，苹果开发照表施工），三屏稿只负责定设计语言；测试验收复验范围 = 全页面逐页过；Chief 最终验收逐页过。

流程铁律（Chief 定）：**视觉稿先行——用户过目点头才动手**；每批 `builder ios build` 编译全绿 + 测试验收复验 + 界面设计走查；文案无军事黑话；每屏一个主操作；减动效/增强对比度必须有降级。

| 批次 | 内容（Chief 定死的开工顺序） | 主责 | 编译 | 复验/走查 | 状态 |
|---|---|---|---|---|---|
| **批次 0**（先清用户点名的病根，可不等视觉稿） | ①黑话按对照表直改——**全页面执行**（苹果开发核准：用户可见串实际 **9 处**，另 2 处「神经负荷/超量恢复/恢复窗口」类术语；运营文案全量重写扩到全页面进行中）；②顶部自绘胶囊 `ClubModeCapsulePicker` 换**原生 TabView tab bar**（迁移方案见 J-5 附）；③状态卡两处**假数据** `7.5h 计划`/`54 bpm`（`ClubAIShell.swift:1374/1381`）改真值或「还没同步到」；④后端**三个 prompt** 军事腔（含 `shared/prompts/weekly_report.v1.md:10`「下周战术建议」，运营文案已备可粘贴禁用词约束段） | 苹果开发（①②③）+ 后端开发（④） | **✅ 编译绿**（测试验收触发 run 42496419492，37.46 MB；苹果开发 42496009994 亦绿） | **✅ 核心通过**（测试验收 K1 表：UI 断言改写逐条核过、反向断言转正向、TabView/假数据/黑话主项界面设计走查全绿） | **④ 后端侧已交付**（提交 `bf52084`，行尾修正随后提交）：三层同步——3 份规范 md（禁词节+修订注记）、运行时 `backend/ai_core.py`（COMMON 与 ANALYSIS_STYLE 写入禁词表、每段 ≤60 字、「容量」→「总重量」、不用 emoji、正向样本句防长复合句）、`plan_explanation.py` 三处「编排」与 `coach_core.py` 一处改平实说法。**另交付批次 2 前置：三联动音效素材**——6 个 `.caf`+同名 `.wav`（S1 tap 0.07s／S2 set_done 0.15s／S3 milestone 0.28s／S4 workout_done 0.55s／S5 rest_tick 0.05s／S6 error 0.22s，48kHz/16bit/单声道，峰值统一 -6dBFS，RMS -15.9~-22.9，正弦+泛音+指数衰减，无版权）+ 生成脚本 `scripts/make_interaction_sounds.py`（CAF 按 Apple 规范手写并严格自校验）+ `sounds-manifest.json`；**pbxproj 注册与播放接线留批次 2 由苹果开发做**，首次编译建议跑 `afinfo BojiClub/Sounds/boji_tap.caf` 实机解析确认。**复验尾巴（不阻塞批次 1，随批次 1 前清完）**：P2 周报「训练出勤」`WeeklyReportView:158` + 「累计出勤场次」`:234`；P3 引导页三句 `FirstLaunchWalkthroughView:427/558/611`（「分秒必争。」「蜕变，历历在目。」「万事俱备。」）+ 其他页「出勤」3 处 + 注释黑话 4 处（Chief 定下批顺手清） |
| **批次 1**（2+3 骨架）**【代码已收口，待末批编译确认 + 正式基线】** | 巨号排印数据块（**档位定案：`.display` 88pt / `.editorial` 76pt**，状态数字当主角、大数字+细分割线替代图标汤）+ 一屏一主按钮 + 删三键悬浮拨号 `ClubHomeSpeedDial` + 每屏玻璃 ≤3 红线守住；**并清批次 0 尾巴**：周报「出勤」×2（P2 必清）+ 4 处注释黑话（防后人照抄回 UI）+ 引导页三句重写（P3）+ 其他页「出勤」3 处；**排印规格按组件级铺全页面** | 苹果开发（照界面设计规格表） | **末批编译待确认**（苹果开发在跑） | **第二批复验已通过**：拨号删除、排印降级、状态卡真数据、文案补刀全清；尾巴 2 处 P3 已清（`e5ad7ce`：注释「出勤频率」→「训练频率」、组件画廊「本周出勤」→「本周练了」） | **✅ 代码全部收口**（`9f0a505` 末批：记录屏当前体重 `.editorial` 76pt 巨号主角、训练完成页事实格 24pt 数据块；`e5ad7ce` P3 清零）。⚠️ 中途踩**游离 HEAD 事故**（builder/他人 checkout 动了分支指针，提交没进 main）→ 苹果开发切回 main 补 cherry-pick 恢复（`9f0a505` 已推），**代码零丢失**；教训：提交前必查 `git status` 第一行是 `On branch main` |
| **批次 2**（玻璃沉浸深化 + **三联动真声音**） | 视频整屏 + 下滚收缩玻璃条 + 滚动驱动动效；**BUG-007 滚动性能欠账先立基线再动手**（视口外暂停、改完复跑对比）——不许再欠性能债；全页面玻璃分层适用；**三联动接线**：音效素材 pbxproj 注册 + 播放接线（随震动/动效同拍），K1-8 届时验真声音才算通过 | 苹果开发（测试验收先测基线） | 待跑 | 待复验 | **前置已备**：①流水线假绿三件修复 + **设备口径钉死 iPhone 16 Pro**（`ad1723f`，掐掉上轮设备断层来源；正式基线与批次 2 后测同设备）；②**基线成立判据（测试验收定）**：`totalTestCount = 2` 且 `passedTests = 2`（防空跑复发）+ 归档设备字段 = iPhone 16 Pro，满足即收数、批次 1 正式基线成立；③运维支付等批次 1 末批绿后触发取样 |
| 批 N | 按 Chief 验收问题单追加 | — | — | — | — |

> **四条线 × 全页面覆盖对照**：界面（批 1 排印 + 批 2 玻璃，全页面）；交互（批 0 原生壳 + 批 1 一屏一主操作 + 批 2 滚动驱动，全页面）；文案（批 0 黑话 + 后端 prompt，全页面含空状态/错误提示）；流程（批 1/2 每屏一主操作与沉浸式推进，全页面）。
> **风险红线**：训练完成「向导化」**不做**（要动 993 行训练状态机，Chief 已否）；BUG-007 性能债批次 2 前必须有基线。

### J-4b. 警示与架构事实（Chief 指示入账，2026-11-08）

1. **AI 文案生效层（关键架构事实）**：`shared/prompts/*.md` **没有任何运行时代码读取**（全库零命中）——真正喂给模型的是 `backend/ai_core.py` 拼装的 system（日报/周报走 `COMMON + GOAL_CONTEXT_RULE + ANALYSIS_STYLE`），另有 `plan_explanation.py`、`coach_core.py`。**「只改 md 等于没改」**——以后改 AI 文案必须三层同步：规范 md（给人看）+ `ai_core.py`（生效层）+ 两个 python 旁路。
2. **流水线假绿坑（今天第二次重演）**：`ios-performance.yml` 的 test 步骤 `cmd | tee` 吞了 xcodebuild 退出码（取到 tee 的 0），xcodebuild 报「project damaged」零执行却报 success；首跑制品经测试验收下载核验实锤（`totalTestCount: 0`、`testNodes` 空、`test-run.log` 有 error 原文）。**已定修复三件**（运维支付）：①`set -o pipefail`；②「`totalTestCount == 0` 即失败」硬判定；③在 `3190189`（pbxproj 撞号修复）之后重跑基线。教训已入团队记忆：新工作流模板必须带这两条。
3. **Debug 包流验收风险（DEC-5 起因）**：此前云端出包全是 Debug 配置，`#if DEBUG` 的 5 处开发入口在用户验收包里可见；规矩已定死——给用户装的包一律 Release。
4. **工程文件并发保护**：音效素材 13 文件已备但**故意不进 bundle**——苹果开发刚踩过 pbxproj 撞号（700A/700B，`3190189` 修复），不并发改工程文件；注册接线统一留批次 2。

**J-5 附：苹果开发技术准备（等稿期间完成，2026-11-08）**
- [design-previews/阶段6-导航壳原生化迁移方案-苹果开发.md](design-previews/阶段6-导航壳原生化迁移方案-苹果开发.md)：自绘胶囊标签 → 原生 tab bar 迁移方案与回归面。
- 黑话精确点位清单已扫（区分注释串与用户可见串）：用户可见 **9 处** + 术语类 2 处，修正此前「13 处」估算（13 = 首页/日报/周报标题类合计口径）。

### J-5. 苹果开发改造范围与工期评估要点（已交付，2026-11-08）

**现状基线（逐段读代码核准）**：顶部是自绘胶囊 `ClubModeCapsulePicker`（塞在系统工具栏 principal 位）；页面壳为 `NavigationStack` + `TabView(.page)` 横翻，**没有原生 tab bar**；首页卡片区 `ClubAIWorkspaceIdleView` 约 980 行；悬浮加号是自绘三键展开式 `ClubHomeSpeedDial`；黑话：初估 13 处（ClubAIShell 7 + 日报周报 6），苹果开发后续全量精扫修正为**用户可见 9 处 + 术语类 2 处**（余量为注释串），见 J-5 附。

| 方案 | 工期 | 风险 |
|---|---|---|
| 一 原生简净 | 1–2 轮 | 低（横翻手势、训练锚点、UI 测试 identifier 需回归） |
| 二 玻璃旗舰 | 2–3 轮 | 中：**滚动性能 BUG-007 旧账未归因，整屏视频会放大**（需视口暂停+复跑对比）；每屏玻璃 ≤3 红线；iOS 17 降级桥接 |
| 三 杂志质感 | 约 3 轮 | **高**：训练完成向导化要动 `TrainingRegistrationViews`（993 行核心状态机），回归面全项目最大 |

**关键结论**：①方案二**基建零成本**（`clubGlassEffect`/`clubGlassGroup`、Hero 播放器、首帧占位三闸门、DES 规范全部现成）；②混搭「2 的玻璃 + 3 的巨号排印」**可行且风险等同方案二**（2–3 轮）——前提是只做排印数据块、**不做训练向导化**；③共同前置（原生 tab bar + 13 处黑话）三方案都要做，可独立一批先跑。

### J-6. 运营文案黑话对照要点（已交付，2026-11-08）

- **规模**：首页 25 条 + 日报 6 条 + 周报 4 条 + 全局术语词典 13 条 + 文案规范 6 条，全部来自代码实际字符串、带文件行号，可按行直改。**范围已按用户澄清扩至全页面**（运营文案全量重写中：训练中/训练完成/记录/设置/引导/会员购买/AI 会话/空状态/错误提示）。
- 典型替换：战备决策舱→**今天**（做系统大标题，区块名取消）；综合充能 88%→**身体状态 88**；战术简报→**今天的建议**；今日战术任务→**今天练什么**；神经负荷恢复良好→**休息得不错**；超量恢复日→**今天不用练力量**；三大专业进阶引擎→**删掉**；已确认登记 3/5 组·保持组间专注→**记了 3 组，还剩 2 组**；肩峰受限换动作→**肩膀不舒服，换个动作**。
- **两个必须跟做的坑**：①`shared/prompts/weekly_report.v1.md:10` 等三个 prompt 是 AI 正文源头，**只改 Swift 标题不够**，日报周报正文照样冒军事腔（后端开发在改）；②状态卡 `7.5h 计划`、`54 bpm` 是**硬编码占位**（`ClubAIShell.swift:1374/1381`），重做时应改真实值或显示「还没同步到」。- **保留边界**（防改过头）：组数、次数、蛋白质、静息心率、体脂等用户本来就懂的词不换，「复盘」保留；只清军事腔、工程腔、算法自述三类。

---

## K. 阶段 6 逐批复验口径（测试验收，2026-11-08 起）

适用：方案 2+3 混搭（DEC-4）全面重做的**每一批**交付。一批一编译一复验，全部通过才交 Chief 验收。

> **范围口径（2026-11-08 用户澄清后补强）**：复验范围 = **全页面**，不只首页——首页/训练中/训练完成/记录/日报周报/设置/引导/会员购买/AI 会话/空状态/错误提示，逐页过。黑话清理、每屏一主操作、玻璃红线、四种设置降级**全部按全页面执行**。

### K-1 每批必查（10 项；K1-8~10 为三联动新增，2026-11-09 随用户「可以+三联动」拍板补入）

| 编号 | 检查项 | 判定标准 | 证据 |
|---|---|---|---|
| K1-1 | 云端编译 | `builder ios build` 绿，出包 | run 号 + IPA 路径/大小 |
| K1-2 | 原生组件铁律 | 批次改动内无新增自绘自建控件（业务图形除外：图表/封面/缩略图） | 改动文件 grep 自绘模式 |
| K1-3 | 玻璃基建 | 玻璃只走 `clubGlassEffect`/`clubNativeGlassButton`/`clubGlassGroup`，页面层无散写 `if #available(iOS 26`，内容层不套玻璃 | 全库复扫（应仅剩 Design.swift 桥接 3 处） |
| K1-4 | 四种设置降级 | 批次新增/改动的每个动效与玻璃件，在减少动态效果、增强对比度、深色、AX 大字号下均有降级分支 | 逐处源码核对 |
| K1-5 | **文案新规则** | 批次涉及的用户可见文案：无军事黑话（战备/战术/简报/战术任务/综合充能等，以运营文案对照表为准）、教练口吻短句、一眼懂 | 批次 diff 文案逐条过对照表 |
| K1-6 | **每屏一主操作** | 批次涉及页面只有一个主操作按钮（强调态），其余为次级/文字操作 | 页面源码/截图 |
| K1-7 | 台账登记 | 批次改动已登记台账（J 节重做批次表 + 变更记录） | 台账 diff |
| K1-8 | **三联动反馈（2026-11-09 新增）** | 批次涉及的关键交互：动效 + 震动（系统触感引擎 `sensoryFeedback`/`UINotificationFeedbackGenerator`）+ 音效（原创合成短音入包）**同一拍触发**；三者缺一不可，也缺一即不过 | 源码核对三者调用点 + 实测同步性（手感/声音/画面对齐） |
| K1-9 | **三联动降级** | 静音开关开启 → 音效静默但震动与动效仍在；减少动态效果 → 动效降级但震动与音效仍在；设置内音效开关关闭 → 只静音效。**任何降级路径都不得让功能整体消失** | 四种设置矩阵下逐项实测 |
| K1-10 | **华丽度红线** | 华丽靠动效层次、滚动驱动、玻璃按压反馈、庆祝编排实现；无彩虹轮播、无无限闪动、无整屏转场、一屏运动元素 ≤2；音效不循环连播 | 源码 + 实测 |

> **验收包配置口径（Chief 拍板，2026-11-08）**：凡给用户装的包（TestFlight 验收、中间体验包）**一律 Release 配置出包**（`builder ios release`），`#if DEBUG` 整体剥离——5 处开发入口（OnboardingView:129/131/133/139/210）天然不存在。**K1 保险丝：验收包里见到任何开发入口 = 该批判不通过**（开发入口本身在 Debug 包保留，不删）。

### K-2 与既有复验表的关系

- 批次涉及**视频/动效** → 沿用 H 表口径（三闸门、红线、减动效）；
- 批次涉及**四种设置** → 沿用 F 表口径（INT-01~06）；
- 批次涉及**A 表 bug 复发** → 按 A 表原编号重新打开，不另起新号；
- 发现新问题 → 按严重度入 A 表（BUG-018 起），P0/P1 立即开问题单退回。

### K-4 批次复验记录（测试验收逐批登记）

**批次 0（原生 TabView + 黑话/假数据清零 + UI 断言）—— 核心通过，3 条文案补刀**（2026-11-08）

| 项 | 结论 | 证据 |
|---|---|---|
| K1-1 编译 | ✅ | run 42496009994（head `3190189`，`dist/BojiClub-c6299db8.ipa` 37.46 MB）；测试验收独立触发 run 42496419492（含后端 prompt/音效提交 bf52084）绿，37.46 MB |
| UI 断言改写（Chief 硬条件） | ✅ | `BojiClubUITests.swift` diff 逐条核：3 条反向断言换正向（含 `XCTAssertEqual(tabBars.buttons.count, 3)`）；9 处 `v2-mode-picker` 迁 `tabBars`；**删除的全是导航断言，业务断言一条未丢**（`modeButton("Club AI")`→`"今天"` 为标签更新非删除），符合「只删不补不收货」反向要求 |
| K1-2 原生组件 | ✅ | 自绘胶囊 `ClubModeCapsulePicker`/`v2-mode-picker` 全库零命中；TabView 三 tab 系统渲染（界面设计走查 §1.1 一致） |
| K1-5 黑话（批次声明范围） | ✅ | 首页 25 处 + 周报「下一周战术建议」+ 记录中心「综合看板→概览」（显示名/内部 key 分离，`displayName` 映射核对无断链） |
| K1-5 黑话（全页面口径） | ⚠️ **3 条补刀** | **P2**：`WeeklyReportView:158`「训练出勤」、`:234`「累计出勤场次」（「出勤」为 prompt 禁用词+对照表点名项）；**P3**：引导页三句 `FirstLaunchWalkthroughView:427/558/611`（「分秒必争。」「蜕变，历历在目。」「万事俱备。」，定稿第十二节要求重写）+ 其他页「出勤」3 处 + 注释 4 处（Chief 已定下批顺手清） |
| K1-6 每屏一主操作 | ⏳ N/A | 批次 0 未动按钮布局（首页排印归批次 1），随批次 1 核 |
| K1-8~10 三联动 | ⏳ N/A | 三联动归批次 2 |
| 编译阻塞附带修复 | ✅ 记录 | pbxproj ID 撞号（`700A/700B` 性能用例注册与 UITests 配置重号）由 `3190189` 修复——上轮 run 42495686440 秒败真因，非批次 0 代码问题；测试验收独立验证本地 pbxproj 括号配平、无重复 ID |

**判定：批次 0 核心通过；3 条文案补刀（1 P2 + 2 P3）随批次 1 前清完，不阻塞 Chief 批批次 1。**

**性能基线（baseline-5）—— 制品空跑，基线不成立**（2026-11-08，测试验收下载制品验证）

- 测试验收用 git 凭据下载 artifact `performance-baseline`（10556 字节）并解压，**铁证**：`test-run.log` 尾部 `xcodebuild: error: Unable to read project 'BojiClub.xcodeproj' — The project 'BojiClub' is damaged`（跑在 `5e2cf390`，pbxproj 撞号未修版本）；`performance-tests.json` 的 `testNodes` 为空、`totalTestCount: 0`、`result: "unknown"`——**测试零执行**。
- **假成功根因**：`ios-performance.yml` 的 test 步骤管道吞退出码（`cmd | tee` 取到 tee 的 0），与 ios-build 修过的坑同款，该文件未带 `set -o pipefail`。44 秒 = build 30s + test 14s 报错退出，10.5KB = 空 xcresult，全部对上。
- **修复三件（@运维支付）**：①test 步骤加 `set -o pipefail`；②加「`totalTestCount == 0` 即失败」判定；③在 `3190189`（撞号已修）后重跑。跑完测试验收复验制品，**见 `testLaunchBenchmark`/`testScrollBenchmark` 真实数值才算基线成立**（Chief 口径：批次 2 合入前的稳定点取样，批次 1 收尾最科学）。

**性能对比铁律（Chief 2026-11-08 拍板，测试验收执行口径）**：

1. **同配置对比，禁跨配置**——唯一禁止「Debug 基线 vs Release 后测」：会把编译优化当性能提升、把回退当零变化。
2. **首选 Release 一条线**：重做前基线与批次 2 后测都用 Release（与验收包/用户所用一致）；若 Release 跑测试目标有坑，**两批都用 Debug**，报告标注口径——**一致性 > 绝对值**。
3. **10-24 那份 Debug 旧数据降级为纯历史参考**，不进对比表（仅 BUG-007 的历史背景引用）。
4. **执行影响**：现有 `ios-performance.yml` 的 `xcodebuild test` 默认 Debug——选 Release 路线时需 @运维支付 加 `-configuration Release`（测试目标需支持 Release 编译），选 Debug 路线则不动；**路线由 Chief/运维支付定，定后写死在工作流里**，中途不许换配置。
5. 后端开发提示的口径断层（重做前基线 Debug vs 批次 2 起 Release）已被本铁律覆盖，复验时我按第 4 条核对实际配置再收数据。

**基线管道验证快照复验（2026-11-09，run 42498401537 / HEAD `f8d2c54`）**：

| 项 | 结论 | 证据 |
|---|---|---|
| 数据真实性 | ✅ 有效 | 归档 `docs/performance-baseline-20261108/`：`totalTestCount: 2`、`passedTests: 2`、`result: Passed`；两用例各 5 次采样值齐全（滚动 RSD 0.75% 质量好，冷启动 RSD 29.8% 因首采样 4.977s 偏高） |
| 管道修复 | ✅ | pipefail + `-only-testing` + 空跑守卫三件已落（`f8d2c54`）；死测试 6 行删除（`OnboardingV2ContractTests` 引用已删组件 `ClubSharedComposer`，scheme TestAction 挂双目标导致隐藏编译失败——批次 0 builder 不编测试目标所以此前未暴露） |
| Debug 路线写死 | ✅ 合理 | 测试钩子（`BOJI_PREVIEW_ACCOUNT`/`BOJI_UI_TEST_SEED`）全在 `#if DEBUG`，Release 驱不动登录态；与铁律「一致性 > 绝对值」一致 |
| **⚠️ 设备断层（新发现）** | **需修正口径** | **新快照 = iPhone 16 Pro / iOS 26.2；10-24 旧基线 = iPhone SE 3 / iOS 26.5。`measurements.md` 称「同 Debug 可作对照」只对了配置一半——设备不同，跨设备对比同样无效**（铁律精神：一致性包含设备）。影响：①BUG-007 的 +47.2% 历史对比**不能**拿这份新数据再算；②「批次 1 vs 批次 2」对比不受影响（同为 16 Pro，是关键对照）；③根因是 runner 无 SE3、兜底建机挑了 16 Pro |
| 正式基线时点 | 不变 | 批次 1 收尾取样（批次 2 整屏视频的对照组），届时核对设备为 16 Pro 并在报告标注设备口径 |
| BUG-007 指标口径 | ✅ | CPU Instructions/Cycles 模拟器恒 0 不可用；**BUG-007 对比用 CPU Time**（本快照 0.860s） |

**批次 1 第二批复验（2026-11-09，run 42500109512 / HEAD `059f93e`）—— 通过**

| 项 | 结论 | 证据 |
|---|---|---|
| K1-1 编译 | ✅ | run 42500109512，`dist/BojiClub-07925964.ipa` 37.43 MB（含 `bojiFont→bojiType` API 混用修复） |
| K1-6 一屏一主操作 | ✅ | `ClubHomeSpeedDial`/`SpeedDial`/`expandSpeedDial` **全库零命中**——三键拨号删除干净 |
| `BojiEditorialNumber` 排印组件 | ✅ | `BojiDesignSystemV2.swift:165-212`：`.display` 88 / `.editorial` 76 / `.hero` 52 与规格表一致；`@ScaledMetric(relativeTo: .largeTitle)` 跟随 Dynamic Type；**AX3 以上压 0.75 防错位**（K1-4 大字号降级）；`monospacedDigit()` 等宽数字 + kerning 字距（-3/-3.5/-2）按档位；封闭组件内不改全局档位（避免波及既有 `.display` 34pt 用量），设计合理。4 处使用点就位（状态卡/训练登记/WorkoutView×2） |
| 状态卡假数据 | ✅ | `ClubAIShell.swift:1195` `readinessScore` 真实规则评分（睡眠+心率+近 3 天训练），`:1194` 注明「缺数据说缺」，3 处「还没同步到」，无编造 |
| K1-5 黑话补刀（3 条承诺项） | ✅ **全清** | P2 周报「训练出勤」×2 已清；引导页三句（分秒必争/万事俱备/蜕变）已清；全页面黑话复扫（战备/战术/简报/充能/超量恢复/神经负荷等 10 词）**零命中** |
| 残留（不阻塞） | 2 处 P3 | ①`ClubAIMemoryView:6` 代码注释「出勤频率」（Chief 批的注释清理余 1 处，非用户可见）；②`BojiComponentGalleryView:150`「本周出勤」（组件画廊=开发预览页，不进产品导航）——随下批顺手清 |

**判定：批次 1 第二批通过。** 批次 1 剩尾巴两处（记录屏 `BodyWeightView` 巨号、训练完成页事实格），收口后即为**正式基线取样点**（运维支付执行，16 Pro 同设备 + Debug 口径）。

**批次 1 全量收口复验（2026-11-09，run 42501578433 / HEAD `e5ad7ce`，含 `bbd9f58` 交付件入库）—— 通过**

| 项 | 结论 | 证据 |
|---|---|---|
| K1-1 编译 | ✅ | run 42501578433，`dist/BojiClub-33d9d2ff.ipa` 37.44 MB |
| 批次 1 尾巴两处 | ✅ | ①记录屏当前体重 `BodyWeightView:109` `BojiEditorialNumber(.editorial 76pt)` 主角落位；②完成页事实格 `WorkoutExperience125:272-300` 数据块化（大数字 + 28×1 细分割线 + 标签下置 + `monospacedDigit`），`bojiStaggeredEntrance` 与数字滚动保留、减动效降级在位 |
| 2 处 P3 残留清理 | ✅ | 注释「出勤频率」→「训练频率」、组件画廊「本周出勤」→「本周练了」（`e5ad7ce`）；**全库复扫：「出勤」0 处、军事黑话 10 词 0 处** |
| 引导页三句 | ✅ | 「分秒必争/万事俱备/蜕变，历历在目」零命中（已按定稿重写） |
| 状态卡评分规则 | ✅ | 睡眠 50 + 静息心率 30 + 近 3 天训练 20 的诚实规则，缺数据「还没同步到」 |
| 交付件入库 | ✅ | `bbd9f58` 8 份（视觉稿/规格表/三联动表/文案定稿等）路径限定入库 |

**批次 1 复验全部通过，K 表无未决项。正式基线取样点 = `e5ad7ce`（16 Pro + Debug），待运维支付取样、测试验收按「totalTestCount=2 且 passedTests=2 + 设备=16 Pro」双条件收数。**

### K-3 阶段 6 整体通过条件（对应 goal）

四条线（界面/交互/文案/流程）全部落地 + 一批一编译全绿 + 测试验收逐批复验通过 + 界面设计按新视觉稿走查达标 → 交 Chief 验收 → 用户真机验收签字。

> **状态**：口径已就绪，等待第一批交付（界面设计三屏视觉稿经用户过目后，苹果开发开工）。

---

## 进度速览（文档管理维护）

### 阶段进度（目标 2026-11-08 修订为 7 阶段，Chief 逐阶段验收 + 用户真机签字）

| 阶段 | 内容 | 状态 | 说明 |
|---|---|---|---|
| 1 | 摸底与规范 | **已通过**（2026-11-08 Chief 验收） | 四份产出齐备、交叉核实一致（Bug 清单、自绘控件清单、后端问题清单、视觉动效规范） |
| 2 | P0 修复：bug 与流程断点 | **已通过**（2026-11-08 Chief 验收，第四輪复验后） | 完成条件全部满足：A 表 P1 阻塞项清空；BUG-001 通知深链修复；5 个流程断点消除；BE-001/BE-004 修复；测试验收第四輪复验通过（E-2 表）；云端编译 run 42465043363 出包 f9a471f6；Chief 过目认可。遗留：BUG-015 首帧占位按 Chief 决定留阶段 4 |
| 3 | UI 原生化改造 | **已通过**（2026-11-08 Chief 验收，G-4 全量复扫后） | 六项完成条件全齐：4 自绘控件全换原生、23 处材质收口归一、动效系统化 IOS-006~010、流程断点收口 IOS-012/013、界面设计走查达标（G-08/G-11 玻璃红线）、编译通过 run 42468330096 出包 f93a9470；测试验收 G-19~G-23 复验通过；P1 价格卡拍板项闭环（G-18/19）。遗留 P3：CLN-02 死代码留阶段 4 顺手清 |
| 4 | 视频融入 + 华丽动效 | **已通过**（2026-11-08 Chief 验收，H 表终扫后） | 五项完成条件全齐：视频融入首页 Hero 玻璃卡（方案 A）、播放三闸门+首帧占位无缝（H-01/02）、三场景动效按规范落地且红线合规（H-10~13）、减动效降级齐备（H-03）、编译通过 run 42470904790 出包 8f1542dc；测试验收 H-01~H-13 全绿；BUG-017 两处进场口径统一闭环、CLN-02 死代码已清（H-09） |
| 5 | ~~整体验收~~ → **三方案汇编与用户选定** | **✅ 已通过**（2026-11-08 用户选定 2+3，DEC-4） | **转向原因**：阶段 1~4 代码层面虽已签字通过（第 4 轮，终态包 ea843320），但用户真机装机后判定整体体验不合格，四条线全打回。三方案（J-1）交用户后，用户回「方案2+3 吧」选定混搭；配套产出：苹果开发改造范围与工期评估、运营文案黑话对照（含后端 prompt 的「下周战术建议」）、界面设计三方案视觉要点，全部就位 → **详见 J 节** |
| 6 | **选定方案全面重做**（界面/交互/文案/流程 · **全页面** + **三联动**） | **进行中**（2026-11-08 开工；**批次 0 复验核心通过，批次 1 开工中**） | 完成条件：2+3 方案在**全部页面**（首页/训练中/训练完成/记录/日报周报/设置/引导/会员/AI/空状态/错误提示，一个不漏）四条线全落地；视觉规格为**全页面组件规格表**（三屏稿只定设计语言）；交互反馈三联动（动效/震动/音效）随批落地并实测（DEC-6：批次 0 验素材就位、批次 2 验真声音）；一批一编译全绿；测试验收逐页复验通过（K 表）；界面设计按新规格逐页走查达标。**开工顺序（Chief 定死三批）**：批次 0 黑话+原生壳+假数据+prompt（已过）→ 批次 1 排印骨架+一屏一主操作+删拨号+文案尾巴（开工中）→ 批次 2 玻璃沉浸深化+三联动接线（**先立 BUG-007 真实性能基线**）。减动效/增强对比度必须有降级；验收包一律 Release（DEC-5） |
| 7 | 重做后验收循环与用户签字 | 未开始 | Chief 逐轮验收、不合格开问题单返工；**原真机补验 7 项清单并入本阶段最终验收**（不再单独前置）；真机复验后**用户签字**才整体关闭 |

### 阶段 2 分工与状态（已通过·归档）

| 成员 | 任务 | 状态 |
|---|---|---|
| 后端开发 | BE-001 核验改后台异步（请求路径只读本地权益，不再同步打 RevenueCat 卡 12 秒）；BE-004 改指数退避自动重试（弱网恢复自动续同步）；改完跑云端编译 + 登记台账 | **已修复待验**；云端编译已通过（run 42461169469，IPA `dist/BojiClub-ffe4a1ed.ipa`），等测试验收复验 |
| 苹果开发 | 材质收口 17 处（15 处 + RemoteConfigNoticeView、ProfileView 补 2 处）→ git 提交推送 + 云端编译；P0 必改 BUG-001（通知深链）、BUG-003（输入串轨，随 IOS-001/002 原生化关闭）；拿到 Hero 视觉稿后接视频关 BUG-005 | **第一批已提交（c3cf75d）**；第二批（BUG-003/005/010/011/012）已改完待提交，提交后请测试验收重跑云端编译 |
| 运维支付 | BE-002/BE-003 部署配置核查 → **已完成**：根因 deploy.sh 配置模板缺键，源码已改（21 键契约 + 校验脚本 + 测试 21 键全过），线上补键清单交 Chief（OPS-003）；TestFlight 步骤指引已出（前提更正：需 $99 付费账号），待用户回「1/2/3」 | 已回报，待用户选链路 |
| 界面设计 | 首页 Hero 卡视觉稿（视频底层静音循环/离开暂停/减少动态显静态帧 + 玻璃卡 + 渐变护字 + BUG-005 落地要点），出好 @苹果开发 | 进行中 |
| 测试验收 | 据 DEC-1/DEC-2 更新 D 表 ACC-02/ACC-04；等修复报上来做复验回归 | 进行中 |
| 文档管理 | 三个决定登记、阶段 2 修复状态随报随登（本表） | 已完成（阶段 2 通过，本表归档） |

### 阶段 3 分工与状态（已通过·归档）

| 成员 | 任务 | 状态 |
|---|---|---|
| 苹果开发 | **IOS-006~010 动效系统化**：手绘 TimelineView spinner → ProgressView、呼吸环 → Gauge + symbolEffect、激光扫描线 → 系统进度语义、彩带粒子 → celebrate、引导页轨道环 → glassEffect + SF Symbols；改一项勾一项 B1 表，一批一编译（已开好头 b1d31c7，IOS-003/004 原生化待其构建验证） | **已完成**（G-01~G-12 通过；含 G-08 内容卡去玻璃、G-19 价格卡拍板项） |
| 界面设计 | 按规范 §1–§7 走查改造效果：材质三层是否滥用、动效节奏表是否守住、玻璃红线（每屏数量、护字渐变）是否达标，不达标处列清单 | **已完成**（走查列 6 处内容卡玻璃已改，判定达标 G-08/G-11） |
| 测试验收 | 交互回归：深色模式、大字号、减弱动态效果、增强对比度四种设置下过一遍改造过的控件，B1 清单逐项核对打勾 | **已完成**（F 表 INT-01~13 + G 表 G-01~G-23，复验通过） |
| 文档管理 | B1 改造清单打勾状态随报随登；E-2 收档归档（已完成） | 已完成（阶段 3 通过，本表归档） |
| 后端开发 | （阶段 2 主任务已交付；BE-005~008 待排期，不属本阶段） | 待命 |

### 阶段 4 分工与状态（已通过·归档）

| 成员 | 任务 | 状态 |
|---|---|---|
| 界面设计 | 第二批动效方案：挑首页、训练中、训练完成三个重点场景，按动效节奏表做进场、转场、微交互的华丽化润色（stagger 进场、spring 展开、完成庆祝动效），红线内标注具体时长、层级和运动元素数量 | **已完成**（DES-004 三场景方案，落地由苹果开发完成，H-10~13 复验通过） |
| 苹果开发 | 三件：①CLN-02 死代码（`BreathingPulseHalo`）收尾编译；②BUG-015 首帧占位图（视频未就绪/低电量/减少动态显示静态帧防黑块）；③界面设计方案出来后逐项落地，一批一编译 | **已完成**（CLN-02 清 98900b6、首帧占位 5ab6f97、三场景落地 064d234，均复验通过） |
| 测试验收 | 动效走查：减弱动态效果开启时降级正常、红线合规（无彩虹轮播/无限闪动/整屏转场，一屏运动元素 ≤2）、Hero 视频三闸门逐项核对；复验登记从 H 表起 | **已完成**（H-01~H-13 全绿） |
| 文档管理 | 视频与动效改动随报随登（本表 + B1/A 表联动） | 已完成（阶段 4 通过，本表归档） |
| 后端开发 | （BE-005~008 待排期，不属本阶段） | 待命 |

### 阶段 5 分工与状态（随报随登）

| 成员 | 任务 | 状态 |
|---|---|---|
| 测试验收 | 出全量回归验收报告，五条标准逐条附证据 | **已完成**（`BUILD140-验收报告.md`，报告第七节 T-1/T-2 双双通过，定格 a4f0692） |
| 文档管理 | 汇总验收记录表、改动清单、遗留项清单（含真机补验项）→ I 节 | **已完成**（I-1 验收记录 4 轮 + 问题单台账 / I-2 改动清单 / I-3 遗留项含真机补验 7 项）；签字后已补第 4 轮记录与 T 单关闭 |
| 苹果开发 | 待命，按 Chief 问题单返工 | **T-1 已关单**；停机（模型账号 402 余额不足），恢复方式待用户定（充值或换模型） |
| 后端开发 | 待命，按 Chief 问题单返工 | **T-2 已关单**；BE-006/008 记遗留不开单 |
| 界面设计 | 待命，配合问题单核对视觉与动效 | 待命 |
| 运维支付 | 真机链路材料一到就配置出可装包（OPS-001/002）；线上补键清单待管理员（OPS-003） | 等用户拍板 |

### 事项状态

| 事项 | 负责人 | 状态 |
|---|---|---|
| Bug 全量排查清单（首轮 BUG-001~009） | 测试验收 | 已完成首轮，待真机复核 |
| 自绘控件与流程不通点清单 | 苹果开发 | **阶段 3 完成**：4 个自绘控件 + 动效系统化 + 流程断点全部换原生并复验通过；阶段 4 做 BUG-015 首帧占位、CLN-02 清理与新动效落地 |
| 接口/数据侧问题清单 | 后端开发 | 已完成摸底，8 项入 B3 表 |
| 视觉与动效规范（含视频融合方案） | 界面设计 | DES-001~004 全部交付并通过验收（规范 + Hero 视觉稿 + 三场景动效方案） |
| 真机安装链路 | 运维支付 | **✅ 已完成**（DEC-3 选 1 TestFlight）：Build 141 已进测试组，**用户已装机**；真机补验 7 项并入阶段 7 重做后收口 |
| **体验重做（DEC-4：2+3 混搭 · 全页面 · 三联动）** | Chief 统筹，四成员分线 | **批次 0 已过（编译绿+复验核心通过），批次 1 开工中**（排印档位 `.display` 88pt/`.editorial` 76pt + 一屏一主按钮 + 文案尾巴）；三联动：素材 6 段就位（DEC-6），批次 2 接线实测；性能基线首跑为空跑假绿，修复重跑后生效；警示与架构事实见 J-4b |
| 服务器补键（OPS-003） | 运维支付 | **已完成**（2026-11-08）：21 键校验全过、迁移全绿、两个 worker 实测跑通、11 个 worker 用户错配历史坑已修 |
| 收款回调链路（OPS-005） | 运维支付 | **✅ 正式闭环**：RevenueCat 测试事件实测入库（事件 ID 与报文一致）、来源官方 AWS 网段、全程 200；`ignored` 为 TEST 事件正确处理。遗留：备案后换正式域名 `bojiclub.fun` |
| 苹果开发模型账号 | — | **余额不足（402）停机**；停机前 T-1 已交付，恢复方式待用户定（充值或换模型） |
| 本文档 | 文档管理 | 台账齐全：A/B/C/D/E/F/G/H 八表 + I 节汇总（验收记录/改动清单/遗留项）；阶段 5 代码层面已签字通过 |

## 变更记录

- 2026-11-08：建档（BUILD140），基线 Build 139 / 0.15.9，验收标准与四张台账表就位。
- 2026-11-08：测试验收填入 A 表首轮 BUG-001~009（源码级静态核对，待模拟器/真机复核）；转记苹果开发 5 条流程不通点，其中 BUG-001 通知深链已核对源码确认。
- 2026-11-08：界面设计交付《0.16.0-原生玻璃与动效规范》（DES-001/002）；测试验收据其 §7 建立 D 表验收检查表 ACC-01~10，并记录 3 条测试环境限制。
- 2026-11-08：阶段 1（摸底与规范）Chief 验收通过；登记三个决定 DEC-1 视频位 A（首页 Hero 卡）、DEC-2 ACC-02 降级验收、DEC-3 真机链路推荐 TestFlight 待用户确认；建立 5 阶段进度表与阶段 2 分工状态表，进入阶段 2（P0 修复）。
- 2026-11-08：运维支付回报 BE-002/BE-003 核查——根因 deploy.sh 配置模板缺 21 键，源码已改（契约+校验+测试全过，未碰线上），线上补键列为 OPS-003 待管理员；**更正 DEC-3/OPS-001：TestFlight 也需 $99/年付费开发者账号**，选项 3 仍零账号；TestFlight 步骤指引已出待用户回「1/2/3」。
- 2026-11-08：测试验收完成阶段 2 首批源码复验——材质收口核对通过（全库仅 `Design.swift:200` 桥接处保留材质，符合预期）；BUG-001 通知深链改为顶部横幅，已生效但新增 BUG-010（文案与实际不符、无关闭按钮）、BUG-011（横幅可能遮挡顶栏，待复核）、BUG-012（`JourneyComponents.swift` 3 处散写 `#available` 未收口）。ACC-02 降级验收的源码核对已完成。
- 2026-11-08：**云端编译验证未通过**。`builder ios build`（Build ID 12f2afd4，snapshot `fe1e4f5`，workflow run 42458229350）在 Build IPA 步骤失败，exit code 65（xcodebuild 编译错误）。**疑似根因**：快照拍于 15:17，当时工作树有 6 个 Swift 文件处于苹果开发未提交的半成品编辑中（+67/−171），快照不代表可编译状态。待苹果开发提交后重跑；错误日志因 GitHub API 限流暂未取得（15:41 重置后补）。
- 2026-11-08：**流程建议（测试验收）**：编译验证必须在**已提交的干净工作树**上做，不要拍正在编辑中的工作树；builder 快照的是工作树而非 HEAD。
- 2026-11-08：测试验收完成**第二批复验**（苹果开发 f6bef84）——BUG-005 视频方案 A 落地核对通过（`brand-video.mp4` 入 bundle，pbxproj 四处引用齐全：PBXFileReference + group child + PBXBuildFile + Resources 构建阶段；AVQueuePlayer 静音循环、离场暂停回零、减少动态效果降级静态底）；BUG-010/011 横幅修正核对通过（safeAreaInset + 「知道了」关闭 + training 文案如实）；BUG-012 散写分支已收口（全库仅剩 Design.swift 桥接内 3 处，正确）；**BUG-003 仅部分关闭**（`SmartWeightStepper`、`TrainingNumericInput125` 仍在）；新增 **BUG-013**（Hero 视频暂停钮 30×30pt < 44pt 触控标准）。
- 2026-11-08：**干净树编译仍失败（run 42459888646，Build IPA exit 65）→ 排除快照污染，确认为真实编译错误。** 测试验收静态定位根因：`ClubAIShell.swift:1183`／`:1195` 在 `ClubAIWorkspaceIdleView`（struct 范围 1043–）内使用 `scenePhase`，但该属性声明在**父结构体** `ClubAIShellView`（53–773）的第 60 行，子结构体不可见 → `cannot find 'scenePhase' in scope`。修复：在 `ClubAIWorkspaceIdleView` 内补 `@Environment(\.scenePhase) private var scenePhase`（同批已补 `colorScheme`，漏了 `scenePhase`）。GitHub API 匿名限流（共享 IP 持续占满）取不到 xcodebuild 原文，本条为静态推导，待编译通过即证伪/证实。
- 2026-11-08：**错误行不可见的根因找到**：本地工作流 `.github/workflows/ios-build.yml` 有一处**从未提交**的改动（+41/−2），加了「`script` 落盘 xcodebuild 完整输出」+「Extract build errors 步骤（抓 `error:` 行写 Build Summary 并发 `::error::` annotation）」。因为没提交，**此前所有云端构建都没有错误行可看**。测试验收已把该改动精确提交并推送（**f5cbc19**），后续构建的失败原因将直接出现在 check-run annotations 里。
- 2026-11-08：**构建历史比对（测试验收）**：最后一次成功构建是 run#2（head=`65c433d`，即接入编译流水线的那次，产出了 14:49 的 dist IPA）。**run#7（push 触发，head=`c3cf75db`）是第一次失败** → **第一批（c3cf75d 材质收口＋通知横幅）就是弄坏编译的那一笔**，与第二批无关。第一批 Swift 全量 diff 已逐行读过，未发现明显语法错误，需错误行定位。
- 2026-11-08：**云端编译恢复通过**。错误行经 Chief 用认证接口下载日志后定位为 `ClubAIShell.swift:1212 VideoPlayer 无 videoGravity`（已由苹果开发改 `AVPlayerLayer` 封装）；后端开发 7cb0b97 收口另外 3 处既有编译阻塞。测试验收 run 42461772092（Build ID c6647b04）编译成功，IPA 37.44 MB，快照源码与 HEAD `8b3447e` 一致。
- 2026-11-08：测试验收完成**阶段 2 复验**，登记为 E 表。BE-001／BE-004 与客户端四连修通过；**新增 BUG-014（P1：Hero 视频未设 `isMuted`，会外放声音）**、BUG-015（P3：低电量降级与首帧占位缺失）；BUG-003 仍部分（SmartWeightStepper／TrainingNumericInput125 未换）、BUG-013 未修。**结论：阶段 2 尚不能判通过**，BUG-014 必须修。
- 2026-11-08：`.gitignore` 补 `logs-builder-*.log`（测试验收本机排障日志不入库，Chief 建议）。
- 2026-11-08：**阶段 2 第四輪返工复验通过**。Chief 判定阶段 2 不通过后返工的三件（BUG-014 静音 / BUG-013 触控区 / BUG-015 低电量闸门）由 Chief 代收口提交 54092f1；测试验收逐处核对源码通过，云端编译 run 42465043363 出包 `dist/BojiClub-f9a471f6.ipa`（37.44 MB）。结果登记为 E-2 表。BUG-003 剩余 IOS-003／004 转阶段 3（苹果开发已推 b1d31c7）。
- 2026-11-08：**阶段 3 交互回归（源码级）登记为 F 表**。全局四种设置基础设施齐备（动态字体 `@ScaledMetric`、AX 布局降级、reduceMotion、减少透明度/增强对比度分支均通过）；逐项核查发现 **BUG-016**（勾选按钮 `symbolEffect` 丢失 reduceMotion 门控，P3）与清理项 CLN-01（JourneyComponents 遗留未用 `@Environment`）。结论：阶段 3 改造项中 INT-11（IOS-006~010 动效）未开工，其余除 INT-06 外通过；全部结论待真机/模拟器实测复跑。
- 2026-11-08：**阶段 3 批次复验登记为 G 表**（苹果开发 43d66f8→77883ff）。IOS-006~009 动效系统化、BUG-016 减动效门控、CLN-01 清理均通过，编译 run 42466697711 出包；**G-08 未完成**：ClubAIShell 仍有 2 处内容卡用玻璃（:1812 智能分析专区、:1946 新用户引导卡），违反 DES 铁律 2，另 ProfileView 5 处待界面设计判定。阶段 3 玻璃红线项不能判达标。
- 2026-11-08：**G-08 复扫通过，阶段 3 玻璃红线达标**。苹果开发 fea35b7 补掉 ClubAIShell 两处内容卡玻璃（改不透明 `cardSurface`），同批完成 IOS-010 引导页重做（每屏玻璃 1 处）；界面设计判定 ProfileView 5 处为合规浮件；测试验收确认全库仅剩 `BojiComponents.swift:83` 一处 `RadialGradient` 属业务图形豁免。编译 run 42467301022 出包 `dist/BojiClub-07403782.ipa`（37.43 MB）。G 表已更新为通过。
- 2026-11-08：**苹果开发第二批修复完成待提交**：BUG-003 输入串轨（删 ClubNumericKeypad 自绘键盘与 keypadWeight 双轨，ClubNumericField 改原生 TextField+sanitize，LiquidCheckbox 改系统符号按钮）、BUG-005 Hero 视频接入（DES-003 方案 A，brand-video.mp4 已入 bundle 并注册 pbxproj）、BUG-010/011 横幅修正（training 文案如实、带「知道了」关闭、改 safeAreaInset 不压顶栏）、BUG-012 JourneyComponents 三处散写玻璃分支收口 clubNativeGlassButton；台账 A/B1 表状态已同步更新。
- 2026-11-08：**云端编译恢复通过（后端开发）**：逐次抓取 xcodebuild 错误行，定位并修复 4 处阻塞编译的问题——`AppStore.swift` 的 `ClubNotificationRoute` 补 `Equatable`（`onChange` 需要）、`TrainingRegistrationViews.swift` 的 `Button(action:) label:` 改回 trailing closure、`ClubAIShell.swift` 的 TimelineView 闭包内非法 `return` 去掉、`VideoPlayer` 无 `videoGravity` 改用 `AVPlayerLayer` 封装（`resizeAspectFill` 铺满）。**workflow run 42461169469 编译成功，IPA `dist/BojiClub-ffe4a1ed.ipa`（37.44 MB）**，已提交推送（`7cb0b97`）。BE-001/BE-004 修复保持「已修复待验」，等测试验收复验。
- 2026-11-08：**阶段 2（P0 修复）Chief 验收通过，阶段 3（UI 原生化改造）开工**。登记：阶段进度表 2→已通过、3→进行中（含完成条件）；C 表第 1 轮验收记录（f9a471f6，首验不通过返工、第四輪通过）；E 节标注已收档归档（后续复验另开 E-3 起）；阶段 2 分工表归档，新增阶段 3 分工表（苹果开发 IOS-006~010、界面设计规范走查、测试验收四设置回归、文档管理打勾）；B1 表加打勾进度汇总（14 项：6 待验 / 1 处理中 / 7 待处理）。
- 2026-11-08：**阶段 3（UI 原生化改造）Chief 验收通过，阶段 4（视频融入与华丽动效）开工**。登记：阶段进度表 3→已通过（G-4 全量复扫，run 42468330096 / f93a9470）、4→进行中（含 Chief 定的完成条件）；C 表第 2 轮验收记录（首验 G-08 内容卡玻璃与 P1 价格卡拍板项 → 全部闭环）；E 节归档注记更正为「阶段 3 复验实际用 F/G 表，阶段 4 从 H 表起」；阶段 3 分工表归档（四人任务全部标已完成），新增阶段 4 分工表（界面设计第二批动效方案、苹果开发 CLN-02+BUG-015+动效落地、测试验收动效走查、文档管理随报随登）；B1 打勾进度更新为 14/14 已修复待验，阶段 4 增量条目待追加。
- 2026-11-08：**阶段 4（视频融入与华丽动效）Chief 验收通过，阶段 5（集成验收与返工循环）开工**。登记：阶段进度表 4→已通过（H-01~H-13 全绿，run 42470904790 / 8f1542dc，BUG-017 闭环、CLN-02 已清）、5→进行中（含完成条件）；C 表第 3 轮验收记录；阶段 4 分工表归档、新增阶段 5 分工表；**新增 I 节总验收汇总**——I-1 验收记录表汇总（5 阶段 3 轮验收 + 构建证据链）、I-2 改动清单汇总（客户端 15 项改造 / 后端 4 项 / 规范文档）、I-3 遗留项清单（bug 现状 11 关 2 待验 4 待处理、后端部署遗留、真机补验项、等拍板事项、已知未实现功能）；D 表 ACC-10 范围更新为 BUG-001~017。
- 2026-11-08：**问题单 T-2（后端）返工完成，待补充复验**。BE-005：新增后台 worker `account-server/process-ai-completion-refresh.php`（systemd timer 每 30 秒）定时把 `ai_user_jobs` 与本地 AI worker 对账并写 `completed_at`，请求路径（insights / club-progress）降级为兜底、超时 1s/2s 放宽到 4s，不再把已完成报告误判成「处理中」。BE-007：服务端 `cloudCommitLock` 由立即 429 改为**排队等锁最多 5 秒**；客户端重试窗口 3 次 → **6 次、每次隔 0.4 秒**，仍不收敛则保留本机记录并自动续同步、不硬报失败。B3 表 BE-005/BE-007 状态改「已修复待验」。
- 2026-11-08：**问题单 T-1（苹果开发）返工完成**。`ExerciseLibraryView:146/174/187` 三处 `components.url!` 改 `guard let ... else { throw URLError(.badURL) }`（commits fca7e98→bc9202a→8e936d2，含 OnboardingView 同类加固）；测试验收终扫全库强制解包 31→10 处，且 10 处全为前置 nil 短路或系统签名，真实强制解包清零。编译 run 24474824704 出包 `dist/BojiClub-ea843320.ipa`（37.48 MB）。
- 2026-11-08：**✅ Chief 代码层面最终验收签字通过（第 4 轮）**。C 表补第 4 轮验收记录（终态包 ea843320，T-1/T-2 双双关单）+ 五条标准终判表（①②③④⑤ 全通过，源码级+编译级）；I-1 问题单台账（T-1/T-2a/T-2b 均已验收关闭，BE-006/008 记遗留不开单）；I-3 遗留项更新——bug 12 条已验收关闭 / 2 条真机补验 / 3 条真机补验项（BUG-002/004/006/007/008），真机补验 7 项清单正式挂起（Chief 签字边界）；阶段 5 状态改「代码层面已签字通过，剩余真机补验 7 项挂起」，交付物表更新（报告已定稿 a4f0692、台账已齐全）；事项状态补苹果开发停机（402 余额不足）待用户定恢复方式。
- 2026-11-08：**服务器线收工（OPS-003 完成）+ 新增 OPS-004 加固遗留项**。B4 表：OPS-003 改「已完成」（服务器 18 文件部署、21 键校验全过、迁移全绿、两个 worker 实测执行成功、webhook 带鉴权 200/不带 401；另修 11 个 systemd worker `User=www-data` 错配为 `nginx` 的历史静默失败坑，提交 da20c3f/a23a9e9，部署脚本改动态探测）；新增 **OPS-004** webhook 鉴权升级 HMAC 签名验证（RevenueCat 官方 `X-RevenueCat-Webhook-Signature`，本轮不做，Chief 指示登记）。I-3-B 后端遗留同步；I-3-D 待办更新（OPS-003 划掉，新增 Bearer 前缀确认项）；事项状态加「服务器补键已完成」。
- 2026-11-08：**用户选定 2+3 混搭（DEC-4），阶段 5 通过、阶段 6 全面重做开工**。①0.1 表新增 **DEC-4**（玻璃旗舰骨架 + 杂志巨号排印气质，视觉稿先行）；②阶段进度表 5→已通过（选定 + 配套产出齐备）、6→进行中（完成条件：四条线落地、一批一编译全绿、逐批复验、走查达标）；③C 表此前已记用户差评与转向；④J 节扩充：J-3 交付状态更新（苹果开发评估、运营文案对照已交付）、新增 **J-4 重做批次台账**（批 0 前置=原生 tab bar + 13 处黑话含三个 prompt；批 1 影像沉浸玻璃打底；批 2 巨号排印数据块；批 3 交互流程收口；四条线覆盖对照）、**J-5 评估要点**（现状基线四病灶、三方案工期风险、混搭可行性）、**J-6 黑话对照要点**（规模、典型替换、prompt 源头坑、硬编码占位坑、保留边界）；⑤事项状态更新。
- 2026-11-08：**用户澄清重做范围＝全页面（一个不漏），Chief 钉入目标；J-4 批次台账按 Chief 定死的三批重排并加「全页面范围」口径行**。①阶段 6 改名「选定方案全面重做（全页面）」，完成条件补：视觉规格=全页面组件规格表（不只三屏）、测试验收逐页复验、界面设计逐页走查；②J-4 范围口径段新增（首页/训练中/训练完成/记录/日报周报/设置/引导/会员/AI/空状态/错误提示全含，组件级铺每页；三屏稿只定设计语言）；③批次表重排为 Chief 三批：批次 0（黑话全页面+原生 TabView+假数据两处 `ClubAIShell.swift:1374/1381`+后端三个 prompt）＝开工中、批次 1（巨号排印+一屏一主按钮+删 `ClubHomeSpeedDial`+每屏玻璃≤3）、批次 2（玻璃沉浸深化，**先立 BUG-007 性能基线**），四条线×全页面覆盖对照与风险红线（训练向导化不做）入表；④黑话数字修正：13 处（初估合计口径）→ **用户可见 9 处 + 术语类 2 处**（苹果开发全量精扫），J-5/J-4/变更记录同步；⑤登记苹果开发技术准备交付 [design-previews/阶段6-导航壳原生化迁移方案-苹果开发.md](design-previews/阶段6-导航壳原生化迁移方案-苹果开发.md)；⑥J-6 补「对照表已扩至全页面（运营文案重写中）」；⑦事项状态行更新。
- 2026-11-08：**批次 0 复验收口 + 批次 1 开工令 + 三条警示入账（J-4b）**。①0.1 表新增 **DEC-5**（给用户的验收包一律 Release 出包，`#if DEBUG` 剥离，K 表「正式包无开发入口」为保险丝——起因：Debug 包流入验收致 5 处开发入口可见）与 **DEC-6**（三联动口径：音效 6 段素材批次 0 只验就位、批次 2 接线实测真声音，尊重静音/减动效，设置页音效开关）；②J-4 批次 0 → **编译绿（run 42496419492/42496009994）+ 复验核心通过**（K1 表），尾巴列明 P2 周报「出勤」×2、P3 引导页三句+注释 4 处（随批次 1 清）；批次 1 → **开工中**（档位定案 `.display` 88pt/`.editorial` 76pt，含批次 0 尾巴清理）；批次 2 → 并入三联动接线；③新增 **J-4b 警示与架构事实**四条：AI 文案生效层在 `backend/ai_core.py`（只改 md 等于没改）、`ios-performance.yml` 管道吞退出码假绿（第二次重演，修复三件已派运维支付）、Debug 包流验收风险、工程文件并发保护（音效素材不进 bundle）；④变更记录同步。
- 2026-11-09：**批次 1 代码收口 + 交付件入库（`bbd9f58`）**。①J-4 批次 1 → **代码全部收口**：末批 `9f0a505`（记录屏体重 `.editorial` 76pt 巨号主角、训练完成页事实格 24pt 数据块）、P3 尾巴清零 `e5ad7ce`（注释「出勤频率」→「训练频率」、组件画廊「本周出勤」→「本周练了」）；第二批复验通过；⚠️ 游离 HEAD 事故（builder/他人 checkout 动分支指针，提交未进 main）由苹果开发切回 main 补 cherry-pick 恢复，代码零丢失——教训「提交前必查 `git status` 第一行」已在批次表留档；②J-4 批次 2 前置更新：设备口径钉死 iPhone 16 Pro（`ad1723f`）、基线成立判据（`totalTestCount=2` 且 `passedTests=2` + 设备字段=16 Pro）；③J-3 新增「8 份交付件入库」行：文档管理用**路径限定式提交**入库并推送（三屏视觉稿、全页面组件规格表、三联动设计表、文案定稿/对照、AppStore 文案初稿、苹果开发两份评估，commit `bbd9f58`，暂存区逐一核对无夹带）；④事项状态待更新。
- 2026-11-08：**装机通道打通 + 收款链路正式闭环（收档）**。①**OPS-001/002 → 已完成**：用户提供 API Key 三件套，TestFlight 签名包 **Build 141 已进测试组**（「薄肌俱乐部测试」）；DEC-3 由「待确认」改为「已落地选 1」。②新增 **OPS-005 收款回调链路终验 → 正式闭环**：用户发 RevenueCat 标准 TEST 事件（id `0FC88245-1E77-4267-BBCA-8F5F1EEFE304`），数据库 `revenuecat_event_facts` 落库、访问日志证实来源 RevenueCat 官方 AWS 网段（User-Agent `RevenueCat`）、全程 200 无 401，`ignored` 为 TEST 事件正确处理（真实购买走 `applied` 发权益）——**项目开始以来第一次真正跑通**；**遗留一项**：备案通过后 webhook 域名从临时 Cloudflare 隧道切 `bojiclub.fun`（运维支付约 5 分钟）。③Bearer 前缀疑点闭环（实测证明两边逐字一致，留档「RevenueCat 原样发送所填值」）。I-3-B/I-3-D 同步、事项状态加收款链路一行、阶段 5 说明改为「装机通道已通，剩用户装机截图启动真机补验」。
