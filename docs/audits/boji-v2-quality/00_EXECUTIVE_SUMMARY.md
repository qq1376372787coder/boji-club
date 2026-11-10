# BOJI CLUB V2.0 全栈质量攻坚 · 执行摘要

日期：2026-10-20  
基线：`BojiClub/` 源码包（用户上传 `BOJI-Source-Optimized-20261020.zip`）  
本地基线提交：`1e2a2c5 chore: baseline BOJI CLUB V2.0 source snapshot`  
本轮性质：本地审计、修复、测试与后台重构；**没有部署生产、没有修改真实用户数据、没有触发真实支付/奖励/推送**。

## 1. 结论先行

1. **原包并非“全部验证通过”。** 使用 Xcode 26.6（Swift 6.3.3）实际编译时，iOS 工程存在一个确定的编译阻塞：`BojiClub/DesignTokens.swift` 的 `onChange` 旧值被当作 Optional 解包。修复后，TestFlight 配置的模拟器构建已 **BUILD SUCCEEDED**。
2. 后端、AI、PHP 管理后台可以在本机隔离环境实际运行。本轮完成了 **639 项 Python 离线回归、38 项 PHP 规则/SQL 回归、51 项 Swift 生成式回归**，并新增 **4 项真实 HTTP 集成测试**（管理员 RBAC、配置草稿/发布、服务端功能开关）。
3. 管理后台从“能用的单体页面集合”升级为具备 **RBAC、配置中心、发布/回滚、真实运行指标、统一设计系统、移动端导航** 的控制台。16 个登录后页面与 3 个移动端页面已用无头 Chrome 实际渲染并截图，无 PHP 致命错误。
4. 修补了若干会造成真实数据/权益/安全问题的缺陷：会员交易号跨账号覆盖、俱乐部申领锁内调用 AI HTTP、Apple 登录凭证重放、AI 营养医嘱绕过、AI 队列单账号占用、AI 结果因日志失败被丢弃、日程提案覆盖已有训练、通知“测试发送”假成功等。
5. **不能宣布可以进入 TestFlight 内测。** 发现 4 个发布阻断项：远程推送缺少 `aps-environment` entitlement/推送 capability；Release 正式 API 域名 `api.gongxiang.cloud` 本机 DNS 无法解析（TestFlight 走 IP；该 IP 测试服已于 2026-10-21 部署并通过 `/config`、`/me`、admin smoke）；发布/内测配置仍使用 `com.bojiclub.app.dev` 与 `apns_topic=.dev`，需确认 Apple 侧 App ID/Provisioning/APNs；法律文件仍是“草案”，`LegalReviewed=false` 且运营主体/客服信息未完成发布确认。另有真实设备、Apple Sandbox 支付、HealthKit、APNs 送达未在本环境验证。

## 2. 本轮实际运行结果

| 检查 | 命令/方式 | 结果 |
|---|---|---|
| Python 离线回归 | `python3 -I tests/run_offline.py` | **639/639 通过** |
| PHP 规则/隔离数据库 | `tests/run_php_suite.sh`（MySQL 9.4 / PHP 8.3.22） | **38/38 通过** |
| Swift 生成式回归 | `tests/run_swift_regressions.py --jobs 3` | **51/51 通过** |
| iOS TestFlight 构建 | `xcodebuild ... -configuration TestFlight -sdk iphonesimulator ... build` | **BUILD SUCCEEDED**（修复编译阻塞后） |
| 管理后台 HTTP | `tests/test_admin_v2_http.py` | **3/3 通过** |
| 服务端功能开关 | `tests/test_feature_gates_http.py` | **1/1 通过** |
| 数据库迁移 | `migrate-v2-quality.php --check → apply → --check` | 6 项漂移 → 应用 → **SCHEMA_OK** |
| 后台页面渲染 | 无头 Chrome，1440px + 390px | 16 个页面 + 3 个移动页；无 PHP 错误；仅 favicon 404 |
| iOS UI 测试 | XCUITest（iPhone 17 Pro Max / iOS 26.5） | 首次 11/14 → 修正选择器/可访问性标识后 **14/14 通过** |

## 3. 本轮交付的核心改动

- **iOS**：修复编译阻塞；AI 日报发送客户端时区；接入只读远程配置（公告/最低构建提示）；清理两处编译警告。
- **PHP 账号服务**：会员交易号只按账号内生效；Apple nonce 一次性消费；俱乐部申领在全局锁外计算进度；后台 RBAC、配置中心、审计补强；账号注销保留脱敏审计；Profile.Update 修正；通知测试改为真实单成员 APNs。
- **Python AI**：日报时区兼容；营养/剂量规则覆盖 notes 与 photoFeedback；单账号未结束任务上限；attempt 日志失败不丢结果；供应商密钥变更重置熔断；日程提案拒绝覆盖/链式冲突；动作 API 字段防护。
- **管理后台**：发布/草稿/版本/回滚；五角色最小权限；真实 Dashboard；统一 Design Tokens/布局/表格/表单/响应式；16 个页面视觉回归。
- **测试**：新增 Python 12 项、PHP 2 项、HTTP 4 项、Swift 编译验证；迁移脚本可重复执行。

## 4. 未完成 / 必须人工确认

- 远程推送 entitlement/Apple 开发者配置与真机送达。
- 发布用 Bundle ID、APNs topic、Provisioning、App Store Connect 商品/价格。
- 法律文件正式审核、运营主体/客服、隐私政策 URL（App Store Connect）。
- 实物奖励的服务端可信资格（当前训练/饮食/健康天数仍来自用户同步数据，无 App Attest）。
- 通知“定时计划”尚未接入调度器；后台已明确标注，不会自动群发。
- 训练动作内容管理、AI Prompt 管理、Token 统计未在现有架构中实现（外部动作数据集/Python 内置提示词）。
- 真实设备、HealthKit、RevenueCat Sandbox、APNs、iOS 17 runtime、VoiceOver 未验证。

详细证据见本目录其余 12 份文档。
