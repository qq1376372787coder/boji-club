# 截图与回归

仅使用独立模拟器和 Debug 构建。工具使用本地预览账号，不连接真实账号服务器；AuditHost 和样本数据不编入 Release。先在 Xcode 用 BojiClub Scheme 构建并安装到模拟器，再运行：

```sh
python3 scripts/composition/capture.py --device YOUR_SIMULATOR_UDID --phase candidate --output ../DesignReview/screenshots --deny-camera
python3 scripts/composition/capture.py --device YOUR_SIMULATOR_UDID --phase candidate --output ../DesignReview/screenshots --native-shell
python3 scripts/composition/capture.py --device YOUR_SIMULATOR_UDID --phase candidate --output ../DesignReview/screenshots --accessibility --routes home,plans,workout,nutrition,ai,club,body,profile
```

相机拒绝授权截图验证的是备用流程；真实拍摄与系统授权需在真机另行验证。第一次使用可能显示使用指南；在模拟器选择稍后再看后再采集。工具检测到系统打开确认、权限提示或空白画面会拒绝该截图，不把它计为视觉通过。

`VisualText.swift` 仅使用系统 Vision。控制器通过 App Documents 中的临时文件切换实际 SwiftUI 页面，等待页面报告 ready，再检查画面。退出时清理控制文件并恢复字体设置。主导航另用 `--native-shell` 验证真实 TabView、安全区域和 Toolbar。

在 375×667 与常规 iPhone 上分别采集，固定系统字号、外观、状态栏、语言和同一组样本。截图 SHA-256 用于基线追踪；像素变化只用于发现变化，不能代替构图评审。

`BojiClubUITests` 中 `testComposition*` 覆盖首屏行动、组表可达性、营养展开、统计切换和长名称键盘状态。已有训练确认、部分保存、迷你训练条、计划月历等测试继续保留。不要把全部页面强制套成同一模板，也不要用像素差异比例自动评判美感。

小屏截图使用独立目录，避免覆盖常规模拟器的基线：

```sh
python3 scripts/composition/capture.py --device SMALL_UDID --phase after --variant small --output ../DesignReview/screenshots --routes home,plans,workout,nutrition,club
python3 scripts/composition/capture.py --device SMALL_UDID --phase after --variant small-accessibility --accessibility --output ../DesignReview/screenshots --routes nutrition,workout
python3 scripts/composition/compare.py ../DesignReview/screenshots/before/standard ../DesignReview/screenshots/after/standard --output ../DesignReview/visual-diff.json
```

比较器仅比较同名、同尺寸图片，记录 SHA-256、超过 16/255 的像素变化比例与平均 RGB 差异，不自动给出视觉通过结论。截图采集器拒绝空白或系统遮罩；横向裁切和错误折行仍须人工复核。样本日期相对实际运行日生成，报告生成时间也会变化；跨日期回归需人工区分时间文字变化与布局变化。本次基线日期为 2026-10-20。

本工具覆盖指定首屏。需要检查折叠后、键盘出现、保存后等交互状态时运行 UITests，并审阅测试附件。协议长正文不因首屏采集而视为全文视觉验收。

文字边缘初筛：

```sh
python3 scripts/composition/check_edges.py ../DesignReview/screenshots --output ../DesignReview/layout-edge-flags.json
```

使用 Vision 文字框检查横向边缘附近的疑似裁切，排除顶部与底部导航区域。横向滚动筛选、装饰和识别错误可能误报；无标记也不能证明没有溢出。以人工复核、不同字号截图及可达性交互测试共同判断。
