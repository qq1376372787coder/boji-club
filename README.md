# 当前交付：0.15.9 (Build136)

请先阅读 [Build135 自然体验与 Club AI 联动](BUILD135_NATURAL_EXPERIENCE.md)。本目录保留旧版本文档和历史 manifest，仅供追溯；Build136 在 Build135 基础上修复跨库 schema 引导、AI 同意表缺失、卡片过期时间与照片识别崩溃。本次交付以本文、CI 证据和源码包 manifest 为准。

> 前序：0.15.6 (Build130) 见 [BUILD130_升级说明.md](BUILD130_升级说明.md)。

# Build 117 / 2026-10-25 最终修复交付

本包为0.15.1 (117)。本次修复与部署说明见 `docs/final-build117/`；先前README与历史报告保留在下文，仅供历史参考。后端已部署，iOS需重新构建安装。源码包不含服务器凭证和用户媒体。

---

# 当前交付：AI Action System 修复与补齐 — Build 116（2026-10-25）

工程为 **0.15.1 / Build 116**。先读 [本轮修复与验证说明](ACTION_SYSTEM_REPAIR_BUILD116.md)：包含 AS-01～AS-32 对照、训练/计划/饮食/测量/同步补齐、迁移与回退步骤，以及真实服务和真机尚需验收的边界。AI 主界面及原生液态玻璃升级保留，旧首页不恢复。本次仅交付代码，未部署、未上传 TestFlight、未录制视频。

本包完整清单为 `ACTION-SYSTEM-BUILD116-MANIFEST.json`。下面的 Build 115 与更早说明、测试数字及 manifest 均为历史材料，不代表本轮重新执行或生产验收结论。

---

# 当前交付：AI 主界面与原生液态玻璃 UI（2026-10-25）

请先阅读 [本轮 UI 升级说明与验收记录](UI_NATIVE_GLASS_20261024.md)。工程当前为 **0.15.1 / Build 115**：AI 主界面是唯一入口，保留顶部 Club AI / 训练双工作区，旧首页与五 Tab 已删除；退休首页开关不再切换新客户端界面。系统分段选择、统一 Composer、原生侧栏/弹层与 iPad 双栏已接入；iOS 26+ 使用原生 Liquid Glass，最低 iOS 17 保持同一 UI 的材质兼容。

本轮保留上一轮 V2 业务修复，新增分享与首份计划的独立组件。47 条 XCTest、666 条 Python 与 52 组 Swift 规则回归通过，最新小屏/手机/iPad 布局专项通过。默认侧栏自动无障碍审计与滚动 CPU 回归仍未关闭，不能称整套验收通过；按用户要求停止追加检测和视频制作。生产未部署、未上传 TestFlight，详细范围见新说明的验证表。**以下为历史材料，其中旧首页回退、旧构建号和历史“已完成/已部署”不适用于本轮。**

---

最新修复交付：V2 源码复核修复（2026-10-24），请先阅读 [修复说明](REPAIR_V2_20261024.md)。本次为代码交付，未部署生产。以下保留历史材料。

最新交付：0.15.1 / Build 113，见 docs/experience-upgrade-20261021/README.md。以下内容保留为历史材料。

> 2026-10-20 页面构图改造：请先阅读 [COMPOSITION-README.md](COMPOSITION-README.md) 和相邻 DesignReview 的验证记录。以下内容保留原项目背景，历史“已完成”声明不代表本轮实际验收范围。

> **2026-10-20 修复版入口**：见 [修复交付-20261020.md](修复交付-20261020.md)。本轮627项Python与51条Swift测试链通过；完整TestFlight模拟器及iOS设备无签名构建通过；浅深色UI各6条及训练完成专项1条通过。本轮未部署。下文为前序交付说明，生产状态须另行核对。

> 2026-10-19 产品数据口径修复：请先阅读 [本轮修复说明](PRODUCT-CONSISTENCY-FIX-20261019.md) 和 [数据口径约定](PRODUCT-DATA-CONTRACT.md)。历史部署状态不代表本轮客户端修复已发布。

# 薄肌俱乐部 0.15.0 · Build 112

2026-10-18。开发基线：`BojiClub-0.15.0-build112-server-deployed-20261018.zip`（SHA256 `62942d3d…c062f`，704 文件）。本目录保留另一 Agent 已部署的健康输入、报告版本链、自动化与推送管理改动，并在其上继续 FIX-001–022 与 D/E/F 体验升级。

请打开**本目录**的 `BojiClub.xcodeproj`，使用 `BojiClub-TestFlight` Scheme；工程三个 target 的 `CURRENT_PROJECT_VERSION` 均为 112，`MARKETING_VERSION` 均为 0.15.0。

## 本轮验证边界

- `tests/run_offline.py`：Python 后端离线回归（合成数据/临时 SQLite）。
- Xcode 26.6 / iOS 26.5 模拟器：`xcodebuild` 构建与可运行的 UI 截图/规则验证。
- 隔离 PHP 8.3 + MySQL 8.4：媒体替换故障注入、迁移与调度查询回归（测试库 `bojiclub_test`，不使用生产数据）。
- **未执行**：真实 Apple 登录/撤销、StoreKit Sandbox 购买、真机 HealthKit/APNs/锁屏、正式签名与 TestFlight 上传。这些仍为外部待验，不以模拟器或 Mock 代替。
- 未连接生产服务器，未执行部署或数据库迁移；发布包与回滚方案见 `deliverables/`。

历史 Build 106/107 文档保留为历史证据，不代表当前版本已通过。私有服务端配置、用户数据库与 Apple 私钥不包含在包内。

详细整改与 D/E/F 验收见本目录 `deliverables/README.md`（交付时生成）。
