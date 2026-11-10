# Build132 原生界面升级交付

基于 Build131 提交 `7dae574c733e237d4247a767290aa1162be88b23` 完成这轮已确认的原生界面改造。App 版本 `0.15.6 (132)`。

## 已完成范围

| 页面 | 本次落地 |
|---|---|
| Club AI 输入栏 | 单层无品牌染色的系统 Liquid Glass；加号、麦克风采用系统圆形按钮；发送采用高对比系统按钮。引用 chip、照片在上方。保留系统文字编辑、回车发送、换行菜单、本机语音与草稿保护。 |
| 我的、账号 | 我的页采用原生分组列表；新增独立账号页，资料、会员、退出与注销分组。退出/注销保留确认，并在账号变化时关闭旧操作。 |
| 设置与导航 | 设置归为账号、偏好、数据与隐私、帮助；普通子页使用系统返回导航。已有自带导航的页通过统一外壳复用父导航，编辑弹层恢复独立导航，避免嵌套导航和丢失关闭按钮。 |
| AI 对我的了解 | 身体、目标、习惯和记忆改为摘要入口；下一级系统列表/表单展示字段、值和来源。保留单项修改、清空、批量编辑、记忆纠正和停用。 |
| 反馈与回复 | 列表改为系统列表；提交页改为分组表单、内容占位提示、照片视频附件和原生提交按钮。回复消息、草稿、上传和重试能力保留。 |
| AI 跟进、通知 | 跟进页使用原生列表承载开关/选择；通知和已有表单统一语义文字色。记录授权与待同步操作分开，待处理队列移到同步入口。 |
| 健康与设备 | 多块装饰卡片改为原生分组，去掉英文眉题与宣传大标题；权限、来源、写入确认、导入预览与去重逻辑保持。 |
| 空间、同步、备份 | 用量和同步状态采用分组列表；待同步项目、导出、修复进入下一层。详细备份说明折叠，个人记录提示仍可见。 |
| 我的计划 | 列表按当前、待采用方案、历史分组；详情复用原有编辑、归档、取消未开始安排和历史保护。含剩余未开始安排的被替换计划仍可管理。 |
| 周计划与资料编辑 | 已有原生 Form 统一样式、保存和导航；周一至周日逐日编辑逻辑保留。 |
| 动作库与引用选择 | 独立动作库采用系统 List、搜索和筛选选择；嵌入式动作库不再嵌套滚动。查询任务挂在单一容器上，避免每行触发重复加载。引用仍使用原生小弹层、选择标记和 chip。 |
| 饮食、身体记录 | 饮食录入采用原生 Form；身体记录使用原生列表及原生编辑表单。照片识别、逐餐核对、营养细项、趋势图保留。 |
| 任务、会员、关于 | 任务采用系统列表行；有效商店会员使用管理列表，购买仍复用 RevenueCat/Apple 流程；关于页采用原生列表，协议保留文档阅读。 |

原审查清单中的 22 类页面已纳入以上范围。训练日历、组数登记、训练总结图表、聊天消息和动作演示保留业务专用主体，不改造成设置列表；导航、关闭和通用控件采用统一原生样式。

## 普通检查

- TestFlight 配置、arm64 iOS Simulator 编译检查；17 项针对性 XCTest，其中 4 项为界面渲染检查，其余覆盖引用/输入和既有回归。
- 已人工核对设置浅色、分组行和输入栏组件图；另提供深色预览。预览来自真实 SwiftUI/UIKit 渲染，使用示例数据，不是真机业务全流程验收。
- 首次测试在生成 dSYM 时因磁盘不足中断；清理本任务旧的可再生成 Build/Index 缓存后重新检查，未删除或跳过失败用例，未删除源码或交付包。
- 没有视频录制、付费模型请求、购买或真实账号删除测试。
- 本次仅修改 iOS 源码，服务端沿用 Build131，无需数据库迁移或服务器部署。未上传 TestFlight；手机需重新编译安装 Build132。

## 保留的边界

- 关闭系统透明效果或提高对比度时，输入栏使用不透明语义背景，保证可读性；iOS 26 以下使用系统材质回退。
- 文字字号跟随系统；圆形操作保留至少 44pt 点击区域，长文字输入可以增高，超出后内部滚动。
- 原生布局没有取消健康/云端分析授权、关键删除说明、未保存草稿、上传失败重试、历史记录保护或付款确认。
- 本次没有重新接入云端语音识别，仍使用 Apple 本机识别。

## 组件预览

设置浅色/深色、聊天输入栏及分组行的预览图片，随独立报告包的 previews/ 目录提供。

## 主要代码

- [NativeInterface132.swift](BojiClub/NativeInterface132.swift)
- [SharedComposer.swift](BojiClub/SharedComposer.swift)
- [Experience130.swift](BojiClub/Experience130.swift)
- [ProfileView.swift](BojiClub/ProfileView.swift)
- [ClubAIMemoryView.swift](BojiClub/ClubAIMemoryView.swift)
- [ProfilePlanCenter126.swift](BojiClub/ProfilePlanCenter126.swift)
- [MemberFeedbackViews128.swift](BojiClub/MemberFeedbackViews128.swift)
- [HealthViews.swift](BojiClub/HealthViews.swift)
- [PlanManagement.swift](BojiClub/PlanManagement.swift)
- [ExerciseLibraryView.swift](BojiClub/ExerciseLibraryView.swift)
- [RevenueCatViews.swift](BojiClub/RevenueCatViews.swift)
- [Design.swift](BojiClub/Design.swift)
