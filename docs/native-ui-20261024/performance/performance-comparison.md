# 原生 UI 前后性能测量

2026-10-24，Small / iPhone SE 3 / iOS 26.5 模拟器，Debug arm64。基线为上一轮修复版，当前版为本轮原生 UI。相同测试方法、相同预览种子、关闭引导，各测 5 次。先基线后当前连续执行，期间没有其他构建或 UI 操作；两版均 2/2 用例通过。

测试方法 SHA-256：`edba010db20f52158aafe3ebf2349d36801426a5bb31aaddc43202c7fdc0954b`。基线 96 个 App 文件与修复包清单一致。活动轨迹确认基线使用旧的自绘训练按钮，当前使用原生 segmented picker；两者均操作实际可见的训练滚动容器。

| 指标 | 基线均值 | 当前均值 | 单位 | 变化 |
|---|---:|---:|---|---:|
| Duration (AppLaunch) | 1.479317 | 1.324079 | s | -10.5% |
| Duration (Scroll_DraggingAndDeceleration) | 0.993894 | 0.946974 | s | -4.7% |
| CPU Instructions Retired (dev) | 1484009.374000 | 2048037.541800 | kI | +38.0% |
| Clock Monotonic Time | 2.517792 | 2.458870 | s | -2.3% |
| CPU Time (dev) | 0.304033 | 0.447587 | s | +47.2% |
| CPU Cycles (dev) | 891369.053800 | 1187977.077000 | kC | +33.3% |
| Absolute Memory Physical (dev) | 85877.545600 | 86447.708800 | kB | +0.7% |
| Memory Physical (dev) | -6.553600 | 268.697600 | kB | 不解释接近零基线的百分比 |
| Memory Peak Physical (dev) | 86044.662400 | 86503.414400 | kB | +0.5% |

12 秒静置 RSS（独立 ps 测量、两次）：基线 [326.41, 335.05] MiB，当前 [318.97, 311.31] MiB；均值 330.73 → 315.14 MiB（-4.7%）。不能把 RSS 与上表 XCTest 物理内存当作同一指标比较。

启动均值降低 10.5%，静置 RSS 均值降低 4.7%，滚动手势及等待的总时间降低 2.3%。同时，应用 CPU 时间从 0.304 增至 0.448 秒（+47.2%，每次上下滑合计增加约 144ms），退休指令增加 38.0%。CPU 时间存在回归，测量结果不支持“性能全部改善”的结论。本次未做采样分析，不能把增量直接归因给某个组件。

两份 xcresult 的全部指标中均无 hitch 数、hitch 比例、帧率或掉帧数，均记为未提供。`Scroll_DraggingAndDeceleration` 是持续时间，不代表滚动掉帧通过。真实设备 Release 的动画卡顿与能耗仍需另行测量。

初次基线尝试因 `.scrollViews.firstMatch` 命中 x=-100000 的非活动 AI 容器而失败，保留在 `baseline-performance-initial-invalid-scroll.xcresult/.log`，不纳入对比。修正后的同一方法先筛选可见且可点击的滚动视图，再开始测量。初次启动 RSD14.1%；本表使用修正连续运行的启动 RSD：基线7.0%、当前1.6%。

原始结果与导出：`baseline-performance.xcresult`、`current-performance.xcresult`，各自 `*-metrics.json`、`*-tests.json`、`*-summary.json`、`*-scroll-activities.json` 与日志。机器可读汇总在 `performance-comparison.json`。可移植证据包含本文、JSON 与日志；原始 xcresult 单独保留。样本较少，不声称统计显著或真机结果。测量用例执行成功不等同于全部性能验收通过。
