# 薄肌俱乐部 Build123 交付说明

日期：2026-10-26。基线为用户提供的 Build122 Dashboard 源码包。本次完成 20 项优化的代码修改、看板统计修复和服务端兼容更新；保留原始记录与历史报告。

当前构建号为 **123**，营销版本沿用 **0.15.6**。本次没有上传 TestFlight；源码可直接在 Xcode 打开 `BojiClub.xcodeproj`。

## 已落实的 20 项

| # | 交付行为 | 主要代码 |
|---|---|---|
| 1 | 新用户先看到紧凑基础资料卡，支持昵称、年龄、性别、身高、体重与 BMI 计算；未知可留空。确认后走权威资料事实的预览/确认流程，实测称重另行明确选择日期。草稿按账号保存到受保护文件。 | Experience123.swift / ClubAIShell.swift / BodyFactsView.swift / profile-facts.php |
| 2 | 品牌浅底使用 #E3E7F0；主要操作使用浅底深字，可读前景派生为 #414D63。玻璃表面增加轻品牌 tint，暗色使用适配色；状态色保留含义。 | DesignTokens.swift / Design.swift / JourneyComponents.swift |
| 3 | 引用入口使用紧凑小窗；输入 @ 联想最近记录，插入输入框内的高亮引用。身份仍由结构化引用绑定，支持整块删除、中文/emoji 范围处理，不把邮箱或任意 @ 文本当作授权引用。 | Experience123.swift / SharedComposer.swift / AIContextReference.swift |
| 4 | 首次说明改为实际输入框、登记位置旁的短提示，可稍后关闭并在帮助页重看；撤掉自动弹出的七页文字指南。 | Experience123.swift / ProfileView.swift / ClubAIShell.swift |
| 5 | 上传照片优先相机，右下角进入相册；有已选照片时可显示缩略预览。拍摄/选择后进入待发送附件，支持移除；相机不可用或拒绝授权则转相册。普通聊天照片不会自动保存成饮食。 | SharedComposer.swift / Experience123.swift / Info.plist |
| 6 | 深入分析从＋移走，统一在右上角下一条回答方式中选择；开启时可以在输入框上方取消，成功提交后回到自动。 | ClubAIShell.swift / ClubCoachView.swift / SharedComposer.swift |
| 7 | 增加 SSE EOF、缺终态、无进展时的权威快照补查与等待预算，支持恢复原任务；已存在的消息可幂等合并。失败不再一直转圈，切换会话的旧请求不能覆盖新会话状态。管理后台区分模型结果与服务端回复保存。 | AIRunStream.swift / AIService.swift / ClubCoachView.swift / admin/index.php |
| 8 | 移除训练页日计划卡下的大型“和 Club AI 聊聊”入口；用户仍可主动引用计划。 | ProductArchitecture.swift |
| 9 | 训练提示收敛为有真实可处理事件时才出现的区域；无事件不占位，移除登记页重复的泛用洞察条。 | ProductArchitecture.swift / Experience123.swift / WorkoutView.swift |
| 10 | 点重量或次数/秒直接打开对应字段，使用含小数点的数字面板；整数单位禁用小数点，支持清空、下一项与保存，保留原校验和无障碍系统输入。输入不会自动勾选完成。 | TrainingRegistrationViews.swift / WorkoutView.swift / Experience123.swift |
| 11 | 修复场次 ID 丢失造成的暂停读取失败。暂停区间随场次保存/同步；训练时钟、动作计时、休息剩余、通知和 Live Activity 联动；完成时长扣除显式暂停，健康导出传递暂停/恢复事件。普通组间休息仍计入会话。 | Models.swift / AppStore.swift / ClubAutomation.swift / WorkoutView.swift / HealthData.swift |
| 12 | 问教练改为当前动作帮助：练哪里、怎么发力、器械调整、常见错误和替代动作。带当天训练引用进入主 Club AI，问题草稿由用户确认发送；迷你条也按实际场次日期选动作。 | Experience123.swift / TrainingRegistrationViews.swift / WorkoutView.swift |
| 13 | 动作要领改为轻量文字入口，保留 44pt 点击区及经过核对的演示匹配规则。 | ExerciseLibraryView.swift |
| 14 | 首页只保留一句问候、一张当前训练行动卡和简短快捷动作；撤掉常驻今日发现与成长季堆叠。训练卡标题显示实际动作，减少重复文案。 | ClubAIShell.swift |
| 15 | 登录恢复改为单一恢复任务、服务端会话优先，保留 Keychain/离线缓存；暂不可读有重连入口。撤销授权在正式环境仍处理，模拟器 notFound 不再直接销毁有效测试会话。增加不含凭证的诊断状态。 | AccountService.swift / BojiClubApp.swift |
| 16 | 问候从符合真实状态的文案池选择，页面重绘不随机跳动；删除“你的训练，由这里开始”。 | ClubAIShell.swift |
| 17 | 正式路径中的旧日报生成、旧周问卷中心和独立聊天入口改为统一 Club AI 路由；旧完整入门表单入口也改到基础资料卡。 | ClubAIShell.swift / ClubInsightTimelineView.swift / TaskCenterView.swift / ClubPlanFollowupView.swift 等 |
| 18 | 我的记录保留训练、饮食、身体三类；更多中统一进入“AI 解读档案”。历史结果保留，新的解读不再引向一排旧表单。 | ProductArchitecture.swift / ReportLibraryView.swift |
| 19 | 增加明确的当日、完整自然周、滚动七天范围，端到端传递并校验日期/时区。自动周报仍评价上个完整周；手动未完整周期不再使用未来结束日身份。本地自动日报按来源指纹去重并支持补记后的新版本。 | Experience123.swift / ClubAutomationService.swift / WeeklyReviewView.swift / coach_core.py / automation_core.py |
| 20 | 统一根会话路由、来源引用与草稿恢复；通知、任务、洞察、计划和归档入口均复用。保留有价值的领域编辑和历史阅读，DEBUG 组件画廊不作为正式入口。 | ClubCoachView.swift / ContextContinuation.swift / ClubAdaptive.swift / BojiClubApp.swift 等 |

## 额外修复的看板口径

- 一餐或营养未知记录不能算全天达标。近七天显示完整记录天数；仅在完整记录且有适用目标时比较当天的上下限。
- 缺失热量不再填零；不存在可比昨日记录时不显示环比；一般的增减采用中性前景，不自动认定“更多就是更好”。
- 热量趋势按每一天的目标版本核对，撤掉把当前目标线套在所有历史日期上的做法。
- 体重变化显示真实“较上次”的时间间隔，撤掉没有起始点却接近满圈的目标环。
- 身体当前值、迷你走势和变化采用一致的来源/日期截止；历史查看不再混入之后的数据。
- 当月比较采用相同已过天数；连续训练记录不会因本周刚开始还没练就立即归零。
- 体重 KPI 支持大字号纵向布局。

## 服务端交付

服务端共更新 **9 个文件**，详见 `DEPLOYMENT_BUILD123.json`。部署前核对了生产源码基线，确认当时无排队/运行中的 AI 任务；部署后检查了文件 SHA256 与健康状态。

没有数据库迁移，没有修改线上用户记录、会员配置或模型密钥。旧客户端省略暂停字段时，兼容层保留已有暂停数据；旧训练场次缺少暂停信息时不补造历史。

历史周度解读支持继续追问原生成结果。服务端仍核对账号归属、来源类型与版本；客户端提供的报告全文不会被作为权威来源。新增周度结果兼容不会把普通聊天结果当作周报。

回滚备份：

- `/opt/bojiclub-build123-backup-20261026-042413`：首批 8 个文件。
- `/opt/bojiclub-build123-backup-20261026-043342`：周度来源兼容补充文件。

## 普通检查结果

- iOS Debug Simulator 编译通过。
- 25 项定向 XCTest 通过：17 项流式/请求恢复测试、8 项本次回归测试，包括跨会话取消、EOF 缺终态、暂停/完成时长、旧场次兼容、饮食完整性、周范围、Unicode 引用删除、邮箱 @ 识别和来源指纹。
- 48 项 Python 相关测试通过，包含自动分析、路由和本次范围/暂停校验。
- PHP 云同步、历史/自动分析契约及新暂停/昵称契约通过；另有 5 项冻结周报来源、归属、版本与类型检查通过。
- 修改的 PHP 文件语法检查通过，服务健康为 ok，9 个部署文件摘要全部一致。
- 使用开发预览账号做了首页启动和布局冒烟检查；这不等于全页面或真实用户流程验收。

PHP 的来源校验使用隔离 PDO/transport fixture，不是生产验收。没有录屏，没有跑 200 条付费模型业务指令，没有在生产账号创建测试训练/饮食或付款。

## 尚需真机核验的边界

相机/相册真实授权、中文输入法完整组合输入、Apple 登录跨重启/升级、健康写入实际显示时长、Live Activity 与通知后台行为仍需真机核验。反复登录的原始设备现象未独立复现，本次交付的是已实现的恢复流程修正与模拟器失效分支修复，不能宣称已证明所有设备上的触发原因。

本次未上传 TestFlight，未宣称通过全量付费模型 E2E。源码中的旧报告、日志与历史交付文档只代表各自基线；当前内容以本说明、Build123 文件摘要和本次检查结果为准。

## 重新构建

正常运行使用 `BojiClub` scheme；普通定向检查可使用 `BojiClub-Unit123` scheme，该 scheme 使用开发预览账号运行主程序，避免测试启动时恢复真实账号。完整 UI 测试仍保留在原 scheme，没有删除原测试以获得通过。

源码包不包含 `.git`、个人 Xcode 状态、Python 缓存、数据库或签名私钥。旧 Build122 摘要移动到历史目录，当前摘要为 `BUILD123_SOURCE_MANIFEST_SHA256.json`，摘要清单按标准排除自身。
