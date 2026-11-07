# Bug 注册表（按真实严重度）

状态说明：**FIXED/TESTED** = 已修并有可复现验证；**OPEN** = 已确认未修；**ENV** = 受环境/Apple 平台限制；**ACCEPTED** = 经业务权衡保留并记录。  
严重度：P0 阻断发布/数据不可用；P1 高概率数据、权益、安全或稳定性问题；P2 中低风险/体验/可维护性。

| ID | 严重度 | 模块 | 问题 | 证据 | 状态 | 验证 |
|---|---|---|---|---|---|---|
| B-001 | P0 | iOS | 源码在 Xcode 26.6 无法编译：`onChange` 旧值是非 Optional，`guard let oldVal` 非法。历史报告声称完整构建通过，与事实不符。 | `BojiClub/DesignTokens.swift:1039` | **FIXED/TESTED** | 修复后 TestFlight 配置模拟器构建 **BUILD SUCCEEDED** |
| B-002 | P1 | AI/iOS | AI 日报 payload 不带 `timeZone`；服务端默认 Asia/Shanghai，UTC+8 以东用户在本地 00:00–02:00 生成的日报被判为“未来日期”。 | `BojiClub/AIService.swift:425`，`backend/ai_core.py:286` | **FIXED/TESTED** | iOS 发送时区；旧客户端按 UTC+14 兜底；新增时区边界测试 |
| B-003 | P1 | AI 安全 | 营养/剂量处方规则只检查 summary/training/nutrition/recovery，notes 与周报 photoFeedback 可绕过“仅一般指导”限制。 | `backend/ai_core.py:1370` | **FIXED/TESTED** | 新增 notes/photoFeedback 数字处方拒绝测试 |
| B-004 | P1 | AI 配额 | 没有单账号未结束任务上限；默认每账号每日为 0（不限），一个账号可占满全局 800 个任务槽，重试不计费。 | `backend/server.py:197,284` | **FIXED/TESTED** | `account_pending_limit` 默认 8；创建/重试均校验；后台可配置 |
| B-005 | P1 | AI 可靠性 | 记录 attempt 时 SQLite 失败会让已成功、已付费的模型结果被丢弃并重试。 | `backend/ai_core.py:1256,1320` | **FIXED/TESTED** | 日志失败不影响返回值；新增注入 SQLite 错误测试 |
| B-006 | P1 | AI/计划 | 日程提案可以把训练移动到已存在安排的日期，或形成链式覆盖。 | `backend/adaptive_core.py:110` | **FIXED/TESTED** | 新增覆盖/链式冲突测试 |
| B-007 | P2 | AI 配置 | 管理后台无法真正清除旧供应商密钥；更换密钥后熔断状态仍保留，可能继续跳过修复后的供应商。 | `backend/server.py:1080`，`backend/ai_core.py` `replace_providers` | **FIXED/TESTED** | `clear_key` 显式清除；密钥变化重置熔断；测试覆盖熔断重置 |
| B-008 | P2 | 动作服务 | `instruction_steps` 非字典时详情接口抛异常并断连。 | `exercise-server/api.py:89-95` | **FIXED/TESTED** | 结构防护 + 回归测试 |
| B-009 | P1 | 俱乐部/数据库 | 实物申领在持有全库 `GET_LOCK` 时调用私有 AI HTTP 校验，单用户可让所有申领/加入等待 5 秒后失败。 | `account-server/public/index.php:642`（修复位置） | **FIXED** | 进度计算移到俱乐部锁外；无同类 HTTP 位于锁内（人工代码审计） |
| B-010 | P1 | 会员 | `membership_entitlements.last_transaction_id` 全局 UNIQUE；同一交易号出现在两个账号时，`ON DUPLICATE KEY UPDATE` 可覆盖另一账号权益。 | `account-server/schema.sql:64` | **FIXED/TESTED** | 去掉全局 UNIQUE，保留普通索引；迁移验证 + 两账号同交易号测试 |
| B-011 | P1 | 认证 | Apple identity token 的 nonce 由客户端提供且服务端不记录，截获 token+nonce 可重复换取 30 天会话。 | `account-server/public/apple-auth.php:78` | **FIXED**（重放表） | 新增 `apple_auth_nonces`，10 分钟一次性消费；迁移已应用；**缺少完整签名 token 的 HTTP 重放测试**（需 Apple 夹具） |
| B-012 | P1 | 后台安全 | 所有管理员权限相同，无角色、无最小权限；任何登录管理员可发奖励、改会员、换 AI 密钥。 | `account-server/admin-schema.sql`（新增 role/status） | **FIXED/TESTED** | 5 角色；服务端页面/动作双重校验；HTTP 测试 403 |
| B-013 | P1 | 后台功能 | “测试发送”只插入一条 `queued/admin_preview` 记录，不调用 APNs；定时计划没有调度器。 | `account-server/admin/bootstrap.php:427` | **部分修复** | 测试改为**真实单成员 APNs**（需配置/设备）；计划明确标注未接入，不会自动群发 |
| B-014 | P1 | 配置链路 | 后台无公开配置中心；App 没有远程配置读取；无法证明“后台改动→App 生效”。 | 新增 `public/app-config.php`、`app_config` 表 | **FIXED/TESTED** | 草稿/发布/回滚、`/config`、服务端 gate、iOS fetch/banner；HTTP/ETag/开关测试 |
| B-015 | P2 | 审计 | 删除成长季任务、归档奖励目录、归档通知模板等破坏性操作无审计。 | `account-server/admin/bootstrap.php` | **FIXED/TESTED** | 补 `audit()`；后台审计标签集中管理 |
| B-016 | P2 | 业务命令 | `/me/commands` 的 Profile.Update 写不存在的 `height/weight` 列且遗漏 NOT NULL，100% 失败；分区账号写入被忽略却返回成功。 | `account-server/public/commands.php:192` | **FIXED** | 使用 `height_cm/weight_kg/nickname/days_per_week`；分区账号明确 409；不支持的 Schedule.Rest/Workout.Confirm 明确 400 |
| B-017 | P2 | 后台认证 | 不存在的用户名跳过 `password_verify`，可枚举账号；限流只按 IP+用户名，跨用户喷洒不受限。 | `account-server/admin/bootstrap.php` 登录段 | **FIXED/TESTED** | dummy hash；IP+用户名/用户名双桶限流；HTTP 登录成功 |
| B-018 | P2 | 隐私/审计 | 用户自助注销会删除 `admin_audit` 中该成员的记录，抹除管理员操作证据。 | `account-server/public/account-deletion.php:99` | **FIXED** | 改为脱敏保留（target 置空、明细脱敏） |
| B-019 | P2 | 后台 Dashboard | 总览只有注册/引导/同步/训练与 7 天活动，缺少会员、AI、履约、异常、配置/备份状态。 | `account-server/admin/index.php` | **FIXED/TESTED** | 真实业务表指标 + “需要关注” + 最近操作；截图验证 |
| B-020 | P2 | 后台 UI | 14 个平铺导航、移动端整块导航占满首屏、无统一设计变量/状态样式。 | `account-server/admin/style.css` | **FIXED/TESTED** | 4 组导航、Design Tokens、移动菜单、表格/表单/状态统一；16 页 + 3 移动页截图 |
| B-021 | **P0** | iOS/APNs | `BojiClub.entitlements` 没有 `aps-environment`，工程也没有 Push Notifications capability；`registerForRemoteNotifications()` 无法得到 token，服务端推送链路实际不可用。 | `BojiClub/BojiClub.entitlements`，`BojiClub.xcodeproj/project.pbxproj` capability | **OPEN/ENV** | 需 Apple 开发者 App ID 开启 Push、配置 Provisioning/APNs Key；本轮无 Apple 账号，未改签名配置 |
| B-022 | **P0/P1** | 发布配置 | TestFlight/Release 仍为 `com.bojiclub.app.dev`、Widget `.dev.widget`，APNs topic 固定 `com.bojiclub.app.dev`；若正式 App Store 使用非 `.dev` Bundle ID，登录 audience、推送 topic、App Group、RevenueCat 商品都会不一致。 | `project.pbxproj`（TestFlight/Release），`account-server/public/club-push.php` | **OPEN/需确认** | 不能凭代码判断哪个是正式 App ID；需与 Apple/App Store Connect 核对后统一 |
| B-023 | **P0** | 合规 | 法律文件标题仍为“草案”，`ReleaseChecklist.example.plist` 的 `LegalReviewed=false`，运营主体/客服信息未填；App 内展示“用户协议草案/隐私说明草案”。 | `legal/*.md`，`Configuration/` | **OPEN** | 需负责人/律师审核、填写运营主体与支持联系方式、生成公开 URL |
| B-024 | P1 | 俱乐部权益 | 训练/饮食/健康天数完全来自用户同步状态；服务端仅形状校验，没有 App Attest/DeviceCheck，伪造 `workoutSavedAt`/sets 可满足实物奖励资格。 | `account-server/public/club-progress.php:9-25`，`public/index.php` claim | **OPEN** | 需产品决策：设备证明、人工核验、或限制实物奖励由服务端可验证指标触发 |
| B-025 | P2 | 媒体一致性 | 状态 PUT 的墓碑删除 `user_media` 未持有媒体锁，与并发上传存在锁顺序/已确认照片被删风险。 | `account-server/public/index.php:765` | **OPEN** | 需设计墓碑与上传的提交协议；本轮未改动以免引入死锁 |
| B-026 | P2 | 自动日报 | 自动任务终态失败后，PHP 把它计入 known_ids，且 failed 也存在 existing_reports；同一 revision 不会再次生成；provider 短暂故障可丢失当天自动报告。 | `account-server/process-club-automation.php`，`backend/automation_core.py` | **OPEN** | 建议有界重试队列 + 失败冷却 + 人工重跑入口 |
| B-027 | P2 | AI 归档/一致性 | 报告归档版本 scope 为 owner/kind/date/purpose，同日两次训练分析会互相标为 stale；`Workers.source_checker` 未在生产启动 wiring，来源变更复核实际不生效；归档无保留策略。 | `backend/server.py` `archive_reports`/`main` | **OPEN** | 需补 source_session scope、注入 checker、保留/清理策略 |
| B-028 | P2 | 后台通知 | 定时计划表/表单存在但无调度器，后台已明确标注“不会自动发送”；若误启用也不会有效果。 | `account-server/admin/index.php` 消息中心 | **OPEN（已诚实标注）** | 需求：接入调度器或移除计划入口；本轮选择不冒险群发 |
| B-029 | P2 | 后台能力 | 无训练动作内容管理、AI Prompt 版本/回滚、Token 成本明细、管理员 2FA。 | `account-server/admin` | **OPEN** | 需架构决策；不应增加“只改 UI 不生效”的假功能 |
| B-033 | P2 | iOS 可访问性/自动化 | `meal-group-*` 标识被 SwiftUI 传播到分组、餐食行和删除按钮，XCUITest/辅助技术出现重复标识；AX3 下分组高度超过视口，中心点点击不稳定。 | `BojiClub/NutritionView.swift` | **FIXED/TESTED** | 改为显式可访问 Header Button（展开/收起状态、唯一 `meal-group-*`），餐食行/删除有独立标识；UI 回归复跑 |
| B-030 | P2 | 性能 | `/me/state` 仍为单账号整包 JSON（约 16MB 上限）；`decodedState()` 对同一 payload 做两次 `cloudValidate`；AI 归档全表 UPDATE。 | `account-server/public/index.php`，`backend/server.py` | **OPEN** | 需要真实数据量后再做增量同步/优化，避免未验证大改 |
| B-031 | P2 | 测试 | 本轮开始时没有可运行的真实 iOS UI 回归结果；历史报告未证明当前源码可编译。 | 历史 `KNOWN-ISSUES.md` / 交付文档 | **FIXED（测试链）** | 本轮运行 51/51 Swift harness 与 XCUITest（结果见 04） |
| B-032 | P2 | 环境 | 真机、HealthKit、Apple Sign-In、RevenueCat Sandbox、APNs 送达、iOS 17 runtime、VoiceOver 未在本机验证。 | 无设备/Apple 账号 | **ENV-LIMITED** | 必须由 Apple 开发者环境/真机完成 |

## 风险排序

1. **B-021 / B-022 / B-023**：阻止 TestFlight 对外内测的配置/合规项。
2. **B-024**：实物奖励资格可被自报数据绕过，业务损失风险。
3. **B-025 / B-026 / B-027**：媒体与自动报告的边缘数据一致性。
4. **B-028 / B-029**：后台能力边界；已明确标注，不允许虚假显示。
5. **B-030**：规模化后才显现的性能债。
