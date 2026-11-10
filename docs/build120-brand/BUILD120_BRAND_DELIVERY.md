# BOJI CLUB 新Logo全量接入交付

版本：0.15.4（120）｜2026-10-25。基于已交付Build119继续实现，119修复保留。

已落实本次确认的所有Logo位置和配套细节。以用户上传图形做矢量重绘，保留原始参考文件；全App和Widget共用同一图形源。

## 页面与功能覆盖

|位置|落地内容|代码位置|
|---|---|---|
|桌面图标|浅色、深色、系统着色三版，1024×1024无Alpha；使用系统图标遮罩|`BojiClub/Assets.xcassets/AppIcon.appiconset/Contents.json:2`|
|启动页|原生启动资源和应用过渡统一；去掉旧插画与950ms固定等待|`BojiClub/BojiClubApp.swift:39`|
|登录入口|替换“薄”字旧图标，登录提示与AI导向入口一致|`BojiClub/OnboardingView.swift:64`|
|AI空白首页|64pt矢量标识作为欢迎区中心；进入对话后不占用消息空间|`BojiClub/ClubAIShell.swift:763`|
|AI新手欢迎及引导|56pt欢迎标识；会话按回复组展示助手身份，原生任务图标保留|`BojiClub/OnboardingV2.swift:1058`|
|侧边栏|原生导航栏顶部Logo＋BOJI CLUB组合|`BojiClub/ClubAIShell.swift:687`|
|AI回复身份|普通回复、流式回复、追问、自动报告、训练及阶段解读共用标识|`BojiClub/ClubCoachView.swift:676`|
|AI处理状态|原有AI等待组件统一换标识；使用真实任务文本，轻微呼吸，不假报完成比例|`BojiClub/Design.swift:467`|
|会员及成员卡|会员介绍、购买入口、成员欢迎卡、个人编号旁放适量品牌标识|`BojiClub/RevenueCatViews.swift:97`|
|俱乐部成长季|深色卡面采用浅色标识；保留活动、进度及奖励信息|`BojiClub/ClubSeasonView.swift:122`|
|训练完成总结|结果页品牌标题与AI分析身份区分，动作、重量、计时功能保留原图标|`BojiClub/ClubWorkoutSummaryView.swift:206`|
|日报、周报与训练解释|报告库和阅读页使用统一签名；来源、日期与历史记录不改|`BojiClub/AIViews.swift:486`|
|分享卡|共用分享渲染器添加浅色品牌签名，覆盖报告、训练及使用该渲染器的导出卡|`BojiClub/ReportShareViews.swift:44`|
|设置与关于|设置有品牌头和关于入口；个人页协议区也能打开关于；版本取安装包实际值|`BojiClub/Design.swift:593`|
|桌面小组件|16pt单色签名，深浅色自适配；小尺寸显示月日，完整日期保留给辅助朗读|`BojiClubWidget/TodayTrainingWidget.swift:50`|

## 统一细节

- 图形源：`BojiClubWidget/BojiBrand.swift:6`。透明SVG/PDF/PNG导出放在brand-assets，原始参考图放在brand-assets/reference。没有白色底板或巨大留白嵌入应用内容。
- 深浅色与对比度：`BojiClubWidget/BojiBrand.swift:60`。大标识采用适配明暗的雾蓝/灰层次；24pt及以下与高对比度使用清晰的单色轮廓。深色卡面显式使用白色。
- 保持Logo清晰；材质效果沿用现有原生控件，不在Logo上叠强模糊或厚阴影。成功/错误/训练强度颜色保留功能含义。
- 动态：`BojiClub/Design.swift:473`。减少动态效果、页面离开/不可见、App非活跃时停止呼吸动画。没有无限循环Task；不把动画当真实进度。
- 语义：Logo为装饰性矢量，不假装功能按钮；品牌签名辅助朗读合并为一个标签。发送、计时、保存、训练功能图标继续负责表达操作。
- 大字：使用系统语义字体、可换行文字与滚动页面；关于页在辅助字号3的深色模式下进行了静态核对。
- 小组件：图形由共享代码绘制，不依赖主App资源包；避免Widget因找不到图片显示空白。
- 素材可重建：scripts/brand-assets/main.swift 从同一几何源生成SVG/PDF/透明PNG、图标与启动图。详见brand-assets/README.md。

## 普通检查与证据

- iOS26.5 / iPhone17模拟器Debug主App和Widget构建通过，最终日志evidence/xcode-final-build.log；未新增业务测试，也没有录制视频。
- 静态图核对：首页浅色、组件深色、关于页深色辅助字号3。截图位于screenshots，来自本机合成预览账号，不代表真实订阅或模型服务验收。
- 资源检查：所有Asset Catalog JSON可解析，引用图片存在；三版桌面图标均为1024×1024且没有Alpha；透明品牌PNG带Alpha。详见evidence/brand-checks.json。
- Build119的account-server、backend、shared及tests目录与基线逐字节一致，本次改动集中在原生界面、资源和工程配置。
- 未进行真实设备、App Store上传或后台业务全量验收；本次不把119的79/55/84/17项历史测试计作本轮重新执行。

## 使用

解压完整源码，用Xcode打开BojiClub.xcodeproj并构建安装120版。App Icon及启动页由新安装版本生效；若系统桌面缓存旧图标，可删除旧测试安装后安装新版（先保留需要的本机数据）。

本次差异见CODE_DIFF_119_TO_120.patch、CHANGED_FILES_119_TO_120.json；源文件清单见SOURCE_MANIFEST_SHA256.json。历史Build119及更早报告仅作追溯，本报告为本次品牌升级依据。
