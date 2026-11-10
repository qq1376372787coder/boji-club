# Phase 0 · UI 基线与冻结报告（UI_BASELINE_AND_FREEZE_REPORT）

> 本文件是后续所有 UI 变更的唯一基线。历史 V1.0/V1.1 的 ChatGPT 式设计稿不作为基线。

## 1. 冻结范围（用户已验收）

- Club AI 首页：欢迎态（“今天，想先做什么？”）、今日训练卡、快捷入口、底部 Composer。
- 顶部 `v2-mode-picker`：`Club AI / 训练`。
- 左侧栏 `v2-sidebar-toggle` / `v2-sidebar-panel`：记录、俱乐部、AI 记忆、我的、设置。
- 右上角新会话按钮。
- 聊天消息气泡、输入框、相机/语音/`+` 快捷入口、滚动与键盘避让。
- 训练中心/训练中、饮食、体重、周报、俱乐部、会员、后台的全部视觉与导航。
- 设计 token：黑白主色、雾灰蓝 `#E3E7F0`（`DesignTokens.swift:24`）、字体、间距、圆角、动效、层级。

## 2. 基线证据

| 项 | 内容 |
|---|---|
| Git 基线 | `313e91ed9afbdafb95cd1823c57ae5825337bc2d` |
| 源码哈希 | `docs/v2/ui_baseline_hashes.txt`（50 个 UI/设计/测试入口文件） |
| 启动截图 | `evidence/ui_baseline/launch_01.png` |
| 完整预览账号截图 | `evidence/ui_baseline/shell_complete_01.png` |
| 构建 | Debug 模拟器 `BUILD SUCCEEDED`（`evidence/xcodebuild_baseline.log`） |
| UI 测试入口 | `BojiClubUITests/BojiClubUITests.swift`（shell/侧栏/记录/训练/无障碍） |

截图采集条件：iPhone 17 / iOS 26.5；`BOJI_PREVIEW_ACCOUNT=complete`、`BOJI_PREVIEW_SKIP_GUIDE=1`、`BOJI_UI_TEST_SEED=1`。动态内容（时间、测试数据）允许合理差异，结构/布局/主题为判定重点。

## 3. 关键结构（代码定位）

| 元素 | 文件:行 |
|---|---|
| 应用入口/全局环境 | `BojiClub/BojiClubApp.swift:5-28` |
| 单一 Shell / 模式切换 / 侧栏 | `BojiClub/ClubAIShell.swift:1-120`、`:600-740` |
| 聊天页/Composer/滚动 | `BojiClub/ClubCoachView.swift:448-747` |
| 消息与卡片渲染 | `ClubCoachView.swift:613-699`、`AICards.swift:319-370` |
| 设计 token | `DesignTokens.swift:20-60`、`Design.swift` |
| 记录页入口 | `ProfileView.swift`、`BodyWeightView.swift`、`NutritionView.swift` |
| 训练页 | `WorkoutView.swift`、`TrainingRegistrationViews.swift` |
| UI 自动化 | `BojiClubUITests/BojiClubUITests.swift:1-120` |

## 4. 文件分类（供后续变更审计）

- `UI_FROZEN`（默认禁止修改）：`DesignTokens.swift`、`Design.swift`、`FlowDesign.swift`、`BojiComponents.swift`、`SharedComposer.swift`、`ClubAIShell.swift`（布局部分）、所有 `*View.swift` 的视觉结构。
- `UI_INTEGRATION_ONLY`（只允许最小数据接线）：`ClubCoachView.swift`（消息列表数据源/状态）、`AICards.swift`（解码/动作，不改视觉）、`AppStore.swift`/`AIService.swift`（数据层）、`ClubProposalSync.swift`。
- `NON_UI`：`account-server/**`、`backend/**`、`tests/**`、`migrations/**`、`docs/**`。

## 5. 本轮变更规则

1. 不改配色、字号、间距、圆角、动效、导航结构、页面层级。
2. SSE 增量文本只更新现有气泡内容；不得整页重排、改变滚动意图或打断第三方音频。
3. 新增 UI 仅允许“已有样式的最小追加”（例如在消息列表内用现有正文样式显示流式回答），并记录 `UI_CHANGE_EXCEPTION.md`。
4. 任何非必要视觉差异立即回滚，改用数据适配层。
5. 若功能与冻结 UI 冲突：后端先完成，前端 flag 关闭，记 `BLOCKED`。

## 6. 回归判定

- 对照本报告截图与哈希，检查首页、侧栏、顶部切换、输入框、训练/记录页。
- 动态字体、VoiceOver、深色模式、小屏、键盘安全区不回归。
- 最终输出差异清单与用例结果；不以“更现代/更统一”为改版理由。
