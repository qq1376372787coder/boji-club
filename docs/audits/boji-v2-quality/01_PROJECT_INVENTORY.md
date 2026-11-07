# 项目真实模块与覆盖清单

## 1. 代码规模（基线扫描）

| 区域 | 位置 | 规模/说明 |
|---|---|---|
| iOS App | `BojiClub/*.swift` | 70 个 Swift 文件，约 34.8k 行；SwiftUI，最低 iOS 17 |
| Widget | `BojiClubWidget/` | 小组件与独立 entitlements |
| UI 测试 | `BojiClubUITests/` | 15 个 XCTest 用例（1 个审计截图用例被本轮跳过） |
| 账号/管理 PHP | `account-server/` | `public/index.php` 917 行主路由；admin 单页 + 10 个 include；55 张表（隔离库实测） |
| AI 工作服务 | `backend/` | `server.py` 1137 行、`ai_core.py` 1426 行、`automation_core.py` 1146 行、`data_integrity_engine.py` 910 行 |
| 动作目录 | `exercise-server/` | `api.py` 256 行 + 678 动作目录 JSON |
| 测试 | `tests/` | Python 639 项离线；PHP 38 项；Swift 生成器 51 项；HTTP 集成 4 项 |
| 文档/证据 | 根目录 md、`audit/`、`delivery-evidence/`、`repair-evidence-20261020/` | 历史记录，仅作为背景，不作为本轮验收结论 |

## 2. 真实功能地图

### iOS

- `AppStore.swift`：本地优先的 `SavedState`（`days`、计划、餐食、体重、AI 任务、周期、草稿）；持久化、journal、云同步、周复盘应用、AI 计划应用、图片清理。
- `CloudSync.swift` / `AccountService.swift`：`/me/state` 全量/分区同步、revision 冲突、媒体上传、登录会话、远程配置。
- `HealthData.swift`：HealthKit 读取、按来源选择、运动去重、TCX 导入、训练写入。
- `AIService.swift` / `WeeklyReview.swift` / `ClubCoach.swift`：AI 任务提交、轮询、周复盘、教练对话。
- `ClubSeason.swift`：成长季、进度、徽章、奖励申领；`MembershipService.swift`：RevenueCat + 服务端权益。
- `PlanView.swift`、`ManualPlan*.swift`、`PlanShiftViews.swift`、`TrainingCycle`：计划/日历/顺延；历史记录保存在 `DayLog` 中。
- 设计系统：`DesignTokens.swift`、`BojiComponents.swift`、`Design.swift`。

### PHP 账号服务（`account-server/public`）

| 路由组 | 职责 | 数据写入 |
|---|---|---|
| `/auth/apple/*`、`/auth/code/*` | Apple/开发手机号登录、nonce 校验 | `users`、`sessions`、`apple_auth_nonces` |
| `/me/state`、`/me/onboarding`、`/me/commands` | 账号资料与记录 | `app_states` / `cloud_parts`、`profiles`、`onboarding` |
| `/me/media/*` | 餐食/身体照片 | `user_media`、文件版本 |
| `/me/ai/*`、`/me/weekly/*` | AI 任务代理，不暴露 AI 密钥 | `ai_user_jobs` |
| `/club/*` | 成长季、任务、奖励、申领 | `club_*` 表 |
| `/webhooks/revenuecat`、`/me/membership/verify` | 订阅事件与权益核验 | `revenuecat_*`、`membership_entitlements` |
| `/me/push-device` | APNs 设备登记 | `club_push_devices` |
| `/config` | **新增**发布配置读取 | `app_config`（只读） |

### 管理后台（`account-server/admin`）

登录后 16 个页面：总览、成员列表、成员详情、成长季、徽章库、礼品库、发货、消息中心、AI 服务、自动跟进、推送、存储、系统、审计、系统配置（新增）、管理员与角色（新增）、安全设置。
页面形态：服务端渲染 PHP + 单 CSP 样式/脚本；动作通过同页 POST + CSRF；审计写 `admin_audit`。

### Python AI 工作服务

- `server.py`：HTTP 入口、JobStore（SQLite）、队列、租约、配额、管理 API。
- `ai_core.py`：请求清洗、输出校验、coaching guard、供应商路由。
- `automation_core.py`：自动日报/周报/训练复盘准备。
- `weekly_core.py`、`coach_core.py`、`adaptive_core.py`：周复盘/教练/日程与参数建议。
- `data_integrity_engine.py`：完整性扫描/修复；与 `automation_core` 内副本重复（本轮未删除，风险见剩余问题）。

## 3. 数据所有权与一致性边界

| 数据 | 权威来源 | 读取方 | 风险 |
|---|---|---|---|
| 训练/饮食/身体日记录 | iOS 本地 `SavedState` → PHP `app_states`/`cloud_parts` | iOS、AI、Club、后台 | 客户端自报；整份状态 16MB 上限 |
| 计划周期/日历 | iOS `TrainingCycle` + `DayLog` | iOS、AI 上下文 | 历史记录与当前计划耦合需持续保护 |
| 会员权益 | RevenueCat/Apple + PHP 合并 | iOS、服务端受保护接口 | 交易号唯一性、快照/事件顺序 |
| 成长季规则/库存/申领 | PHP MySQL | iOS、后台 | 资格计算依赖客户端状态 |
| AI 任务/结果 | Python SQLite + PHP 映射 | iOS、后台、推送 | 任务幂等、归档、重试 |
| 系统配置 | `account-server/config.php`（秘密）+ 新 `app_config`（公开） | PHP、iOS、Python（部分） | 过去无单一配置源 |
| 动作库 | 独立 Python `exercise-server` 数据集 | iOS | 非数据库；后台无写入口 |

## 4. 配置来源审计

1. **秘密配置**：`account-server/config.php`（数据库、AI token、APNs、RevenueCat webhook、Apple 私钥路径），不应进入 Git/后台页面。
2. **公开运行配置（新增）**：`app_config` 的 `draft_json/published_json`，仅 5 组安全值（`ai_enabled`、`club_enabled`、`minimum_build`、`latest_build`、`announcement`）。
3. **AI 运行配置**：Python SQLite `controls`（容量/开关）+ `.data/providers.json`（模型供应商、密钥、优先级）。
4. **业务配置**：成长季/任务/奖励、通知模板/计划、推送预算、存储权限等在 MySQL。
5. **iOS 硬编码**：API 基础地址、RevenueCat 商品 ID/Entitlement、AI 路由版本、UI 文案。本轮新增 `/config` 只覆盖公告/最低构建/两个服务端开关；Prompt、模型、成长规则没有下发到客户端。

## 5. “界面存在但业务未完整实现”清单

- 消息中心“定时计划”：表结构/表单存在，调度器未接入（本轮明确标注，不发送）。
- 后台“训练内容管理”：不存在；动作库由独立服务和文件数据集提供。
- AI Prompt 编辑/版本/回滚：不存在；提示词硬编码在 Python。
- AI Token 用量：仅有任务/尝试统计，无 token 成本明细。
- 实物奖励资格：服务端仅重算客户端同步状态，未使用 App Attest/DeviceCheck。
- 服务端自动日报失败终态：不会自动重试（需人工/下一次数据修订）。
