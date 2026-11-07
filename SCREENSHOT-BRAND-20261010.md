# 0.13.41（60）截图品牌

基于 0.13.40，保留此前编译与记录修复。最低 iOS 17.0。

预先放置「现有 App 图标 + BOJI CLUB」于顶部中央，104 × 18pt，白底黑字。按当前 UIWindowScene 创建透明品牌窗口，不成为 key window，不接收触摸，不进入 VoiceOver，退出场景释放。没有截图监听、照片库读写、新权限、网络或定时器。首页布局、后台、AI、支付和保存逻辑保留。

横屏、倒置、无刘海、iPad、状态栏隐藏、启动动画、非活跃场景及异常尺寸关闭此层。相机若仍显示状态栏，也采用同一规则。安全区域尺寸是保守的布局判断，不是硬件遮挡检测 API；日常能否完全隐藏在刘海或灵动岛后，以及实际系统截图的效果，必须真机确认。展开的实时活动、通话、录屏、热点可能让截图保留系统内容，不能保证此时品牌可见。

38 个 Swift 文件语法解析通过，工程加入新源文件，图标加入普通 imageset。Windows 环境没有 Xcode / Swift 编译器，本版未执行 Mac 编译、原生布局断言或 iPhone 验收。语法解析不能替代编译。Mac 运行 bash scripts/check-on-mac.sh，包含从生产源文件提取布局规则的检查：7 组竖屏尺寸、8 组禁用条件。附带脚本不代表已经运行通过。

真机验收：

1. 刘海和灵动岛各一台，检查正常界面有无文字或白边露出；按系统截图，检查品牌、时间、信号、电量。
2. 首页、训练、饮食、我的、日报、弹窗、半屏和全屏 sheet，检查点击与键盘焦点。
3. 横竖屏、锁屏、前后台、启动动画，检查隐藏和恢复。
4. 通话、录屏、热点、训练实时活动及其展开状态，不覆盖系统内容。
5. 无刘海机型不显示此层。

使用完整新工程，不能仅替换 BojiClubApp.swift：有新增 Swift 文件、工程引用和图片资源。旧联网测试账号继续有效；正式域名、签名、支付待办保留。

苹果官方说明：

- https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification
- https://developer.apple.com/documentation/uikit/uiwindow/canbecomekey
- https://developer.apple.com/documentation/uikit/uiview/safeareainsets
