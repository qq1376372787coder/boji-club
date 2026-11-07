# 0.13.24 设备与健康数据

## 当前确认流程

连接 Apple 健康 → 保存 App 训练 → 查找时间接近的手表记录 → 在同一页核对日期、数据和设备训练 → 一次点击“同意分享并关联这次训练”。只有一个匹配时预选供核对；多条匹配必须选择。也可取消或只分享每日汇总。

训练页和“我的 → 设备与健康数据”使用同一确认页。未点击同意时，仅查看本机数据。页面固定打开时的数据、账号和日期；后续刷新不会替换正在核对的数据。确认时重新检查账号、训练内容和此前已分享记录，变化后要求重新打开核对。健康汇总与训练关联一起保存，失败一起回退；联网后按原有同步流程上传。

页面明确说明云端、运营后台、MiMo 和 DeepSeek 的使用范围，不上传原始心率序列或 GPS。关联不增加训练次数、不重复加热量。营养和其他记录不因确认而改变。取消读取、取消关联、移除每日已分享汇总仍分别保留原有功能。

本版 302 项 Swift Foundation 检查通过，其中新增 44 项检查健康合并确认、原子保存、账号/训练变化、失败重试、跨午夜、AI 输入和云端合并。35 个 Swift 文件语法检查通过。Windows 无法验证真实 HealthKit 查询、iOS 确认页或 Xcode 编译，仍需 Mac/iPhone 验收。详细说明见 HEALTH-CONSENT-20261005.md；以下记录早期通道设计与边界。

## 本次实现

- iPhone HealthKit 只读接入：步数、活动能量、平均心率、静息心率、自然日睡眠、运动记录。
- 所有已写入 Apple 健康且被用户允许读取的来源均可参与，不限 Apple Watch。展示实际来源 App 名称，不把 App 来源误称为硬件型号。
- 我的 → 设备与健康数据：权限请求、日期切换、刷新、来源优先选择、品牌指南、TCX 文件导入、缓存断开与清理。
- 首页按所选日期显示数据；App 回到前台时刷新当天所选日期。没有后台持续采集，也没有直接蓝牙配对。
- 数据按账号隔离、文件保护并排除 iCloud 备份。只在用户确认分享某一天后写入现有云同步记录，后台可查看。AI 日报只接受该确认快照。刷新不会静默重传新的健康数据。
- 上传汇总包括指标、来源、时间及运动摘要，不包含 GPS 路线或原始心率样本。AI 使用 MiMo 主服务，DeepSeek 作为可用的后备服务。

## 品牌通道与边界

| 品牌 | 当前通道 | 注意事项 |
|---|---|---|
| Apple Watch | Apple 健康 | 先配对、同步手表 |
| 小米 / Redmi | Mi Fitness → Apple 健康 | 开启第三方数据共享；因机型而异 |
| Garmin | Garmin Connect → Apple 健康 | 品牌 App 需要前台同步；不等同于 Garmin 完整云数据 |
| Amazfit | Zepp → Apple 健康 | 具体类别按设备和版本开放 |
| Polar | Polar Flow → Apple 健康 | 按品牌提供的数据类别读取 |
| 华为 | 华为运动健康中可用的健康共享 | 依赖地区/机型/版本；本轮未实测国区设备，不保证全部指标 |
| 其他 | 能写入 Apple 健康的品牌 App / 标准 TCX 文件 | 未提供这些渠道的设备还不能接入 |

官方资料：
- https://www.mi.com/uk/support/faq/details/KA-230360/
- https://support.garmin.com/en-AU/?faq=lK5FPB9iPF5PXFkIpFlFPA
- https://support.polar.com/en/support/connecting_polar_flow_with_apple_health
- https://support.amazfit.com/it/amazfit_x/docs/YfPEdX2R1oaMNexokstc8BkhnWb
- https://consumer.huawei.com/minisite/cloudservice/health/common/b0/latest/default/privacy-statement.htm?timestamp=202107221700
- https://developer.garmin.com/gc-developer-program/health-api/
- https://developer.apple.com/documentation/healthkit/hkstatisticsoptions
- https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:)

品牌官方云 API 直连未实现。佳明需要开发者项目审批；其他品牌也需确定官方授权范围和申请条件后单独实现 OAuth、回调校验、同步游标和撤销授权。不要把品牌指南理解为已开通直连。三星、Fitbit、COROS 等不在已确认的原生共享品牌清单，需按实际共享/文件导出能力处理。

## 统计口径

每项取单一来源，优先用户所选来源；缺失时，累计量与睡眠取总量较高的来源，心率取固定来源 ID 顺序的第一个。来源之间不相加，可能与 Apple 健康自己的优先级结果不同。睡眠合并所选来源内重叠区间，排除清醒/卧床，按当地自然日裁切，不能当作整夜睡眠。

运动相同 ID 或时段重叠超过最长时段的 80% 时视为重复，优先所选来源，其次健康数据，最后 TCX。运动按开始日归属。运动能量不加到全天活动能量，力量训练记录不转为热量。缺失指标为 null，不是 0。

TCX：UTF-8，最多 5 MB，单文件最多 200 条活动，本机最多 1000 条；解析 Activity/Id 或 Lap StartTime、TotalTimeSeconds、Calories。只支持含每圈时长的活动导出，不支持 FIT、GPX 或 TCX Course。重复导入按活动开始时间/运动类型/总时长指纹识别，不采集路线。

## Mac 使用

1. 解压后打开 BojiClub.xcodeproj，选择开发团队和 iPhone 真机。
2. 工程已配置 BojiClub.entitlements 和 NSHealthShareUsageDescription，需使用支持 HealthKit 能力的签名配置；若 Xcode 提示签名不支持，在 Signing & Capabilities 中配置对应团队及 HealthKit。
3. 先同步品牌 App，在 Apple 健康里确认相应日期确有数据，再打开薄肌俱乐部连接。
4. 新版需在所有参与同步的设备使用。旧版不认识健康汇总字段，可能在上传时丢弃该字段。

当前版已经运行上述 Foundation 自动化检查，尚未运行 Xcode 编译。Windows 环境无法确认 HealthKit 授权、确认页呈现和各品牌真机表现。服务器部署状态也不等于模型日报与健康导入已通过端到端验收。

后续建议验收：部分拒绝权限、全部拒绝、锁屏后恢复、跨账号、断网同步、同一运动多来源、重复TCX、跨午夜睡眠、日期切换、确认/移除云端汇总。撤销读取不删除历史已分享数据；移除每日汇总不删除已生成日报或其输入，目前没有健康历史一键全链路删除功能。


## 2026-10-09 AI 服务与个人头像更新

新版首次云端分析前说明并确认：LongCat 优先，小米 MiMo 备用，再由 DeepSeek 处理支持的文字任务；图片仅交给支持图片的服务。旧客户端仍按原授权范围处理。录音不上传，只有核对后的文字会用于饮食识别。拍照模式选择照片后自动启动识别，手动模式照片仅为附件，结果核对后保存。头像为可选个人信息，自定义图片裁剪并压缩后与账号记录同步；分享前可关闭头像与昵称展示，不在 AI 请求中发送头像。
