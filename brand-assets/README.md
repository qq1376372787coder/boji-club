# BOJI品牌素材与用法

以用户提供的图形重绘成矢量，原始PNG保留在reference/。原始参考不被应用作为带白底的内容图直接使用。

- BojiMark-Master.svg：可编辑彩色主稿。
- BojiMark-light/dark/mono/white.svg、pdf、png：透明背景，PNG为512×512；适用于内容页、导出和后续品牌使用。
- Brand-Variants.png：深浅色和16/24/48/72尺寸预览板。
- AppIcon资源位于BojiClub/Assets.xcassets/AppIcon.appiconset；1024×1024 RGB，无Alpha，不预烘焙圆角或系统投影。
- 启动矢量位于BojiLaunchMark.imageset；页面组件使用共享SwiftUI矢量。

重建（macOS已安装Xcode；在源码根目录）：

```sh
swiftc BojiClubWidget/BojiBrand.swift scripts/brand-assets/main.swift -o /tmp/boji-render-brand
/tmp/boji-render-brand "$PWD"
```

图形变更只改BojiLogoGeometry，再重建导出，避免不同页面各用一套不一致的图片。24pt及以下或系统高对比度使用单色；深色卡面用onDark；功能按钮继续用其功能图标。
