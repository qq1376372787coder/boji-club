# Build125：13 项训练与 AI 体验修复

日期：2026-10-26。版本：0.15.6（125）。基于本次交付的 Build124 源码继续修复。

## 本次改动

| 用户问题 | 交付行为 | 主要代码 |
|---|---|---|
| 1 加速按钮含义不清 | 删除“启用 DeepSeek + MiniMax 加速”。原功能实际是更新云端分析接收方授权；旧授权用户发送时才展示一次正确说明，同意后续发。模型路由由后端处理。 | SharedComposer.swift、AIContextReference.swift |
| 2 invalid_output | 明确传入真实可引用来源；修复空业务调用列表被拒；结构错误可在原总超时预算内补正一次。保留证据、安全和接收方授权校验，客户端显示可理解的失败说明。 | backend/ai_core.py、coach_core.py、AIRunStream.swift |
| 3 数字录入 | 直接点击当前重量/次数格，弹出 UIKit 原生小数键盘，原位输入；不再自动弹出大编辑页。次数/秒数仍须正整数。 | WorkoutExperience125.swift |
| 4 完成圆圈 | 校验并直接保存当前输入；未填写的目标不冒充实记。重量可填 0 表示自重，支持 1.25、2.5。 | TrainingSetDraft125、TrainingInlineSetRow125 |
| 5 训练胶囊 | 品牌 Logo、活动计时、“点击返回训练”和实记组数；沿用暂停感知计时。 | ClubAIShell.swift |
| 6 难懂的更多选项 | 取消训练页“训练依据与更多选项”；同日再练仅放在完成训练后的顶部更多菜单。 | WorkoutView.swift |
| 7 结束确认 | 原生较大底部确认页，展示已登记/未登记数量及保存后行为。 | WorkoutFinishReview125 |
| 8 手表记录入口 | 收官页统计后、图表前立即核对手表记录；匹配未处理时优先关联，避免同时提示重复导出。导出确认也改为原生 sheet。 | WorkoutView.swift、HealthViews.swift |
| 9 完成仪式和图表 | Logo 收官视觉、轻量动画、6 项真实统计、实记/未登记环图、逐动作条形图及逐组记录入口。 | WorkoutCelebration125、WorkoutFacts125、WorkoutCharts125 |
| 10 待处理事项 | 删除训练首页该区块。 | ProductArchitecture.swift |
| 11 训练入口布局 | 统一动作库/我的计划按钮的高度、内边距、行间距，换用专用线条图形。 | ProductArchitecture.swift、TrainingEntryGlyph125 |
| 12 虚假完成状态 | 日历动作按有效实记统计，显示“已登记 x/y 组”；仅该动作全部有效完成才打勾。完成统计不计未登记目标。 | PlanHubViews.swift、WorkoutFacts125 |
| 13 上传照片入口 | 默认进入相机；相机不可用/拒绝授权时明确说明，由用户主动选相册，不再静默改开相册。选图/拍照结果绑定原账号和会话。 | SharedComposer.swift、ClubChatCamera125 |

## 验证与边界

- Python 69 项定向测试通过；Swift 25 项定向测试通过。
- 模拟器定向 UI 检查覆盖小数键盘原位输入、圆圈保存、训练胶囊返回、部分完成收官统计、图表、相机入口。完整结果和失败后修正过程见独立报告与 evidence。
- 真实 DeepSeek、MiniMax 和 Router 各 1 次合成记录烟测成功；不等同于 200 条全业务验收。结构修复保留失败尝试与计费信息；不保证第三方模型永远返回成功。
- 后端两个文件已部署到现有服务器，SHA256 对应本源码，服务健康检查通过；无数据库迁移，未写生产测试训练记录。
- iOS 页面改动必须安装 Build125 才能看到。本次没有上传 TestFlight。
- 真机相机拍摄、Apple Watch 匹配及 Apple 健康写入需要支持设备和真实授权，模拟器不能替代这部分验收。
- 未运行 200 条大批量测试，交付不含视频。

旧 Build124 交付说明和哈希清单保留在 docs/historical-build124，仅作为历史资料；当前源码以 BUILD125_SOURCE_MANIFEST_SHA256.json 为准。
