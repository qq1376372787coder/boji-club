# iOS 17 兼容调整：0.13.26（45）

2026-10-07。按用户选择，将最低支持系统改为 iOS 17.0。

## 改动

- BojiClub.xcodeproj/project.pbxproj：项目、App 与 Widget 六处 Debug/Release 的 IPHONEOS_DEPLOYMENT_TARGET 从 26.0 调整为 17.0；四处版本/构建号更新为 0.13.26 / 45。
- scripts/check-on-mac.sh：保留模拟器 Debug/Release 构建，增加未签名 iPhone Release 构建，并从编译产物读取 App 和 Widget 的 MinimumOSVersion，要求都为 17.0。
- 更新当前交付说明；旧报告保留其原版本和验证范围。

## 系统 API 核对范围

查看 App 和 Widget 的全部自有 Swift 文件，整理系统调用并检查版本敏感接口：

| 使用处 | iOS 17 基线 |
| --- | --- |
| NavigationStack、PhotosPicker、ImageRenderer、Task.sleep(for:) | 基线覆盖，无需改写 |
| Swift Charts，包括 SectorMark 环形图 | iOS 17 支持 |
| ContentUnavailableView、双参数/initial onChange、sensoryFeedback、symbolEffect | iOS 17 支持 |
| Vision 前景抠图 VNGenerateForegroundInstanceMaskRequest | iOS 17 支持；算法失败继续走现有原图显示退路 |
| 相机 videoRotationAngle / isVideoRotationAngleSupported | iOS 17 支持 |
| HealthKit 睡眠阶段、AVFoundation/Photos/UIKit 基础调用 | 基线覆盖 |
| ActivityKit 使用 ActivityContent 的实时活动请求/更新/结束 | 基线覆盖；是否显示还取决于设备、权限与系统设置 |
| Widget containerBackground(for:) | iOS 17 支持 |
| iOS 26 glassEffect | Design.swift 中已用 #available(iOS 26.0, *) 包裹；else 使用材质背景 |
| 随包 RevenueCat | Package.swift 最低声明为 iOS 13；依赖不阻止 iOS 17 目标 |

这是一轮源代码和配置核对，不是 Apple SDK 的可用性类型检查。保留功能源码可以避免为降低最低系统版本额外改变保存、AI、支付和训练行为。Xcode 仍需包含 iOS 26 SDK，因为即使 glassEffect 被版本判断包裹，编译器也要认识这个 API；这不要求安装 App 的用户升级到 iOS 26。

## 本轮验证与边界

详细结果在 ios17-v26/verification.json；检查源文件引用、plist/entitlement/privacy manifest、资源 JSON、版本配置、业务源文件与 v0.13.25 的哈希一致性以及打包 CRC/哈希。

Windows 没有 Xcode 和 iOS SDK，未完成 SwiftUI/UIKit/HealthKit 的类型检查、链接、iOS 17 设备安装或运行。不能把配置/语法检查说成完整原生验收。

## Mac / 真机验收

1. 使用包含 iOS 26 SDK 的 Xcode 26+，运行 bash scripts/check-on-mac.sh。确认三种构建成功，minimum-os.log 中 App 和 Widget 都为 17.0。
2. 在 iOS 17 真机或可用的 iOS 17 模拟器上检查登录页与四个主要页面、弹窗、最大字号、深色模式和减少动态效果。不要只在最新系统测试。
3. 验证相机方向、相册选择、餐食图片/抠图、长文分页分享，以及体重和训练图表。
4. 在支持的设备上检查健康授权/读取、确认分享、训练关联、桌面小组件和实时活动；没有灵动岛的设备仍应有锁屏卡片，不假定所有设备都显示灵动岛。
5. 再在 iOS 26 或较新系统走同样路径，确认玻璃效果和新旧样式都正常。
6. 验证离线保存、恢复联网、账号切换和 TestFlight 购买/恢复。正式包名、签名、公钥、商品、Webhook 和协议需要另行按真实后台配置确认。

本轮不需要部署服务器或修改数据库。v0.13.25 原始交付目录保持独立。
