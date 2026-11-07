# BOJI CLUB · AI 主界面与原生液态玻璃升级交付说明

日期：2026-10-25。工程版本：0.15.1 / Build 115。证据目录保留原执行日期 20261024。

> **代码范围已完成；关键流程验证通过，默认侧栏自动无障碍审计与滚动 CPU 回归仍未关闭，因此不宣称全部验收通过。按用户最新要求停止追加检测与视频制作。**

本轮在上一轮 V2 缺陷修复版本之上实施用户确认的《BOJI CLUB · AI 主界面与原生液态玻璃升级方案 V1.0》。新构建固定采用 AI 主界面，顶部保留 `Club AI / 训练` 两个工作区；旧首页、五 Tab 与旧首页回退路径已移除。生产服务器未部署，未执行生产数据迁移，也未上传 TestFlight。

此前 [V2 修复说明](REPAIR_V2_20261024.md) 中关于“关闭新首页开关回旧首页”的安排已被本轮产品决定替代；其提案确认、版本冲突、幂等、账号缓存隔离及服务端修复继续保留。本说明优先于历史文档中的旧导航与功能开关描述。

## 1. 最终行为与实现位置

| 范围 | 本轮实现 | 主要代码 |
|---|---|---|
| 唯一主入口 | 登录、会员校验完成后固定进入新 Shell；`ai_native_home=false` 或 `BOJI_V2_SHELL=0` 都不会恢复旧首页。AI 服务关闭时在同一界面提示不可用，训练和记录仍可进入 | `BojiClubApp.swift`、`ClubAIShell.swift` |
| 原生顶部 | 系统 `ToolbarItem`、SF Symbols、原生 `Picker(.segmented)`；辅助功能大字号采用系统菜单选择器；再次点选当前 AI 段不退出对话；训练右侧提供真正的计划/创建/动作库菜单 | `ClubAIShell.swift` |
| 空态工作区 | 一句欢迎语；优先显示今日/进行中训练，否则显示一项有效洞察；最多两个轻量快捷任务；移除旧视频与多卡仪表盘 | `ClubAIShell.swift` |
| 统一输入 | 空态与会话共用 `ClubSharedComposer`；原生多行文本编辑、焦点恢复、发送状态、临近上限字数提示；无效、忙碌与超限输入不能发送 | `SharedComposer.swift`、`ClubCoachView.swift` |
| 语音与真实记录入口 | 点击语音后打开原生表单，再由“开始录音”明确启动设备识别；结果可编辑后填回草稿，发送仍需用户确认。`+` 进入现有照片饮食、手动饮食和体重流程 | `SharedComposer.swift`、`MealEditorView.swift`、`BodyWeightView.swift` |
| 消息流 | 用户消息靠右轻气泡，AI 正文直接排版；来源折叠；业务卡独立插入；支持复制、反馈、分享、再次编辑提问；上翻时不强拉到底部，提供回到最新消息按钮 | `ClubCoachView.swift`、`AICards.swift` |
| 侧栏与历史 | 系统 `List/Section/searchable`、新对话、可恢复草稿、最近三条与全部历史、继续同步更多历史、打开与删除菜单。搜索匹配已同步的提问、AI 回复与本账号草稿；未同步旧对话可继续加载 | `ClubAIShell.swift` |
| 手机与平板 | iPhone 使用左侧原生内容抽屉，支持边缘打开、左滑关闭、遮罩关闭与 VoiceOver 焦点；常规宽度使用 `NavigationSplitView`。App 与 Widget 支持 iPhone/iPad，保留最低 iOS 17 | `ClubAIShell.swift`、工程配置、`Info.plist` |
| 玻璃与系统弹层 | iOS 26+ 的自定义浮动区域使用真实 `glassEffect`、`GlassEffectContainer`，独立按钮使用系统玻璃样式；较早系统在相同 UI 中采用系统材质。表单、菜单、确认框与 Sheet 采用系统呈现 | `Design.swift`、`BojiComponents.swift`、相关表单页面 |
| 底部恢复与训练 | Composer 和训练恢复附件由同一个 Bottom Dock 协调；不再叠加重复 AI 胶囊。组间休息、暂停恢复、Live Activity 与训练业务服务复用已有实现 | `ClubAIShell.swift`、`TrainingRegistrationViews.swift` |
| 首次计划与分享 | 独立首份计划页恢复原任务、追踪替换任务、打开真实计划预览与确认、重试完成加入；分享渲染与预览从旧首页迁出，保留报告/训练/Club 导出 | `FirstPlanPreviewView.swift`、`OnboardingView.swift`、`ReportShareViews.swift` |

使用指南与空态提示已同步新入口：顶部 Club AI / 训练，侧栏“我的记录 → 身体 / 报告”、俱乐部、AI 记忆与“我的”；身体概览设置不再标注为旧首页指标。仅更新引导文字与标签，不改变记录或报告生成行为。

玻璃集中在导航、浮动输入、侧栏容器和操作附件。AI 正文、训练数值、组数、图表与已保存记录保持清晰内容表面。降低透明度或增强对比度时采用明确的内容表面；减少动态效果时取消抽屉过渡动画。原生控件接管选择与交互反馈，不对系统 Picker 额外叠加玻璃背景。

## 2. 状态、账号与业务保护

- `ClubCoachSession` 由 Shell 持有，保存当前会话、草稿、滚动锚点、发送消费标识和错误状态。AI 与训练各有独立导航路径，训练日历展开状态与滚动位置保存在 Shell 中；切换工作区不再把整棵视图移到屏幕外十万点。
- 启动新对话时可保留当前输入为侧栏草稿；草稿按账号与会话隔离。清除某个账号本机数据会删除该账号的索引草稿和旧版本未建索引的草稿，不清除其他账号草稿。
- 删除会话先经系统确认，写入既有删除任务清单并移除对应草稿；已确认的训练、饮食和体重业务记录不受会话删除影响。持久化失败时保留会话并恢复原状态。
- 待确认饮食/体重草稿、改期预览、最终确认、幂等重试与过期/版本冲突仍使用上一轮修复后的执行入口。UI 动效不提前提交业务变更。
- 保留训练深链、通知路由、收起/恢复正在训练界面、休息截止时间与 Live Activity 同步。跨午夜时继续使用进行中训练的实际日期；训练完成后再推进今天，不把旧日训练写到新一天。
- 账号切换清空临时路由、当前会话、导航和弹层状态。首次引导在安全的前台状态重试展示，避免与记录/计划弹层叠加。
- 新客户端的 `FeatureFlagService.aiNativeHome` 固定为兼容值 `true`。服务端字段暂时保留给旧客户端，后台已标注“旧客户端首页兼容开关”；AI/Club 功能可用性开关继续生效。

## 3. 删除、提取与工程清理

| 动作 | 文件/资源 | 说明 |
|---|---|---|
| 删除 | `BojiClub/HomeView.swift` | 旧仪表盘、视频训练舱、旧首页专用呈现与状态随之移除 |
| 删除 | `BojiClub/HomeWorkoutVideo.swift`、`HomeWorkoutLoop.mp4`、`HomeWorkoutPoster.png` | 同时移除 Xcode 编译与资源引用 |
| 删除 | `BojiClub/ScreenshotBranding.swift`、`Assets.xcassets/ScreenshotBrandIcon.imageset/` | 移除附加 UIWindow，不再覆盖系统状态栏 |
| 删除旧类型 | `MainClubView`、`ClubTab` | 原五 Tab 与旧首页分支不再编译；调试 home 入口也指向新 Shell |
| 新增提取 | `BojiClub/ReportShareViews.swift` | 原分享组件提取内容保持一致；导出卡仍保留 BOJI CLUB 品牌 |
| 新增提取 | `BojiClub/FirstPlanPreviewView.swift` | 首次计划的真实恢复、预览、采纳与完成加入流程 |
| 新增组件 | `BojiClub/SharedComposer.swift` | 所有 AI 状态和独立对话页共用同一输入组件 |
| 更新配置 | `BojiClub.xcodeproj/project.pbxproj`、`BojiClub/Info.plist` | 注册新文件、删除旧资源、启用 iPad 与其方向配置；最低版本仍为 iOS 17 |

`BojiClubWidget/TrainingShared.swift` 继续由 App 与 Widget 共享编译，未删除。项目中的其他 SOURCE-MANIFEST、历史 Build 文档与旧阶段截图属于历史材料，不用于证明本轮验收。

## 4. 升级方案验收映射

| 原方案验收项 | 已实现与已验证 | 保留边界 |
|---|---|---|
| 1. 所有状态只出现新壳 | Root 无旧首页分支，退休开关不影响入口，AI 关闭时保留记录；入口/功能开关用例通过 | 未改变登录与会员验证服务 |
| 2. 首份计划与分享完整 | 独立预览恢复、确认写入、完成加入重试；分享组件提取，源码契约与规则回归通过 | 真实账号完整加入、系统分享目标仍需设备验收 |
| 3. 原生顶部且无重复导航 | 系统分段与统一工具栏，记录弹层只有一个可见导航；iPad 侧栏重复按钮已修正并截图复验 | 系统不同版本外观需设备确认 |
| 4. 所有状态共用 Composer | 键盘、会话、手动饮食、体重、语音表单及实际记录入口用例通过 | 设备麦克风授权、语音语言与音频打断未实测 |
| 5. 多次切换保持状态 | 外置会话/训练路径、日历与锚点、持久草稿；20 次切换与草稿恢复通过 | 不代表操作系统强杀后的所有场景 |
| 6. 历史搜索与侧栏隔离 | 历史、搜索、分页、删除确认和草稿恢复已实现并验证 | 侧栏自动像素无障碍审计仍未通过，见下文 |
| 7. 历史阅读不抢滚 | 跟随只在用户保持最新位置时启用；键盘变化仍跟随最新消息，小屏左右边距有断言 | 本轮未继续制作视频 |
| 8. 确认与冲突语义不变 | 沿用修复后的提案/命令入口，取消、最终确认、幂等和冲突规则回归通过 | 未运行生产变更 |
| 9. 训练/离线/后台恢复 | 保留训练服务、单一恢复附件、通知与跨日路由；训练相关回归通过 | 真机锁屏、强杀、APNs 与 Live Activity 后台表现待验 |
| 10. 多尺寸、深浅色与无障碍 | 小屏、主机型、较大机型与 iPad；深浅色、辅助字号 AX3/AX5 和增强对比度流程已验证 | 大字功能通过不能抵消默认侧栏审计失败；旧 iOS 运行待验 |
| 11. 静默打开不启录音/覆盖状态栏 | 录音需明确按“开始录音”；额外状态栏 UIWindow 已删除 | 真机权限与其他 App 音频行为待验 |
| 12. 可比较性能 | 相同 SE3 模拟器与 Debug 配置完成前后测量，原始指标与日志保留 | CPU 有回归，未获得掉帧/hitch 数据，未完成全部性能验收 |

## 5. 验证记录

环境为 Xcode 26.6（17F113）、iOS 26.5 SDK/模拟器，最低部署目标 iOS 17。以下记录仅陈述实际执行范围。

| 检查 | 结果 | 证据 |
|---|---|---|
| Debug 模拟器无签名构建 | 最新布局修正后 `TEST BUILD SUCCEEDED` | `logs/build115-layout-final-summary.log` |
| TestFlight 配置模拟器无签名构建 | 最后视觉修正前 `BUILD SUCCEEDED`；按用户要求停止最后一次追加重建，最终视觉修正仅有 Debug 构建与专项结果 | `logs/build115-testflight-final-summary.log`；不代表上传 TestFlight |
| 原生 XCTest | 47/47 通过 | `logs/build115-unit-flows.log` |
| Python 离线回归 | 666/666 通过；迁移旧首页契约，保留业务断言 | `logs/offline-build115.log` |
| Swift 规则回归 | 52/52 组通过 | `logs/swift-rules-build115.log` |
| 原生 UI 回归 | 首轮 37 例中 30 例通过，7 个失败项中已修复并复验 6 项；默认侧栏审计仍未通过 | `logs/native-full.log`、后续专项日志；不标记整套通过 |
| 最后布局复验 | iPhone 17、小屏 AX5、iPad mini 流程通过；小屏聊天边距与键盘后跟随有断言，20 次切换通过 | `logs/layout-iphone17.log`、`logs/layout-small-ax5.log`、`logs/layout-tablet.log` |
| 多尺寸与显示模式 | 已有小屏深色、AX3/AX5 增强对比度、iPad、较大机型深色截图 | `screenshots/`、`screenshot-index.json`；较早截图不用于证明最后布局修正 |
| 性能比较 | 启动、静置 RSS 和滚动持续时间下降；滚动 CPU 时间增加，未获掉帧指标 | `performance/performance-comparison.md` |

证据保存于 `docs/native-ui-20261024/`。按用户最新要求，已停止追加检测、最后一次 TestFlight 重建与视频制作；交付不含视频，已有验证记录保留。DerivedData、模拟器容器、SourcePackages、测试数据库及运行时缓存不属于源码交付。

### 尚未关闭的侧栏审计

默认侧栏的 `.all` 自动审计仍报告三个 `element=nil` 对比度问题、草稿标题对比度问题，以及两个没有元素定位的“大字号可能裁切”预测。实际草稿标题截图测得约 15.81:1，字形完整；这只能说明该次截图中的标题可读，不能证明所有未知问题是误报。增强对比度审计也未全部通过，未增加类别豁免。

最大辅助字号 AX5 的实际导航、输入和自然滚动流程通过，但不能据此关闭上述自动审计问题。保留 `diagnostics/sidebar-ax-triage.md` 和像素分析作为复核依据；当前没有连接真机，也没有可用签名身份。

### 性能结果与限制

相同 iPhone SE 3 / iOS 26.5 模拟器、相同种子与 Debug arm64 配置，各测五次：启动均值 **1.479 → 1.324 秒（−10.5%）**，独立测量的静置 RSS 均值 **330.73 → 315.14 MiB（−4.7%）**，滚动 signpost 持续时间 **0.994 → 0.947 秒（−4.7%）**。

同时，滚动 CPU 时间 **0.304 → 0.448 秒（+47.2%，约增加 144ms）**，指令数增加约 38%。尚未做采样归因与优化，不能宣称性能全面改善。模拟器没有返回 hitch、帧率或掉帧数，记为未获得数据，不记为零。该比较来自最终布局微调前的 Debug 阶段，不是 Build 115 真机发布性能；原始日志与 JSON 见 `performance/`。

### 可重复运行的命令

在本项目根目录执行。`<设备UDID>` 取自本机 `xcrun simctl list devices available`；输出目录放在源码目录之外，避免将构建缓存打入交付包。

```sh
python3 tests/run_offline.py
python3 tests/run_swift_regressions.py --output /absolute/path/to/swift-rules --jobs 3

xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<设备UDID>' \
  -derivedDataPath /absolute/path/to/DebugDerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight \
  -configuration TestFlight \
  -destination 'platform=iOS Simulator,id=<设备UDID>' \
  -derivedDataPath /absolute/path/to/TestFlightDerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<设备UDID>' \
  -derivedDataPath /absolute/path/to/DebugDerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

性能对比必须使用相同设备、系统版本、种子数据、功能状态和构建配置，并串行运行。基线版本采用此前交付的 `BojiClub-V2-fixed-20261024.zip`；不要用历史报告里不同环境的数字替代本次基线，也不要将 Debug 模拟器数据当作真机发布性能。

## 6. 实现边界与目标环境待验

本轮落实已确认 UI 方案，未新增后端流式协议。聊天仍呈现真实的提交、处理、完成与失败状态；没有将打字动画称为流式返回。服务端未提供可确认的取消任务能力，因此不展示虚假的“停止生成”按钮。

当前照片入口用于现有饮食记录流程；本轮未引入任意文件上传、通用聊天图片附件或附件多模态会话。输入组件只显示实际可用的照片/手动饮食/体重及设备语音功能。语音录音不上传，明确开始后才启用识别；真实设备授权、识别语言可用性、打断/来电与其他 App 音频行为仍需真机确认。

仍需目标环境验收：真实 Apple 登录/撤销、StoreKit/RevenueCat Sandbox 购买与会员恢复、HealthKit 授权与写入、APNs、锁屏/强杀/后台恢复、真机 VoiceOver 与动态字体/iPad 分屏，以及较早 iOS 的实际运行。API 可用性判断和最低版本编译通过不能替代这些设备测试。

当前工程版本已递增至 Build 115；发布前继续按项目既有流程完成签名与正式构建；本说明不代表已经部署、提交商店或运行生产迁移。UI 取消旧壳后，AI 故障应在相同新界面中降级，不能重新挂回已删除的五 Tab 首页。
