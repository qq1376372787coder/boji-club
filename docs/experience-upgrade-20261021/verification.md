# 本次验证记录

版本：0.15.1 / Build 113。日期：2026-10-21。

| 验证 | 结果 | 范围 |
|---|---|---|
| Python 离线回归 | 639 项通过 | 后端规则与静态契约；不使用真实用户数据 |
| Swift 手动计划测试链 | 末尾 48 项通过 | 模型、草稿、模板与原有基础规则 |
| Swift 产品一致性 | 59 项通过 | 包含在下方升级规则脚本的基础测试链中 |
| Swift 新增升级规则 | 34 项通过 | 单日作用范围、计划归属、长计划结束、并发开始保护、旧设备合并、旧周期兼容、循环配置、睡眠区间与本机测量分享边界 |
| 服务端 PHP | 语法及 10 项专项通过 | 在服务器 PHP 8.3 环境运行候选代码后部署；无数据库写入 |
| UI 自动化 | 8 个重点场景分别通过 | 首页、创建方式、批量动作、身体趋势、资料保存、计划删除、训练保存、大字号可达性 |
| 截图检查 | 标准屏、小屏及大字号 | 示例账号；不是实际用户健康数据 |
| iOS 模拟器 Debug 构建 | 通过 | 最终源码构建通过；重点交互另有自动化验证 |
| TestFlight 配置 iOS 设备构建 | 通过，见 device-build.log | 无签名，不等于已上传 TestFlight |

不同测试链有继承关系，不能把以上所有数字相加当成独立测试总数。UI 各场景的通过记录见 ui-passed-cases.json；这不是全量 UI 测试。

## 8 个 UI 场景

- `testBodyOverviewHasMetricAndRangeControls`
- `testCreationOffersManualAndAIWithoutSubmitting`
- `testFiveTabsAndHomeBodyCard`
- `testManualPickerAddsSeveralActionsTogether`
- `testProfileChangesKeepManualPlan`
- `testSingleDayLargeTextStaysWithinScreen`
- `testUnstartedPlanCanBeDeletedFromMyPlans`
- `testWorkoutCompletionShowsOnlyConfirmedVolume`

## 服务端

部署文件：`/opt/bojiclub-account/public/cloud-validation.php`。

备份：`/opt/bojiclub-account/.backups/experience-20261021T021914Z/cloud-validation.php`。

部署后 SHA-256：`9f6fc1f9b5c37853ec040fedd50ecb412ab3c9bc4a6b0a52b2f6334c9343a8a8`。

动作健康接口与账号配置接口均为 HTTP 200。实际部署日志在 server-deployment.log。服务器登录信息没有保存到工程或交付材料。

## 验证边界

未执行真机 Apple 健康授权与所有设备来源组合、真实 Apple Watch 训练关联、正式签名或 TestFlight 上传。本机主要睡眠按醒来日组织；既有 AI 分享仍采用自然日汇总，两者在展示与分享中明确分开。最近测量读取只供本机展示，不新增手动测量，也不自动上传。

小屏大字号日期控件采用分行显示；表单可纵向滚动，保存入口固定在底部。截图中的示例称重与动作来自 DEBUG 测试夹具。
