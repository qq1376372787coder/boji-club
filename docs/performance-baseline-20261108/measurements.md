# 性能基线快照 · 2026-11-08（批次 0 完成后）

- 来源：GitHub Actions run [42498401537](https://github.com/qq1376372787coder/boji-club/actions/runs/42498401537)
- 提交：`f8d2c54`（main）
- 配置：**Debug**（Chief 拍板写死 Debug 路线，理由见文末）
- 设备：iPhone 16 Pro 模拟器，iOS 26.2，arm64，macOS 26.7.2 / Xcode 26.6
- 制品：`performance-baseline`（57.9 MB，保留 30 天）
- 结果：`totalTestCount: 2`，`passedTests: 2`，`result: Passed`

## 测量值（各 5 次迭代）

### testLaunchBenchmark（冷启动）

| 指标 | 平均 | 相对标准差 | 5 次采样 |
|---|---|---|---|
| Duration (AppLaunch), s | 3.178 | 29.842% | 4.977 / 3.083 / 2.603 / 2.989 / 2.237 |

### testScrollBenchmark（训练页滚动）

| 指标 | 平均 | 相对标准差 | 5 次采样 |
|---|---|---|---|
| Duration (Scroll_DraggingAndDeceleration), s | 0.865 | 0.754% | 0.852 / 0.868 / 0.868 / 0.868 / 0.869 |
| Clock Monotonic Time, s | 2.683 | 5.319% | 2.706 / 2.852 / 2.814 / 2.481 / 2.562 |
| CPU Time (dev), s | 0.860 | 10.097% | 0.966 / 0.799 / 0.777 / 0.791 / 0.966 |
| Absolute Memory Physical, kB | 110151 | 0.224% | 109666 / 110256 / 110240 / 110240 / 110355 |
| Memory Peak Physical, kB | 110377 | 0.206% | 109929 / 110486 / 110469 / 110453 / 110551 |
| CPU Instructions Retired, kI | 0.000 | — | 模拟器上该计数器不可用 |
| CPU Cycles, kC | 0.000 | — | 模拟器上该计数器不可用 |

> CPU Instructions Retired 与 CPU Cycles 在模拟器上恒为 0，不能作为对比指标；BUG-007 的 CPU 对比请用 **CPU Time**。

## 口径说明

- **Debug 路线写死**：App 的测试钩子（`BOJI_PREVIEW_ACCOUNT`、`BOJI_UI_TEST_SEED`）都在 `#if DEBUG` 内，Release 包驱不动登录态，UI 用例无法运行。为不改动账号链路，基线与批次 2 后测统一用 Debug，报告标注口径。
- 这是**批次 0 完成后的管道验证快照**；正式基线按 Chief 定的时点取在**批次 1 收尾**（批次 2 整屏视频的对照组）。
- 10-24 旧基线（`docs/native-ui-20261024/performance/`）同为 Debug 数据，按「同配置对比」铁律可作对照。
