# 0.14.0 Build 107 · Xcode 编译报错修复

日期：2026-10-16。本包基于 Build 106，保留上次八项修复；不是只在旧 Build 105 上打补丁。

## 对应你发来的报错

| 文件 | 修正内容 |
| --- | --- |
| ProfileView.swift | PlanView 的计划采用回调明确标记 `onPlanApplied:`，不再依赖已弃用的无标签尾随闭包匹配。 |
| ManualPlanView.swift | 两处 catch 内将提示文字写到 `self.error`，不再给只读的 Error 局部变量赋字符串。 |
| ClubAutomationService.swift | `available` 返回 `[UUID]`；明确以场次 ID 查询训练，不再访问不存在的 `UUID.sessionID`。工作分析 payload 用 `JSONValue.string` 明确类型。 |
| ClubHistory.swift | 将三个容易超时的历史目标聚合／筛选／排序表达式拆成有具体类型的循环；目标时间与 UUID 排序规则保留。AI 日上下文也分步骤构造。 |
| ProductArchitecture.swift | 版本聚合、排序、去重分开；版本行拆成独立子视图。 |
| WorkoutView.swift | 主视图、弹层、状态监听、休息计时分段；当天训练内容拆成 11 个独立视图片段，保留顺序和行为。 |
| ExerciseLibraryView.swift | 推荐列表、动作行、加载状态和弹层分开；类型文案先作为普通字符串计算。 |
| BojiClubApp.swift | 根页面按账号内容、恢复、账号生命周期、通知路由、提醒、自动分析和前台同步拆开，降低单个表达式的类型推断负担。 |

原报告共有七处“无法及时完成类型检查”位置；均已对应拆分。没有通过提高编译器超时阈值或移除功能规避错误。

## 真正执行的检查

- 89 份 Swift 源码与生成文件语法解析通过；17 个升级文件的工程引用、六处 Build 107 设置检查通过。
- 对比确认：训练页、根页面和动作库的既有 State 声明、onChange／onReceive／task 调用均保留。扫描没有发现剩余的 catch 中给只读 error 直接赋值情况。
- 19 组 PHP 回归通过，PHP 语法检查通过；179 份服务端文件与已部署 Build 106 保持相同，不需要重新部署后端。
- 原 16 组原生测试源码已重新生成；另新增 13 条针对实际自动分析调用方法和历史目标排序的原生断言源码，覆盖 UUID 场次、去重、未确认训练、开启时间、提交失败及周报分支。

**尚未执行本次 Xcode 类型检查、原生测试及真机验收。** Windows 上的语法解析无法证明 SwiftUI 类型推断一定通过。上述检查不能包装成“Xcode 编译已通过”。

## 云 Mac 使用方法

1. 解压本包到新目录，关闭原来的 `BojiClub-upgrade-0.14.0-20261015` 项目。
2. 打开本目录的 `BojiClub.xcodeproj`。Scheme 选 `BojiClub-TestFlight`，确认 Build 是 **107**。
3. 在 Xcode 执行 `Product → Clean Build Folder`，再 Build／Archive。

需要完整日志时，可在项目目录执行：

```sh
sh scripts/check-build107-on-mac.sh
```

该脚本先编译真正的 App，再运行新增的自动分析／历史规则断言；不需要输入服务端密码或模型密钥。完整升级验收仍可使用 `scripts/check-upgrade-on-mac.sh`。

这批只处理编译问题，完整 V2 未完成项目仍以 [逐项对照](V2方案逐项完成对照-Build106.md) 为准，不因为生成新包而自动勾选完成。后端部署、容量、会员、支付和 APNs 配置没有改动。
