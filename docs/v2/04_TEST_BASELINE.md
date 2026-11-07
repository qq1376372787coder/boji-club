# Phase 0 · 测试基线（TEST_BASELINE）

## 1. 环境

- macOS 26.5.2 (arm64)，Xcode 26.6 (17F113)，Python 3.9.6，iOS Simulator iPhone 17 / iOS 26.5。
- **无 PHP、无 MySQL/MariaDB、无 Docker**（`php: command not found`）。
- 未配置真实模型 Key、APNs、HealthKit 真机授权、Apple 签名。

## 2. 实际执行结果（基线）

| 检查 | 命令 | 结果 | 证据 |
|---|---|---|---|
| iOS Debug 构建 | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED**，exit 0 | `evidence/xcodebuild_baseline.log` |
| Python 离线回归 | `python3 tests/run_offline.py` | **676 tests OK**，exit 0，18.7s | 终端输出已记录于本文件 §3 |
| Swift 规则回归 | `python3 tests/run_swift_regressions.py --output evidence/swift_regressions_baseline.json` | **32/54 PASS**；22 个 harness 基线编译失败 | `evidence/swift_regressions_baseline.json/*.compile.log` |
| PHP 集成 | `tests/run_action_checks.sh` | **未执行**（缺 PHP/MySQL） | `BLOCKED_ACTIONS.md` |
| 迁移 | `migrate-v2-repair.php --apply/--check` | **未执行**（缺 PHP/MySQL） | `BLOCKED_ACTIONS.md` |
| UI 基线截图 | `xcrun simctl io ... screenshot` | 已采集 2 张 | `evidence/ui_baseline/*.png` |

## 3. Python 基线原始摘要

```
Sole AI home / first-plan / rest-day flow checks passed
AI workspace insight / report / share extraction checks passed
OFFLINE_MODULES ... (58 modules)
Ran 676 tests in 18.749s

OK
```

> 输出中的 `AI worker error: OperationalError` 等三行来自故障注入用例，断言仍全部通过。

## 4. Swift 基线失败（预先存在，不是本轮引入）

22 个 harness 因历史生成代码与当前模型不匹配而编译失败，例如：

```
build_ui_v47_swift_tests.swift:4973: error: type 'Self' has no member 'mergeHealthMeasurements'
```

完整列表见 `docs/v2/overnight/PHASE_0_CHECKPOINT.json` 的 `swiftBaselineFailures`。本轮不修复与任务无关的历史 harness，避免扩大变更面；新增/修改模块将补充独立可运行的 Swift 测试并纳入最终回归对比。

## 5. 本轮新增测试计划（真实可执行）

| 层 | 范围 | 工具 |
|---|---|---|
| Swift XCTest | SSE frame 解析（空行/多行 data/CRLF/注释/UTF-8/Last-Event-ID）、seq 去重、重连状态机、Run 事件 reducer | `xcodebuild test` + 独立 harness |
| Swift 集成 | 本地 Python 假 SSE 服务端：POST run → 事件流 → 断线 → `after_seq` 续传 → 410 快照恢复 | XCTest + localhost |
| Python 单元 | Fitness 引擎（variant/负重口径/覆盖度/红旗/渐进）、Nutrition（per-100g/可食质量/区间/冲突）、Personal（冷却/排序/证据门槛） | `unittest` |
| Python 契约 | 100+ 条 Golden intents：意图分类、能力选择、禁止写、含糊日期、注入参数 | `tests/run_golden_evals.py` |
| iOS 构建/UI | Debug/Release 模拟器构建；U01–U07 关键路径截图 | `xcodebuild` + XCUITest |
| PHP | 新增 Run/路由/迁移的集成测试脚本 | `tests/run_ai_runs.sh`（需 PHP+MySQL，本机 BLOCKED） |

## 6. 发布门禁映射（本轮可验证部分）

- G0 ARCHITECTURE：审计完成（本文件 + `00/01/02`）。
- G1 SAFETY：跨用户隔离由既有 `user_id` 条件 + 新 Run 端点同规则覆盖；PHP 集成待环境。
- G2 CORE：既有 Python/Swift 回归通过；E2E 受 PHP/DB 限制。
- G3 AI ACTION：提案/确认/幂等既有测试（PHP 未本地执行）；SSE 客户端协议测试。
- G4 DATA/PRIVACY：记忆/删除/授权既有实现审计；无真机 HealthKit 证据。
- G5 OPERATIONS：新增聚合端点与 runbook；仅静态审查。
- G6 UX_FREEZE：基线哈希 + 截图 + UITest；最终差异报告。
