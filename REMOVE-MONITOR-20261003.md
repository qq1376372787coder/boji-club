# 移除阿里云监控：0.13.14 / build 33

用户决定不再使用阿里云监控。本版本完整移除该接入，而不是通过忽略头文件错误保留半套实现。

## 已移除

- AlicloudApmAll、AlicloudApmCore、AlicloudApmCrashAnalysis、AlicloudUTDID 的 Podfile 依赖和阿里云 Pods 源。
- EMASMonitorBridge.m/.h、仅供该桥接使用的 BojiClub-Bridging-Header.h、DiagnosticsMonitor.swift，以及相关 Xcode 文件/编译项。
- 仅用于启动诊断的 AppDelegate 适配器、启动后的诊断同意弹窗、登录页和“我的”页诊断入口。
- 配置复制构建阶段、EMAS_CONFIGURATION_FILE、监控配置模板和复制脚本；删除仅供该接入使用的桥接、非模块头文件及 -ObjC 构建设置。
- 当前隐私说明中的可选监控章节和服务商条目；App 隐私清单中的 CrashData、PerformanceData、OtherDiagnosticData。购买 SDK 仍使用设备标识，因此 DeviceID 声明保留。

## 构建

请解压新包到新目录，直接打开 BojiClub.xcodeproj，选择自己的签名团队和 Bundle ID 后构建。RevenueCat 通过本地 Swift Package 引用 Vendor/RevenueCat，继续保留，不需要 CocoaPods。

建议使用新目录，避免旧工作目录中的 Pods、xcworkspace 和 CocoaPods 自动生成构建项继续参与构建。不要将旧目录下的 Podfile、Pods 或顶层 BojiClub.xcworkspace 复制进来。迁移你自己的签名/Bundle ID/RevenueCat 公钥等配置即可。无需卸载手机上现有 App，也不要为了修复构建删除手机中的记录。

Mac 上可运行 bash scripts/check-on-mac.sh，脚本已改为直接使用 -project BojiClub.xcodeproj 构建 Debug/Release，不调用 pod install。

## 保留与验收

AI Insights 彩色标题、动画、Club Keepsake、训练饮食、健康、AI 与会员购买的现有业务流程保留；后端、第三方购买 SDK、图片与 Widget 源码不修改。本轮不增加其他监控服务。

全部剩余 32 个 App/Widget Swift 文件语法解析、Xcode 工程结构/引用完整性、Plist 与隐私清单格式检查、监控残留引用检查、交付包完整性检查通过。记录见 remove-monitor-v12/verification.json，差异见同目录 source-review.patch。

Windows 没有 Xcode，尚未完成 Mac 类型检查、真机与实际性能验收；这些静态检查不表示整个 App 已编译通过。全面代码审查仍未结束。

旧版本报告与历史差异仍可能提到 EMAS，这些文件仅供追溯，不是当前接入或构建说明。以本说明、README_先读我.md 和 BUILD-STATUS.md 为准。
