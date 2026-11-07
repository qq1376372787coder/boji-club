# 后台配置到 App 的真实生效验证

> 原则：后台显示“保存成功”只代表请求被接受一次。本文件只把经过 **API → DB → 业务读取 → 客户端** 证据链的项目标为“已验证”。

## 1. 新增的配置模型

| 层 | 实现 |
|---|---|
| 表 | `app_config(config_key,draft_json,published_json,draft_version,published_version,updated_by,updated_at,published_at)`；`app_config_versions` 记录 draft/publish/rollback |
| 校验 | 白名单 key、严格类型、公告长度、最低构建 ≤ 最新构建；未知字段拒绝 |
| 后台 | 仅 `super_admin`；保存草稿、发布、恢复历史为草稿、乐观版本检查；全部动作审计 |
| 公开 API | `GET /account/v1/config`（无需登录，**只返回 published**）；`Cache-Control: private, no-cache` + ETag + `X-Config-Version` |
| 服务端生效 | `ai_enabled` 阻断 AI 创建/重试；`club_enabled` 阻断 `/club/*`；下一次请求立即生效 |
| iOS | `AccountService.loadRemoteConfig()`；App 启动/回前台（5 分钟节流）读取；顶部安全区公告/最低构建提示；关闭状态按配置版本记录 |
| 安全边界 | 数据库密码、AI owner token、APNs Key、RevenueCat webhook secret **不在**配置中心，也不下发给客户端 |

公开配置（当前 5 组）：

```json
{
  "ai_enabled": true,
  "club_enabled": true,
  "minimum_build": 0,
  "latest_build": 0,
  "announcement": {"enabled": false, "title": "", "body": ""}
}
```

## 2. 七步验证结果（真实 HTTP）

测试环境：本机 PHP 8.3.22 + MySQL 9.4 + 真实 `admin/index.php`；超级管理员会话；PHP 内置服务器。测试脚本：`tests/test_admin_v2_http.py`、`tests/test_feature_gates_http.py`。

| 步骤 | 实测 |
|---|---|
| 1. 读取初始值 | `/config` 返回 `version=0`，默认 AI/俱乐部开启、公告关闭 |
| 2. 修改配置 | 后台保存草稿：AI 关闭、最低构建 120、最新 121、公告开启 |
| 3. 验证写入/草稿隔离 | GET `/config` **版本和值均未变**，证明草稿不公开 |
| 4. 发布 | 后台 `config_publish` 成功；公开版本递增；返回 `ai_enabled=false`、`minimum_build=120`、公告标题正确 |
| 5. 业务读取 | 发布 `ai_enabled=false` 后 `POST /me/ai/jobs` → 503“AI 分析暂未开放”；`club_enabled=false` 后 `GET /club/current` → 503 |
| 6. 异常 | 最低构建 > 最新构建被拒绝；管理员页面校验失败返回错误文本；非超级管理员页面 403、写入 403；ETag 重复请求 304 |
| 7. 恢复 | 后台保存并发布默认值；重新 GET `/config` 恢复默认；测试清理保持已发布默认行 |

## 3. 配置项到客户端的现状

| 配置 | 后台 | 服务端 | iOS | 结论 |
|---|---|---|---|---|
| `ai_enabled` | 有 | 创建/重试阻断 | 未在客户端隐藏入口；服务端返回明确错误 | **端到端（服务端 + HTTP）已验证**；客户端 UI gate 未做 |
| `club_enabled` | 有 | `/club/*` 阻断 | 服务端错误显示 | **服务端已验证** |
| `minimum_build` | 有 | 公开 | 顶部提示（不强制退出） | **API/解码/构建验证**；真机视觉未验证 |
| `announcement` | 有 | 公开 | 顶部提示 | 同上 |
| `latest_build` | 有 | 公开 | 当前只作运营参考 | 信息性 |
| AI 容量/单账号上限 | 有 | Python controls | 无 | Python 单元/并发验证；后台到 Python 的真实回环需部署后验证 |
| AI 供应商/模型 | 有 | Python providers | 无 | 接口与状态代码验证；未用真实密钥调用模型 |
| Prompt 模板 | **无** | 硬编码 | 无 | 未实现，不能伪造 |
| 成长季/奖励规则 | 有 | MySQL + `/club` | 读取 | 既有 PHP/Swift 回归通过；未做真机 E2E |
| 通知模板 | 有 | 真实 APNs 单成员测试 | 用户通知权限 | 因无 APNs 配置/真机，**未送达验证** |
| 通知定时计划 | 草稿 | **无调度器** | 无 | 明确未接入 |

## 4. iOS 端验证边界

- 代码已编译进 TestFlight 配置构建（**BUILD SUCCEEDED**）；`ClubRemoteConfig` 的 JSON key 与 `/config` 响应逐项对应。
- 未在模拟器/真机通过真实账号登录后截图公告；原因：预览账号与服务端登录/网络路径不同，且本轮没有部署公开测试服务器。
- 公告与最低构建提示是**非强制**提示；不会因为配置错误直接锁死 App。
- 服务端开关是强制的；这也是本轮最能证明“后台→业务生效”的链路。

## 5. 仍需生产前完成的验证

1. 在 staging 部署 `migrate-v2-quality.php`，用真实 MySQL/MariaDB 复核迁移。
2. 用真实管理员发布一次公告/最低构建，在 TestFlight 真机观察顶部提示和关闭状态。
3. 用真实 APNs Key/真机验证模板测试发送；当前本地因未配置 APNs 只能验证错误路径。
4. 用真实 RevenueCat/Apple 配置验证会员权益与配置无冲突。
5. 明确“灰度发布/强制更新/撤回”策略；当前版本没有灰度，发布即对所有读取者生效。
