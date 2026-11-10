# BOJI CLUB Build 117 修复与部署交付

日期：2026-10-25。版本：0.15.1 (117)。服务器：117.50.119.49。发布标识：20261025-build117。

**本次独立复审确认的 RA-01～RA-08 已修复，后端已实际部署；最终 132 个运行代码/资源文件与本地交付源码逐一核对一致。** Nginx、PHP-FPM、AI 服务、6 个任务 timer 为 active。iOS 改动已经编译进入源码，需要安装 Build 117；服务器部署不能更新已安装 App 二进制。本次未上传 TestFlight。

## 已落实的功能

- 取消与业务命令统一账户→Run 锁顺序，在领域事务内重新检查父任务，阻断取消成功后的新写入；消息接受、Run 创建在同一事务内保存。
- 饮食识别丢弃模型冒认的标签验证/用户确认，保留来源、误差与复核标记。修正食品改名、手工营养编辑、分量缩放和“根/个/碗不能当克”的计算边界。最后的真实 HTTP 检查还发现并修复了搜索分支局部 import 导致计算分支异常的问题，新增回归用例。
- 食品查询接入实际 USDA SR Legacy 数据，共 7,793 条四项完整基础营养记录，含来源版本、ID、下载哈希与可重复导入脚本。中文精确别名覆盖 10 类食物，其他配方仍需匹配/确认，不冒充中国食品库或照片实测。
- 改期补偿绑定原操作及提交后指纹；补齐长期计划逆向版本、保留指定日期、模板与偏好恢复、撤销的再补偿。后续编辑在预览及提交时阻止自动覆盖；过去/已开始/已完成的训练保持业务保护。
- 急性风险在调用模型和工具之前分流；特殊情况、年龄未知/未成年、训练资料不足和评估不可用时不套用普通成人加重规则。进阶建议先解析唯一器械变体，并保留已确认会话来源，以两次同负重达标为基础给有限建议，不自动改计划。
- iOS 区分 409、429、403、5xx 与明确端点不可用；只在明确不支持新接口时允许旧通道回退，不因限流或提交结果未知而换身份再提交。
- 实现供应商真实增量→安全提取 coach.answer→后端持久事件→PHP worker→客户端 SSE 的流式链路；中断恢复、重试 reset、取消栅栏和最终结构验证保留。工具 JSON 不作为正文显示。
- 单 worker 单次领取 1 项；安装事件清理 timer、Outbox 等后台调度，SSE 独立 PHP-FPM 池上限 4，保护普通 API 与取消请求。部署脚本含配置预检、备份、哈希冲突保护和失败代码回滚。
- 增加 APNs entitlement 与 Debug/Release 环境配置；实际签名、设备注册和投递仍需 Apple 环境验证。

## 本次亲自执行的验证

|层级|结果|证据|
|---|---|---|
|iOS Debug 与 XCTest|62 项，0 失败|evidence/local/xcode-unit.log|
|iOS Release|无签名构建成功，Build117|evidence/local/xcode-release.log|
|Python 离线回归|732 项，0 失败|evidence/local/python-final.log|
|PHP / 隔离 MariaDB|57 套件，0 失败；未连接正式库运行测试套件|evidence/remote/php-suite-final/results.tsv|
|确定性 Golden|120 例，0 失败|evidence/local/golden-final.log|
|取消竞态|重放原双连接竞争窗口，取消后未发生领域写入|evidence/remote/race-inspect.txt|
|真实模型+原 worker|LongCat-2.5-Preview，25 条真实 delta，首段早于模型完成|evidence/remote/real-model-summary.json|
|真实 HTTP 协议|SSE 顺序/断点续读、401、409、429、取消、过期410及快照通过|evidence/remote/http-e2e-summary.json|
|线上有限并发检查|10 个合成订阅，4 个 SSE 进程；普通配置与取消约17ms，合成账户已清除|evidence/remote/production-smoke-summary.json|
|最终线上接口/哈希|营养未知质量/100g计算、急症与特殊情况保护通过；132 文件一致|evidence/remote/final-engine-smoke.json、final-live-verification.json|

正式配置与模型环境文件哈希在部署前后保持一致。最终备份：`/root/bojiclub-deploy-backups/20261025T070549Z-build117`，只保留在服务器 root 私有目录，包含数据库及旧代码。本地交付不含该备份、服务器凭证或生产用户数据。

部署先前出现 Nginx 正则配置错误时已触发自动回滚并恢复旧服务；修复后加入完整候选配置预检。记录保留于 evidence/remote/deployment-first-rollback.*。最终发布为成功状态，见 deployment-result.json。

## 验收边界

本次修复结论针对代码与上述测试范围，不能等同“所有设备/所有模型永远无 bug”。HealthKit 真机增删授权、APNs 真机签名投递、StoreKit/RevenueCat 沙盒、真机第三方音频/锁屏/后台、无障碍与长期性能，以及具资质人员的健身/营养/医疗边界审阅仍需外部验收；没有把 Mock、无签名构建或一条真实模型样本写成这些事项已完成。详见 EXTERNAL_VALIDATION_PENDING.md。

原 ZIP 内的历史报告保留作为历史资料；以本报告、源码差异和本次日志为准。
