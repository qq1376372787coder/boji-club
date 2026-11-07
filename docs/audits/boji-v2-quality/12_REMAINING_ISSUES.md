# 未解决问题与后续任务队列

## A. 发布阻断（必须先做）

| ID | 问题 | 证据 | 下一步 | 需要谁 |
|---|---|---|---|---|
| R-01 | APNs 无 entitlement/capability，无法取得 device token | `BojiClub/BojiClub.entitlements`；project capability | Apple Developer 开启 Push，补签名/Provisioning/APNs Key；真机送达 | iOS + Apple 管理员 |
| R-02 | Release API 域名 `api.gongxiang.cloud` NXDOMAIN；IP 测试服已于 2026-10-21 部署并通过 `/config`、`/me`、admin smoke | 本机 curl / DNS；`13_DEPLOYMENT_20261021.md` | 为 Release 恢复正式域名/证书；TestFlight 继续用 IP 并确认 | 运维 + 后端 |
| R-03 | Bundle ID/APNs topic/App Group 的 `.dev` 与正式环境未确认 | `project.pbxproj`；`club-push.php` | 与 App Store Connect/Apple 对齐；更新代码/签名/商品 | iOS + 运营 |
| R-04 | 法律文件为草案，LegalReviewed=false，运营主体/客服未填 | `legal/*`；`Configuration/` | 法务审核、公开隐私政策 URL、更新 App 文案 | 负责人/法务 |

## B. 业务与安全

| ID | 问题 | 下一步 | 风险 |
|---|---|---|---|
| B-024 | 实物奖励资格来自用户同步状态，无设备证明 | 产品决策：App Attest/DeviceCheck；或只让服务端可验证指标参与实物；或人工核验前置 | 高价值奖励可被伪造数据领取 |
| B-025 | 媒体墓碑删除与并发上传锁顺序风险 | 设计“墓碑版本 + 上传提交”协议；并发测试 | 已确认照片可能被误删/15s 锁超时 |
| B-026 | 自动 AI 日报/周报终态失败不重试 | 增加有界重试/冷却/后台手动重跑；报告失败原因 | 供应商短故障会丢失当天报告 |
| B-027 | AI 归档 scope 混淆同日两次训练；source_checker 未接线；无保留策略 | scope 加 source_session；main() 注入 checker；归档 TTL | 报告误标 stale、陈旧结果当新结果、SQLite 膨胀 |
| B-011 测试缺口 | Apple nonce 表已加，但无完整签名 token 的重放 HTTP 测试 | 用测试 RSA 夹具/测试路由模拟 `/auth/apple/verify` 两次 | 回归保护不足 |
| B-013 限制 | 通知测试需 APNs 配置与真机；未验证送达 | R-01 后执行；失败原因入库 | 运营误判“已发送” |
| B-028 | 通知定时计划未接调度器 | 接入或移除入口；当前已标注草稿 | 运营误以为已自动群发 |
| B-029 | 无训练内容管理/AI Prompt 管理/Token 成本/2FA | 单独立项，不要用假页面 | 后台能力边界/安全 |

## C. 工程与性能

| ID | 问题 | 建议 |
|---|---|---|
| B-030 | `/me/state` 整包 16MB；`decodedState` 双次校验；AI 归档全表 UPDATE | 真实数据量 profiling；按日增量；缓存；归档 scope/索引 |
| B-026 | 自动任务重试 | 与 B-026 合并处理 |
| - | 后端 `data_integrity_engine.py` 与 `automation_core` 内副本重复，且副本修复逻辑有 scope 风险 | 删除死文件或统一为一个有测试的实现；不要同时保留两套 |
| - | PHP 管理后台无深色模式、无 2FA、无批量操作 | 视运营需求迭代；先保证权限与审计 |
| - | 后台配置无灰度 | 如需灰度，增加按构建/比例；不要显示假“灰度”开关 |
| - | 状态同步冲突 UI 的解释 | 双设备真实测试后再优化 |

## D. 环境限制（本轮无法执行）

1. 真机签名/安装/触控/Live Activity/后台恢复。
2. Apple Sign-In 真实授权与 identity token 样本。
3. HealthKit 真实权限（部分授权/撤权）、真实健康数据。
4. RevenueCat/App Store Sandbox 购买、恢复、续订、退款、Webhook 真实投递。
5. APNs 真实送达（受 R-01 阻断）。
6. iOS 17 runtime、小屏、VoiceOver、辅助字号。
7. 生产 MariaDB 10.11 迁移与真实数据回归。
8. 生产负载/慢查询/成本实测。

## E. 复现命令（本机隔离环境）

```bash
# Python 离线
python3 -I tests/run_offline.py

# PHP（需隔离 MySQL；本机工具在 /tmp/boji-tools，不提交）
BOJI_TEST_DSN_BASE='mysql:host=127.0.0.1;port=13306' \
BOJI_TEST_DB_USER=root BOJI_TEST_DB_PASSWORD='' \
PHP=/tmp/boji-tools/php tests/run_php_suite.sh

# Swift 生成式回归
python3 tests/run_swift_regressions.py --output /tmp/boji-swift-regressions --jobs 3

# TestFlight 配置模拟器构建
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight \
  -configuration TestFlight -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/boji-v2-build CODE_SIGNING_ALLOWED=NO build

# 后台 HTTP（先启动隔离 PHP 服务）
BOJI_ADMIN_BASE=http://127.0.0.1:8090 \
python3 -m unittest tests.test_admin_v2_http tests.test_feature_gates_http -v

# 迁移检查
BOJI_MIGRATION_DSN='mysql:host=127.0.0.1;port=13306;dbname=bojiclub_v2_it;charset=utf8mb4' \
BOJI_MIGRATION_USER=root BOJI_MIGRATION_PASSWORD='' \
php account-server/migrate-v2-quality.php --check
```

## F. 结论

本轮已经把“无法编译”“后台无权限/无配置发布/假通知测试”“会员交易号覆盖”“Apple 重放”“俱乐部锁 DoS”“AI 关键输入校验/队列”等可验证问题实际修复并测试。  
剩余问题主要集中在 **Apple 平台配置、法律合规、真实设备/商店验证、以及需要产品决策的奖励资格**；这些不能通过继续改 UI 或写更多静态报告解决，必须由对应负责人确认。
