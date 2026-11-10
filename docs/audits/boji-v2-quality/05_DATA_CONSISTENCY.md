# 跨模块数据联动与一致性审计

## 1. 数据流总览

```
iOS 本地 SavedState（days/meals/plan/…）
  ├─ 本地 persist + journal（崩溃恢复）
  ├─ PUT /me/state（revision 乐观锁；分区账号写 cloud_parts）
  ├─ HealthKit 汇总（用户逐日确认后才进入 AI/云端）
  └─ AI 任务（只提交明确字段；结果回写本地）

PHP MySQL
  ├─ app_states / cloud_parts（云端记录权威副本）
  ├─ profiles / onboarding（投影，含快照）
  ├─ membership_entitlements（RevenueCat + 人工赠送合并）
  ├─ club_*（规则/奖励/申领/库存）
  └─ admin_audit / app_config / ai_user_jobs

Python AI（SQLite）
  └─ jobs / attempts / controls / providers.json / report_archive
```

## 2. 训练计划与历史记录

检查点：

- 历史 `DayLog` 是实际记录载体；计划修改不应改写已完成训练。
- iOS `PlanAdoptionRules.isProtected`、`WorkoutEditing.isProtected` 保护已开始/已确认的训练；`applyAIPlan` 跳过受保护日期。
- 服务端 `cloudWorkoutSessionsPreserved` 拒绝覆盖云端已有的同日多次训练；`/me/state` 校验 session ID/时段。
- `/me/commands` 的 Schedule.Replace 对已开始/已确认的日期返回 409；本轮修复了 Profile.Update 与分区账号假成功问题。
- 现有回归：`test_plan_changes.php`、`test_plan_changes` Swift、`test_plan_schedule.php`、`test_club_history.php`、训练/多餐相关 Swift harness 等；本轮 639/51 全通过。

结论：**核心历史保护路径存在且有测试**。未在真实双设备并发下重新验证；草稿同 ID 并发仍按“较晚覆盖”处理（历史文档已记录）。

## 3. Apple Health

检查点（代码级）：

- 每个指标按来源取值，`availableSources` 保留来源列表；不把多个来源相加。
- 运动记录 `HealthDay.deduplicated`：不同来源、同类型、时段重叠 >80% 视为重复；同设备两条记录不合并，避免误删。
- 全天活动能量与运动热量不直接相加；AI 提示词明确“运动热量可能包含在全天活动能量中”。
- 睡眠为自然日区间并集；不伪造完整睡眠阶段。
- TCX 导入按文件 ID 去重，最多 1000 条；重复时段合并。
- 撤权/断开：`disconnect()` 清除本机设备缓存，保留已确认的云端记录。

限制：**没有真实 HealthKit 设备数据/部分授权/撤权验证**。本轮未改动 HealthKit 核心逻辑，避免在无真实数据时引入风险。

## 4. 饮食与营养

检查点：

- `MealNutritionMerge.merged(edited:base:current:)` 只合用户实际改动的字段，保留并发/云端其他字段；已有 Swift 回归。
- 删除餐食通过 `deletedMealIDs` 与服务端墓碑清理照片；每日总热量/宏量由记录派生，不做跨来源累计。
- AI 报告饮食使用 `meals_complete` 明确完整性；未确认日期不判断“摄入不足”。
- 修复：AI notes/photoFeedback 不能绕过营养处方限制。

限制：本轮未做真实照片跨设备并发上传/删除的端到端 UI 测试；媒体墓碑锁问题（B-025）仍开放。

## 5. AI Insights 与计划修改

- AI 只生成建议/结构化结果；iOS 通过 `applyAIPlan`/`applyWeeklyPlan` 预览确认后写入本地，再由同步上传。
- `expectedDays` 防止预览后数据变化；保护已开始训练；`hasAppliedAIJob` 防重复应用。
- 服务端不直接写 `app_states`；Python 只通过任务结果返回，避免绕过业务服务。
- 修复时区、guardrail、单账号队列、日志丢失、日程冲突。
- 公开配置可关闭 AI 服务；关闭后 PHP 在创建/重试前返回 503。
- 仍未解决：自动任务终态失败不自动重试；归档 scope 对同日多次训练分析会误标 stale；source_checker 生产未接线（B-026/B-027）。

## 6. Club 成长、徽章与实物奖励

- 申领事务：`clubRulesLock` → 用户行锁 → `FOR UPDATE` 奖励/库存 → 资格校验 → 唯一申领/每期一件 → 取消/库存释放。
- 本轮把进度计算（含 AI metadata HTTP）移到全库锁之前；服务端仍在事务内复核奖励状态、库存、截止日与 requirements。
- 电子徽章/称号通过 `club_virtual_grants` 发放；实物库存与状态机受后台限制。
- 后台发布时校验目标不超过活动可完成天数、实物库存覆盖名额、每期最多一项实物、活动日期不重叠。

**开放风险（B-024）**：训练/饮食/健康天数来自用户同步状态，服务端只做结构与日期校验；没有 App Attest/DeviceCheck。恶意客户端可以构造已完成组/健康汇总来满足实物奖励。需要产品/安全决策，不能在本轮用“加一个字段”伪装解决。

## 7. 会员与订阅

- RevenueCat/Apple 是交易权威；服务端合并 `revenuecat_subscriptions`、REST snapshot、人工赠送，取有效期最优。
- 修复：`last_transaction_id` 全局唯一导致的跨账号覆盖；迁移为普通索引。
- Webhook：签名/HMAC、事件 ID 去重、时间顺序、环境/App ID/商品过滤、TRANSFER 处理（代码审计 + 既有 PHP 测试）。
- `requireActiveMembership` 保护 AI/俱乐部；管理后台不能代替 Apple 发订阅。
- 限制：Sandbox 购买/恢复/退款/续订未执行（需要真实商店授权）；B-022 的 Bundle ID/RevenueCat 配置需 Apple 侧核对。

## 8. 注销与数据删除

- `account_deletions` 持久队列，失败重试/人工处理；AI owner 擦除、媒体文件/Apple token 撤销。
- 修复：保留 `admin_audit` 操作证据但脱敏成员关联，不再物理删除。
- 终端清理失败会保留队列，不静默吞掉；后台可重试。
- 未在真实注销周期上跑完（需要真实账号/Apple token）。

## 9. 一致性结论

| 链路 | 结论 | 证据/剩余 |
|---|---|---|
| 训练→日历→历史 | 关键保护存在；本机回归通过 | 双设备并发未真机验证；草稿覆盖策略已记录 |
| Health→面板→AI | 单来源取值/运动去重/不跨源累加 | 真机 HealthKit 未验证 |
| 餐食→统计→AI | 字段级合并/完整性标记 | 媒体并发锁开放 |
| AI→计划 | 预览/受保护日期/幂等应用 | 自动失败重试/归档 scope 开放 |
| 训练→Club→奖励 | 事务内库存/申领保护 | 资格来源可伪造（B-024） |
| 订阅→权益 | 合并与到期判断 | 交易号覆盖已修；商店实测未做 |
| 后台→App | 配置发布链路已建立 | 公告/最低构建为客户端展示；真实设备未验 |
