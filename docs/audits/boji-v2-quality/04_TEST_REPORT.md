# 自动化测试报告

日期：2026-10-20  
环境：macOS 26.6.2 arm64；Xcode 26.6 / Swift 6.3.3；Python 3.9.6；隔离工具链 PHP 8.3.22（static）、MySQL 9.4.0、Node 24.18.0、Chrome headless。  
所有测试使用隔离数据库/临时目录；**未连接生产**。

## 1. 总览

| 层级 | 命令 | 结果 |
|---|---|---|
| Python 离线 | `python3 -I tests/run_offline.py` | **639 tests, OK**（19.5s） |
| PHP 隔离数据库 | `BOJI_TEST_DSN_BASE='mysql:host=127.0.0.1;port=13306' ... tests/run_php_suite.sh` | **38 passed, 0 failed** |
| Swift 生成式回归 | `python3 tests/run_swift_regressions.py --output /tmp/boji-swift-regressions --jobs 3` | **51/51 harnesses passed** |
| iOS TestFlight 构建 | `xcodebuild ... -scheme BojiClub-TestFlight -configuration TestFlight -sdk iphonesimulator ... build` | **BUILD SUCCEEDED** |
| 管理后台 HTTP | `python3 -m unittest tests.test_admin_v2_http -v` | **3/3 passed** |
| 功能开关 HTTP | `python3 -m unittest tests.test_feature_gates_http -v` | **1/1 passed** |
| 数据库迁移 | `migrate-v2-quality.php --check → apply → --check` | 6 项 drift → 应用 → **SCHEMA_OK** |
| 后台页面渲染 | 无头 Chrome 1440×1000 + 390×844 | 16 页 + 3 移动页；无 PHP 错误；仅 favicon 404 |
| iOS UI 回归 | XCUITest，`BojiClubUITests`（跳过 testAuditScreenshots） | **见第 6 节（运行结果）** |

## 2. Python 回归

- 修复前基线：627 项通过。
- 本轮新增 `tests/test_v2_quality_regressions.py` 12 项：
  - 旧客户端无时区日报的本地“今天”边界；
  - 报告 notes、周报 photoFeedback 的数字处方拒绝；
  - 单账号未结束任务上限（创建 + 重试）；
  - attempt 日志 SQLite 失败后仍返回有效结果；
  - 供应商密钥变化清除熔断；
  - 日程移动覆盖已有训练 / 链式移动拒绝 / 简单移动保留；
  - 动作 `instruction_steps` 非字典不崩溃。
- 调整既有断言：
  - `test_ai_capacity.py` 预期新增 `account_pending_limit=8`；
  - `test_batch2_ai_reliability.py` 的“未来日期”用例显式传 `Asia/Shanghai`，并保留无时区兼容用例在新增文件中。

结果：**639/639 通过**。

## 3. PHP 回归

- 修复前历史记录 36 项；本轮扩展：
  - `tests/test_app_config.php`：默认值、草稿不公开、发布、Schema 校验、功能开关、版本记录不被读取路径写入。
  - `tests/test_membership_scope.php`：两个账号相同 `last_transaction_id` 时两行都存在，且不会覆盖第一个账号。
- 结果：**38/38 通过**；日志在 `/tmp/boji-php-suite`（本机临时目录，不提交）。
- 限制：使用 MySQL 9.4，不是生产 MariaDB 10.11；迁移需在 staging 复跑。

## 4. iOS 回归与构建

- `tests/run_swift_regressions.py` 逐项生成、编译、执行：
  ```
  51/51 Swift harnesses passed
  ```
- TestFlight 配置构建：
  ```
  xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight \
    -configuration TestFlight -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/boji-v2-build CODE_SIGNING_ALLOWED=NO build
  ** BUILD SUCCEEDED **
  ```
- 构建产物：`/tmp/boji-v2-build/Build/Products/TestFlight-iphonesimulator/BojiClub.app/BojiClub`。
- 在全部 iOS 改动（远程配置/时区/餐食可访问性）完成后再次执行同一命令：**BUILD SUCCEEDED**。
- 关键事实：修复前使用同一 Xcode/目标构建失败（`DesignTokens.swift:1039`）；历史“完整构建通过”声明不成立于当前源码/Xcode。

## 5. 管理后台与配置链路测试

### HTTP 测试覆盖

`tests/test_admin_v2_http.py`
1. 超级管理员：登录、配置页、草稿保存不改变公开版本、发布后版本递增、公开值正确、ETag 304、非法最低/最新构建被拒绝、恢复默认。
2. 只读/客服/运营/内容边界：页面 403、写入 403；客服可看成员但不能改状态；内容可看徽章但不能看配置/审计。
3. 管理员创建/重复提示/审计页可见操作。

`tests/test_feature_gates_http.py`
- 发布 `ai_enabled=false` → `POST /me/ai/jobs` 返回 503 “暂未开放”；
- `club_enabled=true` → `GET /club/current` 200；
- 发布 `club_enabled=false` → 503；
- AI 开关恢复后同一请求通过 gate，落到“AI 服务未配置”分支，证明不是无条件拒绝。

### 迁移验证

在仅含旧 schema 的 `bojiclub_migrate_test`：
```
SCHEMA_DRIFT
admin_accounts.role
admin_accounts.status
table app_config
table app_config_versions
table apple_auth_nonces
membership_entitlements.last_transaction_id UNIQUE
→ APPLIED 6 items
→ SCHEMA_OK
```
`migrate-v2-quality.php --check` 可重复执行。

### 后台渲染与截图

无头 Chrome 访问 16 个页面均返回 200，标题/页面结构正确；未发现 PHP Fatal/Parse/Warning 文本；唯一 404 为浏览器默认 favicon。  
证据：`docs/audits/boji-v2-quality/screenshots/`（overview、config、roles、notifications、ai、mobile overview）。

## 6. iOS UI 回归

- 目标：`BojiClubUITests`，15 个用例，本轮跳过 `testAuditScreenshots`（截图审计专用），计划执行 14 个。
- 模拟器：iPhone 17 Pro Max，iOS 26.5（`93ACF322-5964-4E3D-B436-547A5F9B4C88`）。
- **实际结果：见下方“运行记录”。若该行为空，表示本机 UI 测试仍在编译/执行，不能用静态分析替代。**
- 覆盖：五标签、动作库抽屉、日历移动预览、迷你训练栏跨 Tab/重启、只确认组数、Club AI 单层导航、记录趋势、组合可访问性、长餐名、训练表格首屏等。

### 运行记录

首次全量运行（23:18–23:26，iPhone 17 Pro Max / iOS 26.5）为 **11/14**，3 个失败均定位为测试选择器/时序问题：
- 旧文案“问 Club AI”在当前页面实际入口为“问教练”；
- 日历移动页同时存在导航栏“关闭”和遮罩 xmark，测试要求唯一匹配；
- AX3 餐食分组原 `DisclosureGroup` 的标识传播到子元素，且大字号下中心点落在视口外。

处理：
- 更新教练入口选择器；
- “关闭”改 firstMatch；
- 将餐食分类改为显式可访问 Header Button（唯一 `meal-group-*`，展开/收起状态，独立编辑/删除标识），并在测试中等待布局稳定后 tap。

**最终全量复跑（23:52 左右）：**
```
Executed 14 tests, with 0 failures (0 unexpected) in 319.296 seconds
** TEST SUCCEEDED **
```
14/14 通过。首次失败不再以“重跑一次就过”掩盖：它暴露并修复了真实的测试选择器/可访问性标识问题。

## 7. 未执行 / 环境限制

| 项目 | 原因 |
|---|---|
| 真机安装、签名、启动 | 无 Apple 开发者签名/设备授权 |
| Apple Sign-In 真实授权 | 无 Apple 账号交互与真实 identity token |
| HealthKit 真实读写/部分授权/撤销 | 模拟器无真实健康数据；真机未验证 |
| RevenueCat Sandbox 购买/恢复/退款/续订 | 会触发真实商店沙盒交易，未获授权 |
| APNs 真实送达 | 无 APNs Key、无推送 entitlement/provisioning、无真机 |
| iOS 17 runtime / 小屏 / VoiceOver | 本机 runtime 为 iOS 26.5；未做 iOS 17 与无障碍真机检查 |
| 生产 MariaDB 10.11 迁移 | 本机用 MySQL 9.4；需 staging 再验证 |
| 压力/并发生产规模 | 未对生产服务进行负载测试，避免影响真实用户 |
