# 管理后台完整功能审计

审计方式：逐页读取 `account-server/admin/*.php`、对应 `bootstrap.php` 动作、SQL、公开 API 与 iOS 读取路径；在隔离 MySQL + 真实 PHP 服务器上执行 HTTP 测试与无头浏览器渲染。  
结论标记：**完整** / **已修** / **部分** / **缺失** / **不适用** / **仅草稿（明确标注）**。

## 1. 页面级矩阵

| 页面 | 业务目的 | 真实数据/持久化 | App 联动 | 权限 | 状态（本轮后） |
|---|---|---|---|---|---|
| 运营总览 | 运营态势 | users/onboarding/app_states/membership/ai/club_claims/push/deletions/app_config/backup | 间接（读业务表） | 所有角色可看 | **已修**：新增会员/AI/待履约/异常/备份/最近操作 |
| 俱乐部成员 | 查询与筛选 | users/profiles/onboarding/app_states | 账号状态/会员 | operator/support/readonly | **完整**（搜索、状态、分页） |
| 成员档案 | 记录/权益/标签/备注/注销 | profiles/app_states/membership/admin notes/tags | 状态、权益、备注 | 分角色 | **完整**（只读角色看不到写入表单；服务端 403） |
| 月度成长季 | 规则/任务/奖励/发布 | club_* | iOS `/club/*` | operator；content 可看不可写 | **已修**：删除任务/归档奖励补审计；规则仍只在草稿可改 |
| 徽章库 / 礼品库 | 目录与图片 | club_reward_catalog + admin-media | iOS collection/claim | content/operator | **已修**：归档审计；图片上传 |
| 发货管理 | 人工核验/物流 | club_reward_claims | 用户查看发放状态 | support/operator | **完整**（状态机、发货必填物流、核验备注） |
| 消息中心 | 模板/计划/发送记录 | notification_* | 无自动计划联动 | content/operator；真实测试仅 operator | **部分/明确标注**：模板测试改为真实单成员 APNs；计划未接调度器，不自动发送 |
| AI 服务中心 | 实时统计/容量/供应商/任务 | Python controls/providers + ai_user_jobs | AI 创建/重试 | operator | **已修**：单账号未结束上限、密钥显式清除；无 Prompt/Token 管理 |
| 自动化任务 | 自动跟进健康 | club_automation(_runs) | PHP 自动任务 | operator | **完整**（暂停/恢复/重跑/查询） |
| 推送管理 | 设备/回执/预算/停发 | club_push_* | APNs 设备/回执 | operator | **部分**：数据与预算真实；实际送达受缺少 entitlement/配置阻断 |
| 存储与同步 | 容量/清理 | storage_settings | 媒体上传配额 | operator | **完整** |
| 系统状态 | 服务/备份/模型 | 实时 DB + AI health/backup-status | 间接 | operator/readonly | **完整**（模型密钥不显示） |
| 操作记录 | 审计 | admin_audit | 无 | operator/support?（support 无 audit 页） | **已修**：集中标签；配置/管理员/归档动作入库 |
| 系统配置（新） | 公开配置发布 | app_config/app_config_versions | `/config` + iOS fetch | **仅超级管理员** | **新增/完整**：草稿/发布/回滚/版本/校验/ETag |
| 管理员与角色（新） | RBAC | admin_accounts | 无（后台自身） | **仅超级管理员** | **新增/完整**：5 角色、创建、停用、改角色、重置密码、最后超级管理员保护 |
| 安全设置 | 改密 | admin_accounts | 无 | 所有角色（仅自己） | **完整**（改密使旧会话失效） |
| 登录 | 认证 | admin_accounts/limits | 无 | 未登录 | **已修**：dummy hash、双桶限流、停用拒绝 |

## 2. 动作级检查（关键项）

| 动作 | 前端 | API/服务端 | 持久化 | 生效/联动 | 审计 | 结果 |
|---|---|---|---|---|---|---|
| 成员禁用/恢复 | 是 | 事务 + 状态 CAS + 注销保护 | users | 会话撤销；App 401 | 是 | 完整 |
| 人工会员调整 | 是 | `membership_adjustments` + 权益重算 | 是 | App `/me` | 是 | 完整（operator 专属） |
| 成长季发布 | 是 | 日期/任务/库存/重叠校验 + 事务 | 是 | iOS `/club/current` | 是 | 完整 |
| 奖励申领状态 | 是 | 状态机 + 人工核验备注 | 是 | App 申领页 | 是 | 完整 |
| 通知模板保存 | 是 | 校验 + 模板表 | 是 | 测试发送读取 | 是 | 完整 |
| 通知测试 | 是 | **真实 APNs 单设备**；失败记录 | delivery | 单成员 | 是 | 已修（需 APNs 配置） |
| 通知计划 | 是 | 保存计划表 | 是 | **无调度器** | 是 | 仅草稿（页面已明确） |
| AI 暂停/恢复 | 是 | Python settings | 是 | 创建任务被拒 | 是 | 完整 |
| AI 容量 | 是 | Python controls + 回读确认 | 是 | 立即生效 | 是 | 完整（新增单账号上限） |
| AI 供应商 | 是 | 密码复核 + Python providers | 是 | 下个任务 | 是 | 完整（新增清除密钥） |
| 推送预算 | 是 | 设置表 | 是 | 下次预约 | 是 | 完整 |
| 配置保存/发布/回滚 | 是 | Schema 校验 + 乐观版本 + 审计 | 是 | `/config` + 服务端 gate + iOS | 是 | 完整 |
| 管理员创建/停用/改角色 | 是 | 角色校验 + 最后超级管理员保护 | 是 | 会话失效 | 是 | 完整 |
| 账号注销重试 | 是 | `account_deletions` | 是 | 后台任务 | 是 | 完整 |

## 3. 原本的“假配置/假成功”与处理

1. **通知测试**：原实现只插入 `queued/admin_preview`，不调用 APNs。→ 改为真实 APNs 单成员发送；计划仍明确标注未接调度，避免假群发。
2. **`/me/commands` Profile.Update**：写不存在列且忽略 NOT NULL，100% 失败；分区账号写元数据却返回成功。→ 修正列；分区账号 409；不支持命令 400。
3. **配置中心缺失**：后台只有分散的开关，App 不读取。→ 新增 `app_config` + `/config` + iOS fetch；服务端开关真实拦截。
4. **“修改成功但 App 无变化”**：成长季/奖励本身有真实 `/club` 读取；通知计划相反，已明确标注为未接入，而不是继续显示成功。
5. **审计缺失**：删除任务/归档目录/归档模板无审计。→ 补齐。
6. **权限**：隐藏按钮不等于权限控制；本轮服务端对页面与动作均校验，并通过 HTTP 403 测试。

## 4. 缺失但未实现的能力（明确）

- **训练内容管理**：动作库由 `exercise-server` 文件数据集提供，MySQL 无动作表；后台没有安全的写回/版本/审核链路。未增加空壳页面。
- **AI Prompt 管理/版本/回滚**：提示词硬编码在 `ai_core.py`/`weekly_core.py`；没有安全编辑器/测试沙箱。未做假 UI。
- **AI Token/成本统计**：Python 有任务/尝试/耗时，未按供应商 token 计费入账。
- **会员方案/价格编辑**：必须由 App Store Connect/RevenueCat 管理；后台不提供价格写入，避免成为第二权威源。
- **管理员 2FA / SSO**：未实现；当前依赖强密码、会话版本、CSRF、限流。
- **批量推送/群发**：未实现，本轮也明确不执行无人值守群发。

## 5. 验证证据

- HTTP：`tests/test_admin_v2_http.py` 3/3、`tests/test_feature_gates_http.py` 1/1。
- 迁移：`account-server/migrate-v2-quality.php`（drift → apply → SCHEMA_OK）。
- 截图：`docs/audits/boji-v2-quality/screenshots/`。
- 页面渲染：16 个页面 200，无 PHP Fatal/Parse/Warning；favicon 404。
- RBAC 矩阵（HTTP 实测）：
  - readonly：`config` 403，写入 403；
  - support：`club` 403，`status` 403，`users` 200；
  - operator：`config`/`admins` 403，`users` 200；
  - content：`badges` 200，`config`/`audit` 403；
  - super：配置/管理员/发布全部成功。
