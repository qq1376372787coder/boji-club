# 代码修改记录

所有修改均在本地独立 Git 分支历史中，可回滚。基线：`1e2a2c5`。没有生产部署。

| Commit | 范围 | 主要内容 |
|---|---|---|
| `ac87bb2` | iOS | 修复 TestFlight 编译阻塞；AI 日报发送 `timeZone`；新增公共配置读取与公告/最低构建提示；清理非 Optional 警告 |
| `fcfb007` | Python AI / 测试 | 时区兜底；notes/photoFeedback 剂量防护；单账号未结束任务上限；attempt 日志失败不丢结果；密钥变更重置熔断；日程提案冲突；动作 API 字段防护；新增 12 项回归 |
| `cf6665f` | PHP 服务 / DB | 权益交易号按账号作用域；Apple nonce 一次性；俱乐部申领锁外计算进度；Profile.Update 修正；账号注销审计脱敏；真实 APNs 测试发送；配置中心表与公开端点；服务端功能开关；迁移脚本 |
| `26928e4` | 管理后台 / 测试 | RBAC（5 角色）、管理员页、配置页、真实 Dashboard、通知页真实测试、审计补强、Design System/响应式；PHP/HTTP 测试 |
| `e4b6fc2` | 工程卫生 | 恢复 `backend/server.py` 原 CRLF，避免无意义全文件 diff |
| `e232c1f` | iOS 可访问性/测试 | 餐食分类改为显式可访问 Header Button（唯一标识/展开状态/独立编辑删除标识）；修复 AX3 大字号点击；UI 测试选择器/等待稳定；公告关闭按钮改名避免“关闭”歧义 |
| `066e564` | 管理后台 | 只读角色隐藏无权限写入表单；真实通知测试限定 operator/super；HTTP 回归补充 |

## 逐项说明

### 1. iOS（`ac87bb2`）

- `BojiClub/DesignTokens.swift:1039`：`onChange(of:)` 的旧值在 iOS 17+ 是非 Optional；移除 `guard let`。这是原包 **P0 编译阻塞**。
- `BojiClub/AIService.swift:425`：`report` 也发送 `TimeZone.current.identifier`，与服务端校验一致。
- `BojiClub/AccountService.swift`：新增 `ClubRemoteConfig`、`loadRemoteConfig()`；从一致 API 基址读取 `/config`，仅接受已发布公开配置；网络/解码失败不阻塞 App。
- `BojiClub/BojiClubApp.swift`：RootView 顶部安全区展示公告/最低构建提示；按配置版本记住关闭；每 5 分钟节流刷新。
- `BojiClub/PlanShiftViews.swift`：修复 `reps` 非 Optional 的无效 `??` 警告。
- `BojiClub/NutritionView.swift`：餐食分类由 `DisclosureGroup` 改为显式可访问按钮；唯一 `meal-group-*` 标识、展开/收起无障碍状态、独立餐食编辑/删除标识；修复 AX3 下大尺寸分组点击不稳定。
- `.gitignore`：忽略本地工具链、测试配置、运行时媒体和证据目录，防止凭据/大文件进入提交。

### 2. Python AI（`fcfb007`）

- `backend/ai_core.py`
  - 缺少 `timeZone` 时使用 UTC+14 作为“最晚本地今天”，避免东八区以东用户被误判未来日期。
  - `validate_coaching` 将 `notes`、`photoFeedback` 纳入剂量/营养处方检查。
  - `Router.record_attempt_best_effort`：日志写入失败不再丢弃有效结果。
  - `Router.replace_providers`：供应商密钥变化时重置熔断状态。
- `backend/server.py`
  - 新增 `account_pending_limit`（默认 8），创建与重试都检查单账号未结束任务；`0` 表示不限。
  - 新增 `clear_key` 管理接口参数，可真正删除旧密钥。
- `backend/adaptive_core.py`：拒绝移动到已有安排的日期、拒绝链式/重复移动。
- `exercise-server/api.py`：`instruction_steps` 非字典时返回空数组而不是崩溃。
- `tests/test_v2_quality_regressions.py`：12 项回归（时区、guardrail、配额、日志、熔断、日程、动作 API）。
- `tests/test_ai_capacity.py`、`tests/test_batch2_ai_reliability.py`：更新默认值与显式时区断言。

### 3. PHP 服务（`cf6665f`）

- `account-server/schema.sql` + `migrations/20261020-entitlement-transaction-scope.sql`：`last_transaction_id` 去掉全局 UNIQUE，保留普通索引，防止跨账号覆盖。
- `account-server/public/apple-auth.php` + `apple_auth_nonces`：Apple nonce 10 分钟一次性消费；重复使用返回 401。
- `account-server/public/index.php:642`：俱乐部实物申领在获取全库锁之前计算进度（会调用 AI metadata），消除跨用户 HTTP 锁阻塞。
- `account-server/public/account-deletion.php:99`：注销不再删除管理员审计；保留操作类型/管理员/时间并脱敏成员关联。
- `account-server/public/commands.php`：
  - Profile.Update 使用真实列 `height_cm/weight_kg`，补齐 `nickname/days_per_week` 等 NOT NULL。
  - 分区账号明确返回 409，不再假成功。
  - Schedule.Rest/Workout.Confirm 未实现语义，明确返回 400，不再静默成功。
- `account-server/public/club-push.php`：抽出 `clubPushSendContent`，支持后台单成员测试内容。
- `account-server/public/app-config.php` + `/config` + `weekly.php` gate：
  - 公开配置 Schema 校验；草稿绝不公开。
  - `ai_enabled` 关闭时阻断 AI 创建/重试；`club_enabled` 关闭时阻断俱乐部路由。
- `account-server/migrate-v2-quality.php` + `deploy.sh`：可重复迁移；已用旧 schema 验证 `drift → apply → SCHEMA_OK`。
- `account-server/admin/bootstrap.php`：`notification_test` 改为真实 APNs 单设备发送；增加配置/管理员/容量动作；所有破坏性动作补审计。

### 4. 管理后台（`26928e4`）

- `admin-schema.sql`：新增 `role`/`status`。
- `admin/bootstrap.php`：
  - 5 角色：`super_admin/operator/content/support/readonly`；页面可见 + 动作写入双重服务端校验。
  - 配置草稿/发布/回滚；乐观版本检查；审计。
  - 管理员创建/改角色/停用/重置密码；保护最后一个超级管理员与当前登录账号。
  - 登录 dummy hash、双桶限流、停用账号拒绝。
  - 通知真实测试、AI 容量单账号上限、AI 密钥清除。
  - 集中 `adminAuditLabels()`。
- `admin/index.php`：
  - 4 组导航；`config`、`admins` 页面；16 个页面统一标题/说明/面包屑。
  - Dashboard 增加有效会员、今日 AI 任务、待履约、需要关注、最近操作。
  - 通知页明确计划未接入，测试发送字段改为成员 ID。
  - 移动端菜单默认折叠。
- `admin/style.css`：设计 Tokens、布局、表格、表单、按钮、状态、空态、响应式；保留所有旧 class。
- `admin/ai-capacity.php`：单账号未结束上限与实时展示。
- 测试：`test_admin_v2_http.py`（3）、`test_feature_gates_http.py`（1）、`test_app_config.php`、`test_membership_scope.php`；PHP suite 扩到 38。最终 XCUITest 14/14、TestFlight 配置构建 **BUILD SUCCEEDED**。

## 修改原则与边界

- 没有修改真实生产数据库、服务器、Apple/RevenueCat 配置。
- 新增表/列只扩不缩；迁移可重复执行；旧管理员在迁移后保留超级管理员权限。
- 没有把密钥写入代码、提交或报告；本地 `config.php` 已被 `.gitignore` 忽略。
- 未完成事项在 `02_BUG_REGISTER.md` 与 `12_REMAINING_ISSUES.md` 明确列出，不以“已修复”掩盖。
