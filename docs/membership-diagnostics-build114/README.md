# 会员价格加载诊断补丁 · Build 114

这份补丁用于查明会员价格加载失败的真实原因，尚不能宣称已经修复价格问题。

## 云 Mac 安装

1. 保存 Xcode 中修改，然后退出 Xcode。
2. 解压补丁。双击“安装补丁.command”，选择包含 BojiClub.xcodeproj 的原项目文件夹。
3. 看到“补丁已安装”后，重新打开原项目。脚本只替换 MembershipService.swift / RevenueCatViews.swift，并将 App、Widget 构建号改为 114；保留签名、Team、描述文件及公共 SDK Key。必要时仅补齐 Widget 显示名称。
4. 选择原 BojiClub-TestFlight Scheme、Any iOS Device (arm64)，Product → Archive。
5. Distribute App → TestFlight Internal Only 上传。处理完成后，将 Build 114 加入原内部测试组。
6. 手机 TestFlight 更新到 0.15.1 (114)。进入会员页，向下找到“检查购买服务（内测）”，运行后截图或分享结果给开发者。

如果双击脚本未运行，可在终端输入 `python3 `，拖入 apply_patch.py，再输入一个空格、拖入项目文件夹，回车运行。

不要用本机完整 project.pbxproj 覆盖云 Mac 的项目文件，以免丢失手动签名设置。

## 诊断内容

- 当前版本、Bundle ID、SDK 最近方案错误域/错误码及有限的底层错误链。
- 使用安装包内公共 SDK Key 读取 RevenueCat 当前方案和三项已知商品 ID，不传俱乐部用户 ID。
- 使用 StoreKit 读取当前商店地区，以及 yuefu / nianfu / yongjiu 的实际商品、价格和类型。
- 最多等待 30 秒，已完成步骤会保留；账号切换会清除并取消旧诊断。
- 不购买、不恢复、不上传收据、不修改会员权限；诊断结果只在本机展示，由用户手动分享。
- 正式 Release 配置隐藏诊断入口。TestFlight Scheme 保留 BOJI_TESTFLIGHT 编译条件。

## 回滚

安装脚本会在原项目旁生成 Build114-backup 时间戳目录。需要回滚时退出 Xcode，将其中三个原文件（两个 Swift 和 project.pbxproj）及 Widget Info.plist 复制回原位置。

## 仍需验证

本机无云 Mac 的分发证书及手机连接；签名上传和实际 StoreKit 返回值需要在手机更新 Build 114 后确认。本补丁没有改变支付 API 地址，也没有假设网络是故障原因。
