# Phase 0 实施报告

## 本阶段目标与可验证范围
读取 00A/01–06/07 全部治理文档，审计真实源码、数据库契约、部署结构；建立 UI 冻结基线；回答“周四改周六”写入路径与单一权威问题。范围仅限本地隔离工作区。

## 审计到的真实现状（文件路径 + 关键函数/数据模型）
- iOS SwiftUI + PHP BFF + Python AI Worker；业务权威在 `app_states` 文档 + 分片，命令入口 `commands.php:30 handleBusinessCommandCore`。
- AI 为同步 JSON 代理 + 客户端轮询（`weekly.php`、`AIService.swift`）；**无 SSE**。
- 提案/幂等/Outbox/对账/租约已实现（`ai_action_proposals`、`data_operations`、`domain_outbox`、`domain-consumer-inbox`）。
- 缺失：SSE、trace 全链路、动作 variant/负重口径、per-100g 营养引擎、结构化安全分流、Golden Evals、后台 backlog 视图。

## 实施设计与理由（ADR）
- ADR-001：复用现有命令/提案/Outbox，不新建平行业务表。
- ADR-002：SSE 采用“持久 Run + 事件日志 + GET 订阅”，POST 幂等建立 Run，断线用 `after_seq`/`Last-Event-ID`；客户端失败回退现有轮询。
- ADR-003：确定性专业规则放 Python（可测试、已是 AI 引擎层），PHP 仅做鉴权/能力路由/薄代理。
- ADR-004：UI 仅最小数据接线，完成结果注入现有 `AILocalJob` 复用原渲染。

## 修改文件及数据库迁移列表
- 文档：`docs/v2/00–05`、`docs/v2/overnight/*`、`docs/v2/ui_baseline_hashes.txt`。
- 源码：本阶段未修改业务代码（基线 commit `313e91e`）。

## API/Schema/Feature Flag 变更
- 规划新增 Run API 与 `ai_runs`/`ai_run_events`、可空 `trace_id`、`ai_streaming_v2` flag（见 `03_MIGRATION_PLAN.md`），尚未应用。

## 实际测试：命令、版本、结果、失败用例
| 命令 | 结果 |
|---|---|
| `xcodebuild ... build` | BUILD SUCCEEDED，exit 0 |
| `python3 tests/run_offline.py` | 676 tests OK，exit 0 |
| `python3 tests/run_swift_regressions.py --output ...` | 32/54 PASS；22 个历史 harness 编译失败（基线） |
| `xcrun simctl ... screenshot` | 2 张基线截图 |

## 手动 E2E 与截图/录屏证据
- 模拟器启动与预览账号截图：`evidence/ui_baseline/launch_01.png`、`shell_complete_01.png`。
- 未做真实后端 E2E（本机无 PHP/MySQL）。

## 性能、安全、用户体验的变化
- 无运行时代码变更；无性能影响。

## 发现并修复的回归问题
- 无（本阶段只审计）。

## 遗留风险和下一阶段依赖
- PHP/MySQL 运行时缺失，PHP 侧只能静态审查；真实模型/APNs/HealthKit 未验证。
- SSE 服务端依赖新增 timer 与迁移。

## 数据备份、灰度、回滚操作步骤
- 见 `03_MIGRATION_PLAN.md`；未执行生产操作。

## 是否满足门禁：YES/NO + 证据
- Phase 0 完成门槛 **YES（审计与基线）**；G0–G6 全量门禁 **NO**（依赖后续阶段与缺失运行时）。
