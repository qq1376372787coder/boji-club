# 远程通知：代码已准备，Apple 配置与真机送达待完成

Build 105 默认不注册 APNs，也没有擅自改变现有签名权限。服务器推送程序已安装，但在缺少受保护配置时直接退出。本机提醒继续保留。服务器自动生成报告与 APNs 送达是两件事：不开启 APNs，已生成的报告仍可在下次打开 App 时同步查看。

## 需要准备

1. Apple Developer 中打开 Bundle ID `com.bojiclub.app.dev`，启用 **Push Notifications**。Team ID 为 `GYFUN6MZ9J`。
2. 在 Apple Developer 的 Keys 创建用于 **Apple Push Notifications service (APNs)** 的密钥。保存 Key ID 与 `.p8` 文件。之前的 Sign in with Apple 密钥、RevenueCat 内购密钥承担不同用途，不能直接拿来替代。
3. 将 `.p8` 放入服务器 Web 根目录之外的私有目录，并让运行 PHP 的 nginx 用户能够读取；目录和密钥只授予必要权限。密钥不得放入 App、源码 ZIP、网页目录或聊天记录。
4. 将 `account-server/apns-config.example.php` 中的配置项合并到服务器已有的受保护 `config.php`，填写实际 Key ID、私有路径和 Team ID；验证后才把 `apns_enabled` 改成 true。不要覆盖原有支付、数据库、AI 配置。服务器还需支持 TLS 与 HTTP/2 的 PHP cURL。

## 云 Mac 上的源码开关

完成 Apple 权限设置后，在本项目根目录运行：

```sh
python3 scripts/enable-remote-push.py
sh scripts/check-upgrade-on-mac.sh
```

脚本只修改工程签名设置、主 App entitlement 和 Info.plist，并保留 `.before-remote-push` 备份。Debug 使用 development；Release/TestFlight 使用 production。重新生成相应 provisioning profiles，再 Archive。脚本在临时工程副本上已连续运行两次并检查幂等性；这不是 Apple 签名验证结果。

默认 Build 105 没有执行该启用脚本，不因此新增 TestFlight 签名要求。

## 实际验收

- 真机登录自己的测试账号，主动授权通知；打开 Club AI 对应分析偏好并完成同步。
- 先确认服务器 `/me/push-device` 返回 `push_ready=true`，再用真实测试记录完成一项分析，退出到后台验证送达与点击跳转。
- 分别验证每日分析、训练解读、周度报告；通知只包含通用提示和路由信息，不把体重、饮食或模型正文显示在锁屏上。
- 测试免打扰、关闭某类通知、撤回云分析授权、退出账号、切换账号及 token 更新。旧账号失效会话不能继续推送。
- TestFlight 走 production APNs；不要用 development token 向 production 地址发送。
- 服务器已配置每分钟检查、失败退避，最多 5 次传输尝试；只处理设备开启后最近 48 小时内的分析任务，避免补发大量旧消息。免打扰可延后发送。

本次完成了 22 项加密、路由、隐私和免打扰检查，以及数据库/API 测试；没有向 Apple 发出真实推送。正式验收必须保留设备端送达与跳转结果。

官方依据：[向 APNs 注册](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[使用密钥连接 APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)。
