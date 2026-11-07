# 后端交付说明

日期：2026-10-16（2026-10-17 更新）。本轮 V2 补齐的**后端相关**改动与待部署事项。

## ✅ 已部署（2026-10-17，用户授权）

**`public/cloud-validation.php` 三处白名单已部署到 117.50.119.49**（`insightKind` 增加 `'plan'`、
`coachActionType`/`insightDestinationType` 增加 `'schedule_shift'`）。

- 备份：`/opt/bojiclub-account/.backups/insight-enum-20261017/cloud-validation.php`
- 校验：远端哈希与本地一致（fbdfd3b6…）；`php -l` 无错误；
  三项功能用例通过（旧格式兼容 / plan 事件+schedule_shift+新字段通过 / 假类型仍拒绝）；
  `/account/v1/` 路由（/opt/bojiclub-account/public/index.php）应答正常。
- 记录：`account-server/insight-enum-deployment-20261017.json`（不含凭据）。
- **发布顺序已满足**：Build 108 的「计划跟进」洞察同步不会再被契约校验拒绝。
- 回滚：`cp .backups/insight-enum-20261017/cloud-validation.php` 回原位（回滚后须停发 Build 108）。

## 结论先行

除上述校验器变更外，**本轮没有其他必须部署的后端变更。** 客户端新能力全部经现有同步/存储通路落地：
阶段报告、顺延记录、行动状态、计划草稿/模板都挂在 `SavedState`/`DayLog` 的可选字段上，
随现有记录同步（`CloudMerge` 已加对应合并规则；服务端对未知 JSON 字段透传，不校验不丢弃），
旧客户端可继续工作（字段可选、解码缺省）。

## 合并规则变更（随客户端生效，服务端无感）

| 字段 | 合并规则 | 位置 |
|---|---|---|
| `DayLog.planShifts` / `DayLog.phaseReports` | 按 ID 并集去重（与 goalVersions/planVersions 同规则） | CloudSync.swift `mergeValue` |
| `SavedState.actionStates` / `planDrafts` / `planTemplates` | 同 ID 取 `updatedAt` 最新（与既有 survey/观察类同机制） | CloudSync.swift `mergeValue` |
| `deletedPlanDraftIDs` / `deletedPlanTemplateIDs` | 并集（与既有 deleted* 同规则） | CloudSync.swift `mergeValue` |

服务端按 JSON 透传存储，无需 schema 变更。**兼容性**：旧客户端解码忽略未知字段；新客户端解码旧数据得 nil/默认值。回退：客户端降级后新字段留在云端不损坏，旧客户端继续读写旧字段。

## 待部署扩展（非本轮承诺，未写进生产代码路径）

### 1. AI 阶段报告（服务端生成版）

当前阶段报告为**客户端规则计算**（入口/类型/持久化/历史阅读全部可用）。若要服务端 AI 生成版：

1. 迁移：`account-server/schema.sql` 与 `migrate-*.sql` 中
   `ai_user_jobs.kind ENUM(...)` 增加 `'phase_report'`；
   `public/weekly.php` 提交校验白名单加入 `'phase_report'`；
   `ai-response.php` 映射表加入 `'phase_report'=>['report']`（结果 kind 沿用 report 便于阅读器）。
2. 提示词/路由：按现有 report 处理链增加 phase 报告提示模板（明确起止日期、数据覆盖、无上一阶段不环比）。
3. 验证：本地 PHP 回归（tests/）＋合成任务端到端；**生产迁移不在无人值守任务中执行**。
4. 回退：ENUM 收窄前先停写；任务行保留，历史可读。

### 2. 普通主动推送预算（A7 服务端接入点）

客户端 `ClubProactiveBudget`（每账号每日 ≤1 条普通主动提醒）已实现并记录规则。
现有服务端推送（`process-club-push.php`）只覆盖训练提醒与用户明确开启的报告通知——按任务书这些**不计入**预算。
若未来新增「普通主动」推送类别，在 `clubPushSend` 前按账号/日期消耗预算（建议表 `club_proactive_budget(user_id, day, used)`），超预算改次日或丢弃并记 receipt。

## 密钥与配置

本交付不含任何密钥/凭据；`config.php` 未改动。APNs 密钥、签名配置仍缺（历史缺口，见 KNOWN-ISSUES）。
