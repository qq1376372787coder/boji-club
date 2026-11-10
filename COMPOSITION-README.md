# BOJI 页面构图改造 · 2026-10-20

从用户提供的 `BojiClub-V2.0-Fully-Completed-20261020 (2)_副本.zip` 解包后改造。当前工作以用户本次布局要求为准；包内历史任务书、验收报告和版本清单保留为项目背景，不能作为本次验收结论。

## 查看成果

相邻 `DesignReview/index.html` 是评审入口，包含实际运行的前后截图、逐页十问及小屏/辅助字号入口。`Page-Composition-System.md` 定义七种构图原型；`wireframes.html` 比较七个核心页面各两种方向。`Validation.md` 记录本轮验证，`覆盖边界.md` 单独列出尚未完成的真实设备、交易、素材与错误状态验证。

本次主要变更在首页、计划中枢、实时训练、饮食、身体、统计、成长、收藏、资料、动作库、报告库与 AI 设置。改变的是信息优先级、组合与渐进展开；保留训练确认、实际组保存、日程调整、数据口径与账户操作逻辑。未部署服务器或更改服务配置。

## 运行项目

用 Xcode 打开 `BojiClub.xcodeproj`，选 `BojiClub` Scheme 和 iPhone 模拟器。现有第三方依赖沿用原项目的 Package.resolved。实际账号运行、签名和服务设置继续使用项目原有配置。

Debug 本地样本：Scheme → Run → Environment Variables：

- `BOJI_PREVIEW_ACCOUNT=complete`
- `BOJI_UI_TEST_SEED=1`
- `BOJI_AUDIT_SCREEN=home`（仅在需要独立页面审计入口时添加；正常五标签界面省略该项）

审计入口、扩展样本和参考报告由 `#if DEBUG` 包裹，不进入 Release。完整路由见 `BojiComponentGalleryView.swift` 中 `BojiAuditHost`；样本并非真实业务数据。

## 构建与回归

本次使用 Xcode 26.6、iOS 26.5，Debug 构建及 13 项常规 UI 测试及1项小屏 AX3补充测试通过。具体设备、Release 构建和截图覆盖见相邻评审目录的验证记录。没有 iOS 27 的运行结论。

```sh
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug -destination 'platform=iOS Simulator,id=YOUR_UDID' -derivedDataPath /tmp/boji-composition -jobs 2 build-for-testing CODE_SIGNING_ALLOWED=NO
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug -destination 'platform=iOS Simulator,id=YOUR_UDID' -derivedDataPath /tmp/boji-composition -parallel-testing-enabled NO -skip-testing:BojiClubUITests/BojiClubUITests/testAuditScreenshots test-without-building CODE_SIGNING_ALLOWED=NO
```

截图与像素比较工具见 `scripts/composition/README.md`。使用独立模拟器，以免覆盖个人测试数据。自动化不负责判断品牌审美；日期、报告生成时间和异步内容变化需要人工解释。

`COMPOSITION-SOURCE-MANIFEST.json` 记录本次修改的 Swift 文件与哈希；`DesignReview/layout-changes.patch` 是对上传源码的差异，包含 UI 测试。旧的 SOURCE-MANIFEST 等文件是历史记录。
