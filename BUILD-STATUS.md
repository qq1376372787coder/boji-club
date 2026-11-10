# 薄肌俱乐部 0.15.0 · Build 111

2026-10-18。基于 Build 110，完成首页、计划日历、训练恢复、Club AI、记录趋势的体验升级，并加入完整深色模式与 XCUITest 关键路径。

请打开**本目录**的 `BojiClub.xcodeproj`，使用 `BojiClub-TestFlight` Scheme，确认 `MARKETING_VERSION = 0.15.0`、`CURRENT_PROJECT_VERSION = 111`。

完整改动、验证命令与未验收边界见 [Build 111 体验升级说明与测试报告](BUILD111-体验升级说明与测试报告.md)。

## 本轮完成

- 首页：身体状态卡 + 真实测量趋势、380/460pt 沉浸主卡、单条优先 AI 洞察。
- 计划：日历置顶、今天居中、周/月动画、日历内移动预览、休息日、创建入口分组；移除计划封面轮播。
- 训练：紧凑登记、休息暂停/继续、五 Tab 迷你训练栏、进程重启恢复、Live Activity 当前动作/暂停。
- Club AI：单层导航 Hub、优先洞察、今天/更早时间线、chip 筛选、共享依据披露、对话草稿。
- 记录：3/6/12 月/自定义/累计趋势；确认训练口径；体重多尺度。
- 深色模式：语义色动态化，移除强制浅色。
- 新增 `BojiClubUITests` target，5 条关键路径在浅色/深色下均通过。

## 验证结果

- `sh scripts/check-upgrade-on-mac.sh`：退出码 0，全部 Swift 规则测试通过，TestFlight simulator build 成功。
- `python3 -I tests/run_offline.py`：580 项通过。
- `sh scripts/check-experience-v150-ui.sh`：5/5 通过（浅色与深色各一次）。
- 截图：`build111-evidence/screenshots/`（浅色/深色各 6 张）。

## 尚未验证

- 真机（Live Activity、视频后台恢复、实际触控）。
- iOS 17 runtime 与小屏设备（本机只有 iOS 26.5 / iPhone 17）。
- Live Activity 内交互暂停、跨设备暂停、Club AI 图片理解等已明确延后。
- 服务端同步契约未变，本轮未重新部署；Build 110 服务端继续生效。
