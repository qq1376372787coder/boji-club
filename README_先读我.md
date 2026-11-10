# 当前交付：0.15.9 (Build 135)

请先阅读 [Build135 自然体验与 Club AI 联动](BUILD135_NATURAL_EXPERIENCE.md)。本目录保留旧版本文档和历史 manifest，仅供追溯；本次交付以 Build135 说明、测试证据和源码包 manifest 为准。

> 前序：0.15.6 (Build130) 说明见 [BUILD130_升级说明.md](BUILD130_升级说明.md)。
> 最新交付：0.15.1 / Build 113，见 docs/experience-upgrade-20261021/README.md。以下内容保留为历史材料。

> **2026-10-20 修复版入口**：见 [修复交付-20261020.md](修复交付-20261020.md)。本轮627项Python与51条Swift测试链通过；完整TestFlight模拟器及iOS设备无签名构建通过；浅深色UI各6条及训练完成专项1条通过。本轮未部署。下文为前序交付说明，生产状态须另行核对。

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
