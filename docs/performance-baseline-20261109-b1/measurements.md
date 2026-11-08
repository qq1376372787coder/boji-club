# 正式性能基线 · 批次 1 收尾（f57f77b）

- 来源：GitHub Actions run [42503336067](https://github.com/qq1376372787coder/boji-club/actions/runs/42503336067)
- 取样点：**`f57f77b`**（批次 1 最终收口，含底部坞归属补正）
- 触发方式：tag `ios-perf/batch1-baseline`
- 配置：**Debug**（路线写死，理由见下）
- 设备：**iPhone 16 Pro 模拟器 / iOS 26.2 / arm64**（macOS 26.7.2 / Xcode 26.6）
- 制品：`performance-baseline`（52.7 MB，保留 30 天）
- 结果：`totalTestCount: 2`，`passedTests: 2`，`failedTests: 0`，`result: Passed`

> 这是批次 2（玻璃沉浸 + 三联动）滚动性能对比的**对照组**。批次 2 后测必须同设备、同配置。

## 测量值（各 5 次迭代）

### testLaunchBenchmark（冷启动）

| 指标 | 平均 | 相对标准差 | 5 次采样 |
|---|---|---|---|
| Duration (AppLaunch), s | 5.756 | 56.066% | 12.191 / 3.912 / 4.185 / 4.603 / 3.891 |

### testScrollBenchmark（训练页滚动）

| 指标 | 平均 | 相对标准差 | 5 次采样 |
|---|---|---|---|
| Duration (Scroll_DraggingAndDeceleration), s | 0.852 | 1.802% | 0.868 / 0.836 / 0.834 / 0.870 / 0.851 |
| Clock Monotonic Time, s | 2.804 | 5.851% | 2.607 / 2.678 / 2.940 / 2.751 / 3.046 |
| CPU Time (dev), s | 1.315 | 27.922% | 1.689 / 1.832 / 0.983 / 1.060 / 1.011 |
| Absolute Memory Physical, kB | 108572 | 0.024% | 108569 / 108602 / 108602 / 108552 / 108536 |
| Memory Peak Physical, kB | 108785 | 0.029% | 108765 / 108831 / 108815 / 108765 / 108749 |
| CPU Instructions Retired, kI | 0.000 | — | 模拟器上该计数器不可用 |
| CPU Cycles, kC | 0.000 | — | 模拟器上该计数器不可用 |

## 数据质量说明（重要）

1. **首采样是离群点**：本次 runner 是全新机器、现场下载 iOS runtime，导致第 1 次迭代明显偏高
   （冷启动 12.191 s、CPU Time 前两次 1.689/1.832 s）。**看稳态请看第 2～5 次**：
   冷启动约 3.9～4.6 s，CPU Time 约 0.98～1.06 s。
2. **RSD 偏高的指标**（冷启动 56.1%、CPU Time 27.9%）不适合做精确前后对比；
   滚动时长（1.8%）与内存（<0.1%）稳定，适合做批次 2 对照。
3. **CPU Instructions Retired / CPU Cycles 在模拟器上恒为 0**，不能作为对比指标；
   BUG-007 的 CPU 对比请用 **CPU Time**。

## 与 11-08 管道验证快照的关系

`docs/performance-baseline-20261108/`（run 42498401537，`f8d2c54`）是同设备同配置的**管道验证**数据，
与本基线可互相参考。两者差异主要来自采样噪声（首采样离群），不代表真实性能变化。

## 口径说明

- **Debug 路线写死**：App 的测试钩子（`BOJI_PREVIEW_ACCOUNT`、`BOJI_UI_TEST_SEED`）都在 `#if DEBUG` 内，
  Release 包驱不动登录态，UI 用例无法运行。为不改动账号链路，基线与批次 2 后测统一用 Debug。
- **设备写死 iPhone 16 Pro**：跨设备对比无效（10-24 旧基线是 iPhone SE 3 / iOS 26.5，仅作历史背景，不进对比表）。
- 10-24 旧基线在 `docs/native-ui-20261024/performance/`。
