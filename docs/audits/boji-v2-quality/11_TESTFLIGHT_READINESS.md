# TestFlight 发布准入评估

评估日期：2026-10-20  
版本：0.15.0 / Build 112  
结论：**不具备“可直接提交并可对外使用全部功能”的条件。** 可以继续做内部技术验证，但必须先处理下列阻断项。

## 0. 官方发布检查脚本的本机结果

`python3 scripts/check-release-ready.py` 返回 `ready: false`：

- `api.gongxiang.cloud` DNS 失败；
- `dongzuo.gongxiang.cloud` DNS 失败；
- RevenueCat SDK 公钥通过；
- Apple 签名团队通过；
- 运营主体/协议确认失败；
- 用户可见协议仍为草案；
- `native_build_verified: false`、`store_purchase_verified: false`。

这与本文件的人工审计结论一致，不是脚本误报。

## 1. 已通过/已具备

| 项 | 状态 | 证据 |
|---|---|---|
| 源码可编译（TestFlight 配置，模拟器） | **通过** | 全部 iOS 改动后最终 `xcodebuild ... BUILD SUCCEEDED` |
| XCUITest 常规回归 | **14/14** | 首次 11/14，修复测试选择器/可访问性标识后全绿 |
| Debug/TestFlight 的 Swift harness | **51/51** | `run_swift_regressions.py` |
| App 图标 | 存在 | `Assets.xcassets/AppIcon.appiconset` |
| 启动界面 | 存在 | `UILaunchScreen` + `LaunchArtwork` |
| HealthKit 权限描述 | 存在 | `NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription` |
| HealthKit entitlement | 存在 | `BojiClub.entitlements` |
| Sign in with Apple entitlement | 存在 | `BojiClub.entitlements` |
| 隐私清单 | 存在 | `BojiClub/PrivacyInfo.xcprivacy` + Widget |
| 账号注销入口 | 存在 | 我的 → 注销账号 + `/me` DELETE |
| RevenueCat SDK/商品 ID | 存在 | 工程设置 public key；月度/年度/永久商品 ID |
| Release 日志/隐私 | 未见明显泄密日志 | 代码审计；后台不显示完整 AI key |

## 2. 阻断项（必须在对外内测前处理）

### R-01 P0：远程推送实际不可用

- `BojiClub.entitlements` **没有 `aps-environment`**；`project.pbxproj` 的 TargetAttributes 只声明了 In-App Purchase，没有 Push Notifications capability。
- `ClubRemotePush.swift` 调用了 `UIApplication.shared.registerForRemoteNotifications()`，但没有 entitlement 的包无法取得 APNs device token；服务端 `club_push_devices` 不会有真实设备。
- 服务端 `clubPushConfigured()` 还固定要求 `apns_topic === 'com.bojiclub.app.dev'`。
- **处理**：Apple Developer 为对应 App ID 开启 Push Notifications；补 Provisioning/APNs Key；在 Xcode 开启 capability（或让签名配置注入 `aps-environment`）；用真机获取 token 并完成一次沙盒/生产 APNs 送达。若本轮不做推送，应移除“允许手机通知/推送管理”相关承诺或明确标注未上线。

### R-02 P0：正式环境 API 域名不可解析

- Release 构建的 `productionBaseURL = https://api.gongxiang.cloud/account/v1`。
- 本机实测：`api.gongxiang.cloud` **NXDOMAIN**；`curl` 无法解析。
- TestFlight 构建使用 `https://117.50.119.49/account/v1`；**2026-10-21 已将本轮账号/管理后台选择性部署到该 IP 测试服**。线上实测 `/config` = 200（ETag 304）、无 token `/me` = 401、`/admin/` = 200；测试会员 `/me` = 200。
- 因此 TestFlight 的**服务端配置链路已上线**，但 Release 正式包仍指向不可解析的 `api.gongxiang.cloud`。
- **处理**：为 Release 恢复 `api.gongxiang.cloud` 的 DNS/证书/网关，或改用已部署且证书覆盖的正确域名；TestFlight 包仍使用 IP 测试服。不要把 IP 当作长期正式地址。服务端部署/迁移/测试会员记录见 `13_DEPLOYMENT_20261021.md`。

### R-03 P0/P1：Bundle ID 与发布环境未确认

- TestFlight/Release 均为 `com.bojiclub.app.dev`；Widget 为 `com.bojiclub.app.dev.widget`。
- APNs topic 硬编码为 `com.bojiclub.app.dev`；Apple 登录 audience 默认 `.dev`；App Group 为 `group.com.bojiclub.shared`。
- 如果 App Store Connect 的正式 App ID 不是 `.dev`，登录、推送、App Group、RevenueCat 商品环境会不一致。若 `.dev` 确实是正式 TestFlight App ID，需要明确记录而不是靠猜。
- **处理**：用 App Store Connect/Apple Developer 的实际 App ID、Bundle ID、Provisioning 对齐；不要只改字符串不验证签名/推送。

### R-04 P0：法律与隐私未完成发布审核

- `legal/TERMS-OF-USE.md`、`PRIVACY-POLICY.md`、`ACCOUNT-DELETION.md` 标题为“草案”；App 内展示“用户协议草案/隐私说明草案”。
- `Configuration/ReleaseChecklist.example.plist` 的 `LegalReviewed=false`，`OperatorName`/`SupportContact` 为空；只有 example 文件，未看到正式确认文件。
- **处理**：法务/负责人审核；填写运营主体、客服渠道；生成公开隐私政策 URL（App Store Connect 必填）；确认健康数据、AI 第三方处理、照片、未成年人/特殊人群说明；更新 App 内文案与版本号。

## 3. 建议内测前修复

| 项 | 说明 |
|---|---|
| 真实设备签名与安装 | 本轮只有无签名模拟器构建；未验证真机启动、崩溃、Keychain、HealthKit、Live Activity |
| Apple 登录真机 | 未走真实 Apple ID；nonce 重放修复需夹具/真机验证 |
| RevenueCat Sandbox | 购买/恢复/续订/退款/重复 webhook 未实测；用真实 Sandbox 账号 |
| AI/照片/健康真机链路 | 未验证大图、弱网、跨时区、自动日报、后台切回 |
| APNs 送达 | R-01 完成后做 1 台真机测试；后台“发送测试通知”也依赖它 |
| 生产迁移 | `migrate-v2-quality.php` 在 MySQL 9.4 通过；需在 staging MariaDB 10.11 复跑并备份 |
| 真实运营数据回归 | 成员/成长季/奖励/发货/通知在隔离库无真实数据；需 staging 人工回归 |
| 崩溃/日志 | 未见真实设备崩溃统计；需 TestFlight 内测观察 |
| 订阅价格/商品 | 代码中商品 ID 为 `yuefu/nianfu/yongjiu`；需与 App Store Connect 实际商品一致 |

## 4. 可后续迭代（不阻断内部技术 TestFlight，但阻断对外承诺）

- 实物奖励资格服务端可信（App Attest/DeviceCheck/人工）。
- 定时通知计划调度器。
- 训练动作内容管理、AI Prompt 版本/回滚、Token 成本统计。
- 媒体墓碑并发协议、自动日报失败重试、AI 归档 scope/保留策略。
- 性能 profiling 与增量同步。

## 5. 建议的发布门槛

**内部 TestFlight 可用（仅技术验证）**：R-02（部署可达）、R-03（确认 Bundle）、R-04（至少隐私 URL）完成；R-01 若推送功能不展示可暂时降级，但要在 App 内明确“推送未上线”。  
**外部 TestFlight / 正式发布**：R-01～R-04 全部完成；真实设备、Apple 登录、Sandbox、HealthKit、APNs、staging 迁移/回归全部通过；实物奖励资格风险有明确业务决策。

**当前判定：不通过外部 TestFlight 准入。**
