# 上传校验 90360 修复（2026-10-21）

苹果上传校验发现 Widget 扩展缺少 CFBundleDisplayName。已在 BojiClubWidget/Info.plist 增加 String 值“薄肌俱乐部”。该修改适用于所有构建配置，不改变证书、描述文件、Team、Bundle ID、版本号或业务数据。

最终 TestFlight 配置无签名设备构建成功，并直接检查产物 BojiClub.app/PlugIns/BojiClubWidget.appex/Info.plist，确认显示名已写入。记录见 widget-display-name-build.log。本地构建不能替代苹果服务器上传校验，需在云 Mac 修改后重新 Archive、上传。

云 Mac 快速修复：选 Target BojiClubWidget → Info → 新增 Bundle display name（CFBundleDisplayName），类型 String，值 薄肌俱乐部；或用交付的 BOJI-Widget-Info.plist 替换工程 BojiClubWidget/Info.plist。

已归档文件不会跟随源码自动改变，修复后必须重新 Product → Archive，再选择新归档上传。旧归档不用再次上传。
