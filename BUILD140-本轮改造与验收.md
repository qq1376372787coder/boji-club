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
| BUG-013 | Hero 卡视频暂停钮触控区不足 | 暂停/播放钮 `Image(...).frame(width: 30, height: 30)`（`ClubAIShell.swift:1281`）直接作为 Button label，`clubNativeGlassButton()` 不含最小尺寸，实际触控区 = 30×30pt < 44pt 最小触控标准 | P3 | 苹果开发 | 待处理 | 测试验收第二批复验时发现，第三輪复验**仍未修**；违反 ACC-06 与 DES §6「视觉可 42pt、触控必须 ≥44pt」 |
| BUG-014 | Hero 品牌视频**没有静音** | `setupHeroVideo()`（`ClubAIShell.swift:1190-1196`）创建 `AVQueuePlayer` 后未设 `isMuted = true`；全库 `BojiClub/*.swift` 搜 `isMuted` **零命中**。打开 App 首页会直接外放视频原声 | P1 | 苹果开发 | 待处理 | 测试验收第三批复验时发现；违反 DES §5.2「静音 `isMuted = true`」。修法：`player.isMuted = true` |
| BUG-015 | 视频降级缺两项（低电量 / 首帧占位） | DES §5.2 要求「低电量模式 → 静态图」与「未就绪前显示第 0 帧静态图」。现状：只实现减少动态效果降级（不创建 player，回退 `brandMist` 纯色底）；无 `isLowPowerModeEnabled` 判断，未就绪回退是纯色块而非首帧截图 | P3 | 苹果开发 | 待处理 | 测试验收第三批复验时发现；纯色底已能避免黑块，但不符合规范原文，建议补 `ProcessInfo.processInfo.isLowPowerModeEnabled` 与首帧占位 |

> 用户直接在群里反馈的具体 bug 和流程卡壳点，由测试验收转记到此表。
>
> 另：`KNOWN-ISSUES.md` 列出的功能差额（E6 距离计量、D6 提醒频率学习、E7 围度/体脂独立流程、漏练补排、行动状态机全面接入、草稿并发分叉）属**已知未实现功能**，不计入本轮 bug 编号，单独跟踪。

## B. 改造清单（按负责人分表）

### B1. 苹果开发 · 自绘控件 → 原生组件 + 玻璃改造

| 编号 | 现状（自绘/自建控件或流程不通点） | 目标（原生组件/玻璃方案） | 涉及文件 | 状态 | 备注 |
|---|---|---|---|---|---|
| IOS-001 | LiquidCheckbox 自绘圆+波纹勾选 | 系统符号按钮（checkmark.circle.fill/circle）+ symbolEffect(.bounce.up.byLayer) + 触感 | TrainingRegistrationViews.swift completeControl | 已修复待验 | 自绘定义已删（DesignTokens.swift:673 段）；完成/撤销分支保留 heavyDrop/latch/tick 触感与 accessibilityLabel/Hint |
| IOS-002 | ClubNumericKeypad 自绘数字键盘 | 系统键盘 decimalPad/numberPad + 原生 TextField | Experience123.swift ClubNumericField、TrainingRegistrationViews.swift:542/546/564 | 已修复待验 | 自绘键盘定义与 keypadWeight 双轨已删，底部键盘条删除；TextField 带 sanitize 过滤（数字、一个小数点、最长 8 位），VoiceOver 走系统键盘语义 |
| IOS-003 | TrainingNumericInput125 包 UITextField | 原生 TextField + formatted 数值约束 | WorkoutExperience125.swift:169/78/84 | 待处理 |  |
| IOS-004 | SmartWeightStepper 自绘磁吸步进胶囊 | 原生 Stepper/Menu + 系统材质 | DesignTokens.swift:814 | 待处理 |  |
| IOS-005 | 23 处直写 .regularMaterial/.ultraThinMaterial | 收口 clubGlassEffect（iOS 26 自动 glassEffect） | 见摸底文档 C 节 | 已修复待验 | 17 处浮件收口 clubGlassEffect、2 处内容卡改不透明 cardSurface；全库复扫仅剩 Design.swift:200 桥接自身降级分支（预期）；含 BUG-012（JourneyComponents 散写玻璃分支收口） |
| IOS-006 | ClubActivityMark/ClubWaitBar/AIWaitProgress 手绘 TimelineView | 原生 ProgressView（不确定态） | Design.swift:331/509/540 | 待处理 |  |
| IOS-007 | BreathingPulseHalo 手绘呼吸环 | 原生 Gauge(.accessoryCircularCapacity) + symbolEffect | DesignTokens.swift:746 | 待处理 |  |
| IOS-008 | LaserScanBeamOverlay 手绘激光扫描线 | 系统进度语义（ProgressView+识别文案） | DesignTokens.swift:888、MealEditorView.swift:876 | 待处理 |  |
| IOS-009 | ConfettiView 手绘彩带粒子 | symbolEffect(.celebrate)/系统庆祝 | OnboardingView.swift:1324/1293 | 待处理 |  |
| IOS-010 | 首次引导轨道环/渐变卫星手绘 | glassEffect + SF Symbols 重做 | FirstLaunchWalkthroughView.swift:223-530/794-810 | 待处理 | 等 DES 动效规范 |
| IOS-011 | 训练/AI 界面呈现时通知深链被屏蔽（sheet 返回 nil） | 训练进行中点通知可见提示或跳转 | BojiClubApp.swift:216 | 已修复待验 | P1 流程断点；屏蔽逻辑保留（不打断训练），顶部安全区横幅如实提示+「知道了」关闭，route 保留待解除后自动弹出（BUG-001/010/011 同修） |
| IOS-012 | 登录→会员门→引导→首启 walkthrough 四层状态机回写不及时卡门 | 状态收口+卡门可恢复提示 | BojiClubApp.swift、ClubAIShell.swift | 待处理 |  |
| IOS-013 | 组间休息 pauseService+restDeadlines 双状态 | 单源事实+跨午夜边界回归 | ClubAIShell.swift:166-172 | 待处理 |  |
| IOS-014 | 品牌视频融入技术位预留 | AVKit/VideoPlayer + 玻璃边框，**位置已定 A：首页 Hero 卡底层**（DEC-1） | ClubAIShell.swift heroGlassCard、pbxproj | 处理中 | 代码层按 DES-003 方案 A 完成（AVQueuePlayer 静音循环+三闸门降级+护字渐变+30pt 玻璃暂停钮），brand-video.mp4 已复制入 BojiClub/ 并在 pbxproj 注册；待云端编译与视觉验收 |

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
| 第 1 轮 |  |  |  |  |  |

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

## E. 阶段 2 修复复验（测试验收，2026-11-08）

复验窗口由 Chief 开启。本轮为**源码级静态复验 + 云端编译验证**（真机/模拟器画面项仍待安装链路）。

| 项 | 复验结论 | 证据 |
|---|---|---|
| **云端编译** | ✅ **通过** | `builder ios build` run 42461772092（Build ID c6647b04），IPA 37.44 MB；快照 `7913193` 与 HEAD `8b3447e` 的源码差异为空（仅未提交杂项文件），即**已提交状态编译通过** |
| **BE-001 会员核验异步化** | ✅ 通过（附 1 条观察） | `index.php:593`、`weekly.php:191` 请求路径已不再同步打 RevenueCat（注释确认改后台）；`/me` 走 `respondThen` 异步刷新（index.php:695）；后台 worker `account-server/process-membership-refresh.php` + `account-server/deploy/bojiclub-membership-refresh.{service,timer}` 已就位。**观察**：`/me/membership/verify`（index.php:701）仍同步强制刷新，但已不在受限请求路径；后台每分钟刷新后客户端轮询会收敛，可接受 |
| **BE-004 弱网同步** | ✅ 通过 | `AppStore.swift:2646` 改 `DomainCommandBackoff.delay(attempts:)` 指数退避；`:2618` 按 `nextAttemptAt` 跳过未到期命令；`:765` blocked 不再中止整次同步；`ClubProposalSync.swift` 新增 `nextAttemptAt` + `DomainCommandBackoff` |
| **客户端四连修** | ✅ 全部通过 | ①`ClubNotificationRoute: Identifiable, Equatable`（AppStore.swift）；②`TrainingRegistrationViews.swift:293/304` 已用 `Button(action:) { }`；③`ClubAIShell.swift:1178` TimelineView 闭包为表达式体、无非法 `return`；④`ClubAIShell.swift:1207-1228` 改用 `HeroVideoContainerView`（`AVPlayerLayer` + `videoGravity = .resizeAspectFill`） |
| **BUG-001 / 010 / 011 通知横幅** | ✅ 通过 | 横幅 `safeAreaInset(edge: .top)` 不压顶栏；`actionTitle: "知道了"` 关闭；training 类文案如实 |
| **BUG-005 视频三闸门** | ⚠️ 部分 | 循环（`AVPlayerLooper`）、离场暂停归零、reduceMotion 降级、深色压暗、护字渐变均到位；**未静音**（BUG-014，P1）、低电量与首帧占位缺失（BUG-015，P3） |
| **BUG-012 玻璃分支收口** | ✅ 通过 | 全库 `if #available(iOS 26` 仅剩 `Design.swift:160/197/211` 桥接自身（预期） |
| **BUG-003 输入串轨** | ⚠️ 部分 | `ClubNumericKeypad`／`LiquidCheckbox` 已删并改原生；`SmartWeightStepper`（DesignTokens.swift:741）与 `TrainingNumericInput125`（WorkoutExperience125.swift:169）仍在（IOS-003／004 未做） |
| **BUG-013 暂停钮触控区** | ❌ 未修 | 仍为 30×30pt（ClubAIShell.swift:1281） |

**复验结论**：BE-001／BE-004 与客户端四连修通过，云端编译通过；**阶段 2 尚不能判通过**——BUG-014（P1 视频未静音）必须修，BUG-003 剩余两项与 BUG-013／015 需排期。

---

## 进度速览（文档管理维护）

### 阶段进度（5 阶段，Chief 逐阶段验收）

| 阶段 | 内容 | 状态 | 说明 |
|---|---|---|---|
| 1 | 摸底与规范 | **已通过**（2026-11-08 Chief 验收） | 四份产出齐备、交叉核实一致（Bug 清单、自绘控件清单、后端问题清单、视觉动效规范） |
| 2 | P0 修复：bug 与流程断点 | **进行中** | 完成条件：A 表 P0/严重 bug 全关；BUG-001 通知深链（`BojiClubApp.swift:218`）修复；5 个流程断点消除；BE-001（核验同步阻塞）与 BE-004（弱网同步停摆）修复；测试验收复验通过；云端编译通过；Chief 过目 |
| 3 | 原生组件与玻璃质感全面改造 | 未开始 | 依赖阶段 2 |
| 4 | 视频融入 + 动效特效 | 未开始 | 视频位 A 已定，可与阶段 3 并行部分推进 |
| 5 | 整体验收（Chief 循环验收至满意） | 未开始 | 按 §0 五条标准 + D 表 ACC-01~10 |

### 阶段 2 分工与状态（随报随登）

| 成员 | 任务 | 状态 |
|---|---|---|
| 后端开发 | BE-001 核验改后台异步（请求路径只读本地权益，不再同步打 RevenueCat 卡 12 秒）；BE-004 改指数退避自动重试（弱网恢复自动续同步）；改完跑云端编译 + 登记台账 | **已修复待验**；云端编译已通过（run 42461169469，IPA `dist/BojiClub-ffe4a1ed.ipa`），等测试验收复验 |
| 苹果开发 | 材质收口 17 处（15 处 + RemoteConfigNoticeView、ProfileView 补 2 处）→ git 提交推送 + 云端编译；P0 必改 BUG-001（通知深链）、BUG-003（输入串轨，随 IOS-001/002 原生化关闭）；拿到 Hero 视觉稿后接视频关 BUG-005 | **第一批已提交（c3cf75d）**；第二批（BUG-003/005/010/011/012）已改完待提交，提交后请测试验收重跑云端编译 |
| 运维支付 | BE-002/BE-003 部署配置核查 → **已完成**：根因 deploy.sh 配置模板缺键，源码已改（21 键契约 + 校验脚本 + 测试 21 键全过），线上补键清单交 Chief（OPS-003）；TestFlight 步骤指引已出（前提更正：需 $99 付费账号），待用户回「1/2/3」 | 已回报，待用户选链路 |
| 界面设计 | 首页 Hero 卡视觉稿（视频底层静音循环/离开暂停/减少动态显静态帧 + 玻璃卡 + 渐变护字 + BUG-005 落地要点），出好 @苹果开发 | 进行中 |
| 测试验收 | 据 DEC-1/DEC-2 更新 D 表 ACC-02/ACC-04；等修复报上来做复验回归 | 进行中 |
| 文档管理 | 三个决定登记、阶段 2 修复状态随报随登（本表） | 进行中 |

### 事项状态

| 事项 | 负责人 | 状态 |
|---|---|---|
| Bug 全量排查清单（首轮 BUG-001~009） | 测试验收 | 已完成首轮，待真机复核 |
| 自绘控件与流程不通点清单 | 苹果开发 | 进行中 |
| 接口/数据侧问题清单 | 后端开发 | 已完成摸底，8 项入 B3 表 |
| 视觉与动效规范（含视频融合方案） | 界面设计 | 已交付（DES-001~003）并通过阶段 1 验收；**视频位已定 A（DEC-1）**，Hero 视觉稿已出，待苹果开发接入后关 BUG-005 |
| 真机安装链路 | 运维支付 | **推荐 1 TestFlight（DEC-3），待用户回复 1/2/3**；更正：1、2 均需 $99/年付费账号，3 零账号；链路生效前真机验收项挂起，模拟器验收不受影响 |
| 本文档 | 文档管理 | 台账运行中：三决定已登记，阶段 2 状态随报随登 |

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
- 2026-11-08：**苹果开发第二批修复完成待提交**：BUG-003 输入串轨（删 ClubNumericKeypad 自绘键盘与 keypadWeight 双轨，ClubNumericField 改原生 TextField+sanitize，LiquidCheckbox 改系统符号按钮）、BUG-005 Hero 视频接入（DES-003 方案 A，brand-video.mp4 已入 bundle 并注册 pbxproj）、BUG-010/011 横幅修正（training 文案如实、带「知道了」关闭、改 safeAreaInset 不压顶栏）、BUG-012 JourneyComponents 三处散写玻璃分支收口 clubNativeGlassButton；台账 A/B1 表状态已同步更新。
- 2026-11-08：**云端编译恢复通过（后端开发）**：逐次抓取 xcodebuild 错误行，定位并修复 4 处阻塞编译的问题——`AppStore.swift` 的 `ClubNotificationRoute` 补 `Equatable`（`onChange` 需要）、`TrainingRegistrationViews.swift` 的 `Button(action:) label:` 改回 trailing closure、`ClubAIShell.swift` 的 TimelineView 闭包内非法 `return` 去掉、`VideoPlayer` 无 `videoGravity` 改用 `AVPlayerLayer` 封装（`resizeAspectFill` 铺满）。**workflow run 42461169469 编译成功，IPA `dist/BojiClub-ffe4a1ed.ipa`（37.44 MB）**，已提交推送（`7cb0b97`）。BE-001/BE-004 修复保持「已修复待验」，等测试验收复验。
