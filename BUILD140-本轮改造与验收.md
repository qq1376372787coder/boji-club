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
| DEC-3 | 真机链路**推荐 1（TestFlight）**，待用户确认 | Chief 与测试验收均选 1：90 天有效期覆盖多轮验收，Ad-hoc 7 天重签易断档；用户回「1/2/3」后生效。**更正：1、2 都需 $99/年付费开发者账号（见 OPS-001），选项 3 仍零账号** | 运维支付已出 1 的中文步骤指引，用户一确认即配置 |

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
| BUG-001 | 通知深链（训练提醒等） | 训练进行中（或 AI 会话可见时）点推送通知：`BojiClubApp.swift:219` 的 `.sheet(item:)` Binding 在 `store.trainingInterfacePresented`/`store.clubAIInterfacePresented` 为真、或 `route.kind == "training"` 时直接返回 nil，通知被静默吞掉 | P1 | 苹果开发 | 已修复待验 | 修复方式（commit ea531ff + 第二批）：屏蔽时改顶部提示横幅，路由保留待条件解除后自动弹出；第二批已修遗留——文案区分 training（如实说明不会自动弹出）、带「知道了」关闭按钮、改 safeAreaInset 不压顶栏（BUG-010/011 同修） |
| BUG-002 | 登录→首页入口状态机 | 登录后依次过 `account.phase`→`MembershipGateView`→`IndependentProfileOnboardingView`→`FirstLaunchWalkthroughView`→主壳，四层任一状态回写不及时即卡在门页 | P2 | 苹果开发 | 待处理 | 苹果开发提供，待模拟器复核 |
| BUG-003 | 训练登记输入 | 训练中切换重量/次数输入：自绘 `ClubNumericKeypad` 与系统键盘（keypadWeight 开关）并存，输入串轨且 VoiceOver 不可达 | P1 | 苹果开发 | 已修复待验（部分） | 自绘键盘与 keypadWeight 双轨已删（ClubNumericKeypad 定义删除、底部键盘条删除），统一原生 TextField（decimalPad/numberPad）+ sanitize 过滤（数字、一个小数点、最长 8 位）；LiquidCheckbox 同步改系统符号按钮。**测试验收复验**：`ClubNumericKeypad`／`LiquidCheckbox` 确已删除，但同批的 `SmartWeightStepper`（DesignTokens.swift:741，使用点 TrainingRegistrationViews.swift:563）与 `TrainingNumericInput125`（WorkoutExperience125.swift:169，使用点 78/84）**仍在**，对应 IOS-003／IOS-004 未做，故本条仅部分关闭 |
| BUG-004 | 组间休息状态 | 暂停/恢复休息并跨午夜或跨时区：`pauseService.state` 与 `restDeadlines` 双源（`ClubAIShell.swift:166-172`），提醒取消与恢复重排边界多，是卡顿高发区 | P2 | 苹果开发 | 待处理 | 待真机/跨日复核 |
| BUG-005 | 品牌视频未融入界面 | 主壳空态 Hero 卡 `heroGlassCard`（`ClubAIShell.swift:1172`）仍是渐变+TimelineView 流光占位，源码注释明写「视频资产待补」；`design-assets/brand-video.mp4` 在工程内无任何引用 | P1 | 苹果开发／界面设计 | 已修复待验 | 按 DES-003 方案 A 接入：AVQueuePlayer+AVPlayerLooper 循环、仅页面活跃播放、离场 pause+seek(.zero)；减少动态效果/视频未就绪/页面非活跃回退静态占位；底部护字渐变、深色压暗 20%；brand-video.mp4 已入 BojiClub/ 并在 pbxproj 注册（四处引用齐全）。**测试验收复验（第三輪）**：循环/离场暂停/reduceMotion 降级/深色压暗/护字渐变均到位；但**全库无 `isMuted`，视频会外放声音**（见 BUG-014），低电量降级与首帧占位未做（见 BUG-015） |
| BUG-006 | 侧栏无障碍审计 | 默认侧栏自动审计仍报 3 个 `element=nil` 对比度失败 + 2 个「大字号可能裁切」预测（`docs/native-ui-20261024/diagnostics/sidebar-ax-triage.md`） | P2 | 苹果开发 | 待处理 | 上一轮未关闭项；草稿标题实测 15.81:1 非误报，但未知项无法定位 |
| BUG-007 | 滚动性能回归 | 相同 SE3 模拟器 Debug 前后对比：滚动 CPU 0.304→0.448 秒（+47.2%），指令数 +38%（`docs/native-ui-20261024/performance/performance-comparison.md`） | P2 | 苹果开发 | 待处理 | 未做采样归因；影响「华丽动效」的流畅度观感 |
| BUG-008 | 顶栏工作区选择器小屏溢出 | iPhone SE（375pt）下 `ClubModeCapsulePicker` 分段选择器 `maxWidth: 300`，加左 44pt 侧栏钮 + 右 44pt 更多钮 = 388pt > 375pt，可能压缩/截断 | P3 | 苹果开发 | 待处理 | 仅大字号走 `.menu` 降级；小屏待复核 |
| BUG-009 | 强制解包风险点 | 静态扫描 31 处 `!`，多数有前置 guard；风险相对高的：`AppStore.swift:2111`（`state.days[key]!.meals[index]`）、`ExerciseLibraryView.swift:143/168/178`（`components.url!`）、`MembershipService.swift:240`（`self.notice!`）、`HealthViews.swift:206`（`URL(string:)!`） | P3 | 苹果开发 | 待处理 | 未发现必然崩溃路径，建议随改造一并加 guard |
| BUG-010 | 通知横幅文案与实际行为不符 | training 类通知（`route.kind == "training"`）被 sheet 绑定**永久**屏蔽（`BojiClubApp.swift:219` 的 blocking 条件里含 `route?.kind == "training"`），横幅却写「退出训练或对话后会自动打开」——实际永远不会打开；且 `BojiStatusBanner` 未传 `action`，**没有关闭按钮**，route 未清理前横幅常驻 | P3 | 苹果开发 | 已修复待验 | 触发路径：训练中收到另一日期的训练提醒 → `ClubAIShell.swift:761-764` 把 `trainingRoute` 置 nil 但保留 route → 横幅常驻。测试验收复验 BUG-001 时发现；**已修**：training 类文案如实写「训练进行中不会自动弹出，请稍后从通知中心重新打开本条通知」，横幅带「知道了」关闭动作（清提示状态），不再常驻 |
| BUG-011 | 通知横幅可能遮挡顶栏 | 横幅 `.overlay(alignment: .top)` 直接压在 `navigationWorkspace` 上（`BojiClubApp.swift:241-247`），顶栏已有侧栏钮+分段选择器+更多钮，需确认不遮挡、不拦截点击 | P3 | 苹果开发 | 已修复待验 | 横幅从 `.overlay(alignment: .top)` 改为 `.safeAreaInset(edge: .top)`，走系统安全区布局，不压导航栏、不拦截顶栏点击 |
| BUG-012 | 页面内散写 `if #available(iOS 26)` | `JourneyComponents.swift:72/92/128` 仍直接写 `if #available(iOS 26.0, *)` 三分支（规范 §1 明令禁止，应收口到 `clubNativeGlassButton`）；且这三处所在的 `ClubActionButtonStyle` 本身就是待淘汰的自绘按钮（30+ 使用点） | P2 | 苹果开发 | 已修复待验 | 材质收口 IOS-005 的漏项；**已修**：JourneyComponents 三处散写分支收口为 `.clubNativeGlassButton(prominent:)` / `.clubNativeGlassButton()`，页面层无 if #available；ClubActionButtonStyle 整体淘汰（30+ 使用点替换）留待后续批次 |
| BUG-013 | Hero 卡视频暂停钮触控区不足 | 暂停/播放钮视觉 30×30pt，实际触控区 < 44pt 最小触控标准 | P3 | 苹果开发 | 已验收关闭 | 测试验收第二批复验发现，第三輪复验未修；**第四輪已修**（commit 54092f1）：`ClubAIShell.swift:1287-1288` 加 `.frame(width: 44, height: 44).contentShape(Circle())`，视觉仍 30pt、命中区 44pt，符合 ACC-06 与 DES §6 |
| BUG-014 | Hero 品牌视频**没有静音** | `setupHeroVideo()`（`ClubAIShell.swift:1190-1196`）创建 `AVQueuePlayer` 后未设 `isMuted = true` | P1 | 苹果开发 | 已验收关闭 | 测试验收第三批复验发现（界面设计独立核对一致）；**第四輪已修**（commit 54092f1）：`ClubAIShell.swift:1194` `player.isMuted = true` |
| BUG-015 | 视频降级缺两项（低电量 / 首帧占位） | DES §5.2 要求「低电量模式 → 静态图」与「未就绪前显示第 0 帧静态图」 | P3 | 苹果开发 | 已修复待验（低电量部分） | **第四輪已修低电量闸门**（commit 54092f1）：`ClubAIShell.swift:1191` guard 增 `!ProcessInfo.processInfo.isLowPowerModeEnabled`。**首帧占位图按 Chief 决定留到阶段 4** 随视频深化一起做，本条保持打开至阶段 4 |
| BUG-016 | 勾选按钮动效未受「减少动态效果」约束 | `TrainingRegistrationViews.swift:295` `Image(...).symbolEffect(.bounce.up.byLayer, value: true)` 无条件生效；原自绘 `LiquidCheckbox` 的动画是有 `if !reduceMotion` 门控的，换原生后**门控丢失** | P3 | 苹果开发 | 已验收关闭 | 测试验收阶段 3 交互回归（F2/INT-06）发现；违反 DES §0 铁律 3「所有动效尊重减少动态效果」与 ACC-05。**已修**（commit 43d66f8）：`TrainingRegistrationViews.swift:298` `if reduceMotion { base } else { base.symbolEffect(...) }` |

> 用户直接在群里反馈的具体 bug 和流程卡壳点，由测试验收转记到此表。
>
> 另：`KNOWN-ISSUES.md` 列出的功能差额（E6 距离计量、D6 提醒频率学习、E7 围度/体脂独立流程、漏练补排、行动状态机全面接入、草稿并发分叉）属**已知未实现功能**，不计入本轮 bug 编号，单独跟踪。

## B. 改造清单（按负责人分表）

### B1. 苹果开发 · 自绘控件 → 原生组件 + 玻璃改造

> **打勾进度（文档管理随报随登）**：共 14 项。已修复待验 6 项（IOS-001~005、011，其中 4 个自绘控件 IOS-001~004 全部换完，b1d31c7 补最后两个，待其构建验证）；处理中 1 项（IOS-014 视频接入，代码完成待编译与视觉验收）；待处理 7 项（IOS-006~010 动效系统化为阶段 3 主体，IOS-012/013 流程状态改造）。阶段 3 收尾要求逐项转「已修复待验」并经界面设计走查 + 测试验收回归 + 云端编译。

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

### B2. 界面设计 · 视觉与动效规范（规范产出后贴链接）

| 编号 | 规范项（材质/层次/模糊/动效节奏/视频融合方案） | 交付物 | 状态 | 备注 |
|---|---|---|---|---|
| DES-001 | 「iOS 原生组件 + 玻璃质感」视觉与动效规范：系统分层降级（iOS 26 glassEffect / iOS 17-25 磨砂 / 增强对比度不透明）、材质三层体系（内容面/浮动玻璃/强调玻璃，含圆角、描边、阴影、密度值）、z 层次约定、动效节奏表（时长/曲线/进场/流光/华丽感红线）、组件规格速查、验收自查清单 | [0.16.0-原生玻璃与动效规范.md](0.16.0-原生玻璃与动效规范.md) | 已交付待验 | 供苹果开发落地、测试验收按 §7 自查 |
| DES-002 | 视频融入方案：素材已解析为 960×960 / 10 秒 / 2.1MB 方形视频；给出 A 首页 Hero 玻璃卡底层视频（推荐）、B 启动过场、C 训练完成页氛围底三个候选位 + 统一播放规格（静音循环、离开暂停、减少动态效果显示静态帧、渐变护字） | 同上 §5 | **已拍板选 A**（DEC-1） | 出首页 Hero 卡视觉稿（视频底层 + 玻璃卡 + 渐变护字 + BUG-005 落地要点），出好 @苹果开发 |
| DES-003 | 首页 Hero 视频玻璃卡视觉稿（方案 A 落地），三状态：①浅色视频播放态 ②深色（视频上先叠黑 20% 再压护字）③减少动态效果/低电量/未就绪 → 同构图换首帧静态图。分层规格：视频 z0 → 全幅渐变护字（透明→黑 52%，底部最深）→ 玻璃高光层 `clubGlassEffect`(圆角28) → 全白文字+1px 投影（对比度≥4.5:1）→ 右上 30pt 玻璃暂停钮；14s 流光保留、仅页面活跃时跑 | [design-previews/hero-video-card-A.html](design-previews/hero-video-card-A.html) | 已交付待验 | **BUG-005 落地要点**：①`ClubAIShell.swift:1172` heroGlassCard 现有 TimelineView 流光保留，其下插视频层；②AVPlayer 单例、静音循环，页面活跃才 play，离场 pause+seek(.zero)；③三闸门（reduceMotion/低电量/视频未就绪）任一命中只显首帧图，可删"视频资产待补"注释；④视频入 bundle 前先挂占位图防黑块；⑤`design-assets/brand-video.mp4` 需加入 App 资源 |

### B3. 后端开发 · 接口/数据侧流程卡顿问题

> 摸底结论（2026-11-08，后端开发）：账号服务（PHP）与 AI 后端（Python）代码本身有较多防护，但有 8 处会在真实链路里造成卡顿/停摆，按优先级排列如下。

| 编号 | 问题（登录/同步/支付回调等） | 影响的流程 | 方案 | 状态 | 备注 |
|---|---|---|---|---|---|
| BE-001 | 会员核验在请求路径上同步调用 RevenueCat：`requireActiveMembership → revenueCatRefreshIfDue → revenueCatVerifyMembership`，一次 4 个 HTTPS 请求、deadline 12 秒；付费用户每 5 分钟后的第一个受限请求最多卡 12 秒。购买后 `/me/membership/verify` 强制刷新同样同步阻塞。 | 购买后"核验中"长时间转圈；会员功能页面（任务/AI/记录）偶发卡死 | **已改**：请求路径只读本地 `membership_entitlements`；新增后台 worker `account-server/process-membership-refresh.php`（systemd timer 每分钟）承担到期核对；删掉 index.php 两处、weekly.php 一处的同步刷新调用；`/me` 保留 respondThen 异步刷新 | 已修复待验 | index.php:352、revenuecat.php:25、revenuecat-verify.php:131；**第二成因（运维支付查实）：配置键缺失 → `revenueCatVerificationConfigured()` 假 → `rc_not_configured` 要求客户端 60 秒重试，随 OPS-003 线上补键一并解决** |
| BE-002 | 登录强依赖服务端配置与 Apple 联网：`apple_client_ids` 缺失直接 503「Apple 登录尚未配置」；公钥缓存过期/首次登录时同步联网 `appleid.apple.com`（5 秒超时），网络差即登录失败。**根因已查实（运维支付）：`deploy.sh` 首次部署生成的 `config.php` 根本没写这些键**，且 `apple_keys_cache_dir` 目录 deploy.sh 不建（上轮修过但脚本没跟上） | Apple 登录入口不可用或转圈 5 秒 | 源码已改：deploy.sh 生成完整 21 键配置、缺密钥自动生成落盘 0600、建 Apple 公钥缓存目录、部署后配置校验缺键即失败；新增 `account-server/config-contract.php`、`account-server/check-config.php`（`deploy.sh --check-config`）、`tests/test_deploy_config_contract.py`（21 键全通过）；`.gitignore` 补 `account-server/private/`、`cache/apple-keys/`。**待办：线上旧 config.php 不会自动更新，需管理员登录服务器补键（运维支付无 SSH 权限，清单给 Chief）** | 源码已改·待线上补键 | apple-auth.php:62、apple-key-cache.php:38；改动均未碰线上 |
| BE-003 | 支付回调强依赖 `revenuecat_webhook_authorization`（≥24 字符），缺失时全部事件 401 被拒；TRANSFER 等异常事件直接 503，只能等 RevenueCat 重投，无本地对账/补单入口。**根因已查实（运维支付）：deploy.sh 生成的 config 无此键 → webhook 鉴权直接判未授权，所有支付回调 401**；另发现模板 `revenuecat_product_ids` 写的是已下架旧档 `bojiclub_halfyear_2990/yearly_4290`（iOS 端在用 `yuefu/nianfu/yongjiu`），`environment` 写 PRODUCTION 与 RevenueCat 实配 SANDBOX 不一致 | 付款成功但权益不到账或延迟 | 部署配置已随 BE-002 一并修（商品档改 `yuefu/nianfu/yongjiu`、配置校验）；**待办：管理员补键 + 去 RevenueCat 后台配 webhook 的 Authorization 头**；回调失败告警 + 本地对账/补单脚本仍待做 | 源码已改·待线上补键 | revenuecat.php:7、revenuecat.php:111 |
| BE-004 | 域命令连续失败 6 次即标记 `blocked`（前台断网 12 分钟即可触发），云同步遇到 blocked 命令直接抛「有一项修改需要处理」并中止。 | 弱网/多设备后同步停摆，用户不知如何处理 | **已改**：`.deferred`（结果未确认）改指数退避自动重试（2s→5s→15s→60s→5min→15min→1h），不再按次数 blocked；仅真实 409 冲突才 blocked，且 blocked 不再中止云同步（其余记录照常读写） | 已修复待验 | BojiClub/AppStore.swift:2617/2639、BojiClub/ClubProposalSync.swift:24/29（新增 `nextAttemptAt` + `DomainCommandBackoff`） |
| BE-005 | AI 完成状态核验用 1 秒 / 2 秒超时的同步 HTTP 打本地 worker（`verifiedAICompletion` / `verifiedAICompletions`），位于 insights、club-progress 请求路径。worker 繁忙时核验失败 → 已完成报告不被标记 → 页面显示「处理中」或重复生成。 | AI 报告/复盘状态不同步、重复生成 | 状态由 worker 回调/定时任务写入；或延长超时并允许降级标记 | 待处理 | ai-response.php:84/124、insights.php:60、club-progress.php:72 |
| BE-006 | 旧账号首次分片化迁移在第一个 `/me/sync` 请求里同步完成（`cloudPartEnsure`），数据量大时首同步长时间无反馈；旧数据总量 >15MB 直接返回 426 要求更新 App。 | 老用户升级后首次同步卡住/失败 | 迁移放后台 + 进度提示；426 时给明确更新引导 | 待处理 | cloud-parts.php:119、cloud-parts.php:177 |
| BE-007 | 云同步提交锁按用户文件锁，第二台设备提交返回 429 + `Retry-After: 5`；客户端虽会 5 秒后自动重试，但连续 3 次冲突会中止本次同步。 | 多设备同时使用时偶发同步失败提示 | 服务端排队合并；或延长客户端重试窗口 | 待处理 | cloud-parts.php:72、AppStore.swift:770/810 |
| BE-008 | AI worker 未配置模型 Key 时直接 `SystemExit` 退出，所有 AI 功能不可用且无明确错误暴露给客户端。 | AI 分析全部失败 | 部署核查 + 健康检查告警（`/api/v1/health` 已具备） | 待处理 | backend/server.py:1322 |

### B4. 运维支付 · 真机安装链路

| 编号 | 事项（签名/分发安装/需要的账号证书） | 状态 | 备注 |
|---|---|---|---|
| OPS-001 | 真机安装链路三选一：1. TestFlight（90 天有效，首次需等苹果审核）；2. Ad-hoc 直装（最快当天上真机，7 天重签）；3. 模拟器 MobAI 分享（零账号，测不了相机/健康/推送真机能力）。**更正（运维支付查苹果官方文档）：App Store Connect 与 API Key 需加入 Apple 开发者计划（$99/年）+ App Manager/Admin 权限，选项 1 和 2 都要付费账号，此前"免费 Apple ID 可建 API Key"说法作废**；区别只在时效 90 天 vs 7 天 | **Chief 推荐 1（TestFlight），待用户确认**（DEC-3，前提已更正为需付费账号） | 现 dist 里的 `BojiClub-4938f036.ipa` 为未签名 Debug 包（无签名/描述文件，代码在 debug dylib 里），**任何真机都装不上**；选 1 的操作步骤指引已出（建 API Key→`builder auth apple`→`builder signing setup --distribution store`→出包上传→TestFlight 分发），用户回「1」即走起；`.p8` 文件不进聊天，走安全路径 |
| OPS-003 | **线上补键（管理员操作，运维支付无 SSH 权限）**：旧脚本生成的 `config.php` 缺 21 个必需键（Apple 登录、RevenueCat 全套），不会被新脚本自动更新；另需去 RevenueCat 后台配置 webhook 的 Authorization 头 | **待管理员（Chief 转交运维）执行** | 不补则 BE-001 第二成因（`rc_not_configured`）、BE-002（503）、BE-003（401）线上依旧；清单由运维支付列给 Chief |
| OPS-002 | builder 已登录 GitHub，未登录 Apple；仓库无证书与描述文件 | 待处理 | 链路选定后由运维支付配置并同步构建/验证命令 |

---

## C. 验收记录表（Chief 验收时填写）

每轮验收一行：轮次 / 交付构建（Build 号 + IPA）/ 验收日期 / 结果（通过·不通过）/ 发现的问题 / 处置（重新派活给谁）。

| 轮次 | 构建 | 日期 | 结果 | 发现的问题 | 处置 |
|---|---|---|---|---|---|
| 第 1 轮 | dist/BojiClub-f9a471f6.ipa（run 42465043363，未签名 Debug） | 2026-11-08 | **通过（阶段 2）** | 首验发现 BUG-014 视频未静音（P1）、BUG-013 暂停钮触控区不足、BUG-015 低电量闸门缺，判不通过返工 | 返工后第四輪复验通过（E-2 表，commit 54092f1）；BUG-015 首帧占位留阶段 4；进入阶段 3 |

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
| ACC-10 | A 表 bug 清零 | BUG-001~012 全部「已验收关闭」或经 Chief 同意延后 | — | 待处理 | — |

### 测试环境限制（测试验收备注）

1. 本机 Windows 无 Xcode，无法跑 XCTest／XCUITest 与 iOS 17 模拟器；ACC-02 的「iOS 17–25 磨砂」一项当前**没有可执行环境**，需运维支付确认能否提供 iOS 17 模拟器或真机，否则只能做源码级降级分支核对。
2. ACC-02/04/05/06/07/09 都需要真机或模拟器实际画面，依赖运维支付的真机安装链路（B4）。
3. 当前 `dist/BojiClub-4938f036.ipa` 为未签名 Debug 包，不可装真机，不能作为验收构建。**2026-11-08 更新**：`dist/BojiClub-c6647b04.ipa`（37.44 MB）已是**编译通过的未签名 Debug 包**，可用于模拟器/后续签名，真机仍需安装链路。

---

## E. 阶段 2 修复复验（测试验收，2026-11-08）【已收档：阶段 2 于 2026-11-08 经第四輪复验通过，本节转为归档记录，后续复验另开 E-3 起】

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
| G-23 | 编译回归 | ⏳ 进行中 | run 42468330096（head `cfaa0d5`，含 d837df6 的价格卡改动） |

**阶段 3 结论**：客户端六项完成条件全部满足（G-13~G-22），P1 拍板项已闭环（G-19）；**仅剩 G-23 编译回归待出结果**，以及 P3 清理项 CLN-02（`BreathingPulseHalo` 死代码）。

---

## 进度速览（文档管理维护）

### 阶段进度（5 阶段，Chief 逐阶段验收）

| 阶段 | 内容 | 状态 | 说明 |
|---|---|---|---|
| 1 | 摸底与规范 | **已通过**（2026-11-08 Chief 验收） | 四份产出齐备、交叉核实一致（Bug 清单、自绘控件清单、后端问题清单、视觉动效规范） |
| 2 | P0 修复：bug 与流程断点 | **已通过**（2026-11-08 Chief 验收，第四輪复验后） | 完成条件全部满足：A 表 P1 阻塞项清空；BUG-001 通知深链修复；5 个流程断点消除；BE-001/BE-004 修复；测试验收第四輪复验通过（E-2 表）；云端编译 run 42465043363 出包 f9a471f6；Chief 过目认可。遗留：BUG-015 首帧占位按 Chief 决定留阶段 4 |
| 3 | UI 原生化改造 | **进行中**（2026-11-08 开工） | 完成条件：4 个自绘控件全部换成原生组件（IOS-001~004，代码已完成待构建验证）；23 处材质收口到 clubGlassEffect（IOS-005 已收口）；自绘动效换系统动效（IOS-006~010 本阶段主体）；改造清单逐项打勾；界面设计按规范走查达标；云端编译通过；Chief 过目认可 |
| 4 | 视频融入 + 动效特效 | 未开始 | 视频位 A 已定，可与阶段 3 并行部分推进 |
| 5 | 整体验收（Chief 循环验收至满意） | 未开始 | 按 §0 五条标准 + D 表 ACC-01~10 |

### 阶段 2 分工与状态（已通过·归档）

| 成员 | 任务 | 状态 |
|---|---|---|
| 后端开发 | BE-001 核验改后台异步（请求路径只读本地权益，不再同步打 RevenueCat 卡 12 秒）；BE-004 改指数退避自动重试（弱网恢复自动续同步）；改完跑云端编译 + 登记台账 | **已修复待验**；云端编译已通过（run 42461169469，IPA `dist/BojiClub-ffe4a1ed.ipa`），等测试验收复验 |
| 苹果开发 | 材质收口 17 处（15 处 + RemoteConfigNoticeView、ProfileView 补 2 处）→ git 提交推送 + 云端编译；P0 必改 BUG-001（通知深链）、BUG-003（输入串轨，随 IOS-001/002 原生化关闭）；拿到 Hero 视觉稿后接视频关 BUG-005 | **第一批已提交（c3cf75d）**；第二批（BUG-003/005/010/011/012）已改完待提交，提交后请测试验收重跑云端编译 |
| 运维支付 | BE-002/BE-003 部署配置核查 → **已完成**：根因 deploy.sh 配置模板缺键，源码已改（21 键契约 + 校验脚本 + 测试 21 键全过），线上补键清单交 Chief（OPS-003）；TestFlight 步骤指引已出（前提更正：需 $99 付费账号），待用户回「1/2/3」 | 已回报，待用户选链路 |
| 界面设计 | 首页 Hero 卡视觉稿（视频底层静音循环/离开暂停/减少动态显静态帧 + 玻璃卡 + 渐变护字 + BUG-005 落地要点），出好 @苹果开发 | 进行中 |
| 测试验收 | 据 DEC-1/DEC-2 更新 D 表 ACC-02/ACC-04；等修复报上来做复验回归 | 进行中 |
| 文档管理 | 三个决定登记、阶段 2 修复状态随报随登（本表） | 已完成（阶段 2 通过，本表归档） |

### 阶段 3 分工与状态（随报随登）

| 成员 | 任务 | 状态 |
|---|---|---|
| 苹果开发 | **IOS-006~010 动效系统化**：手绘 TimelineView spinner → ProgressView、呼吸环 → Gauge + symbolEffect、激光扫描线 → 系统进度语义、彩带粒子 → celebrate、引导页轨道环 → glassEffect + SF Symbols；改一项勾一项 B1 表，一批一编译（已开好头 b1d31c7，IOS-003/004 原生化待其构建验证） | 进行中 |
| 界面设计 | 按规范 §1–§7 走查改造效果：材质三层是否滥用、动效节奏表是否守住、玻璃红线（每屏数量、护字渐变）是否达标，不达标处列清单 | 进行中 |
| 测试验收 | 交互回归：深色模式、大字号、减弱动态效果、增强对比度四种设置下过一遍改造过的控件，B1 清单逐项核对打勾 | 进行中 |
| 文档管理 | B1 改造清单打勾状态随报随登；E-2 收档归档（已完成） | 进行中 |
| 后端开发 | （阶段 2 主任务已交付；BE-005~008 待排期，不属本阶段） | 待命 |

### 事项状态

| 事项 | 负责人 | 状态 |
|---|---|---|
| Bug 全量排查清单（首轮 BUG-001~009） | 测试验收 | 已完成首轮，待真机复核 |
| 自绘控件与流程不通点清单 | 苹果开发 | 摸底完成；4 个自绘控件（IOS-001~004）已全部换原生待构建验证，动效系统化 IOS-006~010 阶段 3 进行中 |
| 接口/数据侧问题清单 | 后端开发 | 已完成摸底，8 项入 B3 表 |
| 视觉与动效规范（含视频融合方案） | 界面设计 | 已交付（DES-001~003）并通过阶段 1 验收；**视频位已定 A（DEC-1）**，Hero 视觉稿已出，待苹果开发接入后关 BUG-005 |
| 真机安装链路 | 运维支付 | **推荐 1 TestFlight（DEC-3），待用户回复 1/2/3**；更正：1、2 均需 $99/年付费账号，3 零账号；链路生效前真机验收项挂起，模拟器验收不受影响 |
| 本文档 | 文档管理 | 台账运行中：阶段 1/2 已通过，阶段 3 打勾随报随登 |

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
- 2026-11-08：**阶段 2（P0 修复）Chief 验收通过，阶段 3（UI 原生化改造）开工**。登记：阶段进度表 2→已通过、3→进行中（含完成条件）；C 表第 1 轮验收记录（f9a471f6，首验不通过返工、第四輪通过）；E 节标注已收档归档（后续复验从 E-3 起）；阶段 2 分工表归档，新增阶段 3 分工表（苹果开发 IOS-006~010、界面设计规范走查、测试验收四设置回归、文档管理打勾）；B1 表加打勾进度汇总（14 项：6 待验 / 1 处理中 / 7 待处理）。
