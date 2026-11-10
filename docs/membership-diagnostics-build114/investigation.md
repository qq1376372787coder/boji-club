# Build 114 购买问题排查记录

手机 Build 113 在加载会员方案后 1–2 秒显示暂不可用，未取得 SDK 原始错误，因此不能确认根因。

已验证：
- 付费 App 协议截图有效、银行账户可用。
- App Store Connect / 安装包 / RevenueCat Bundle ID 均为 com.bojiclub.app.dev。
- 月付 yuefu / 1 个月，年付 nianfu / 1 年，均可供审核。
- 月付中国大陆价格 CNY12；37 个亚太销售地区包含台湾，用户报告 App Store 账号台湾地区。
- RevenueCat 内购密钥显示 Valid credentials，服务器通知显示 configured correctly。
- 本机使用项目公共 SDK Key 读取 RevenueCat 当前方案 HTTP200，商品 yuefu/nianfu/yongjiu。
- 用户同一手机 Safari 无鉴权探测返回预期的 HTTP401/7225 Invalid API Key，证明这次浏览器连接 API 可达，不代表 App 内请求已成功。

尚未验证：年付及永久方案的实际地区定价/销售状态，手机 StoreKit 商品返回值，安装包内实际 SDK 错误。

Build 114 仅改善错误分类并加入只读内测诊断；没有更改会员权限、收据核验、支付 API 地址和真实商店价格。诊断入口仅 Debug / BOJI_TESTFLIGHT 启用。需要云 Mac 签名上传与手机验收，不能宣称购买故障已修复。

已通过：TestFlight 配置无签名 iOS 设备构建；17 项错误分类及脱敏检查；补丁安装签名保持/构建号/备份/损坏及更新版本拒绝检查。构建有原有图表 plotAreaFrame 弃用警告。未在实体 iPhone 执行 StoreKit 查询。
