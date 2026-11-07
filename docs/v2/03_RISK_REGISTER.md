# BOJI CLUB V2.0 · Phase 0 审计报告 03：风险登记册（RISK REGISTER）

- 评级：P0=发布阻断 / P1=高 / P2=中 / P3=低。每条含证据与缓解建议。
- 状态：OPEN（未处理）/ MITIGATED（已有缓解）/ ACCEPTED（接受）。

---

## A. 工程与流程风险

| ID | 等级 | 风险 | 证据 | 状态 | 缓解建议 |
|---|---|---|---|---|---|
| R-01 | **P0** | **无版本控制**：交付为 zip、无 .git，回滚与变更审计完全依赖人工归档 | 工作目录无 .git；根目录 ~180 个手写修复 md | OPEN | Phase 1 前置条件：`git init` + 全量首提交 + tag `v0.15.1-b114`；建立分支模型（main/develop/feature） |
| R-02 | ~~P0~~ **基本解决**（2026-10-24） | **CI 入口就绪**：`scripts/run-all-checks.sh`（五步全量，本地实测通过）+ `.github/workflows/ci.yml`。**遗留**：仓库无远端托管，workflow 待接入后生效；PHP 套件未含 | 提交 8a06c38 | PARTIAL | 接入远端托管即生效；PHP 套件 runner 配置后补 |
| R-03 | P1 | **无功能开关体系**：`feature.ai_native_home` 等回退开关不存在；现有远程配置 ai_enabled/club_enabled 客户端不消费 | `AccountService.swift:142-166` 解码后无读取点（历史问题⑩） | OPEN | Phase 1 交付客户端 FlagService（远程 app_config 驱动+本地覆盖+默认回退旧首页），补齐消费链 |
| R-04 | ~~P1~~ **部分解决**（2026-10-24，提交 8a06c38） | 测试基建：**已新增项目首个单元测试 Target**（BojiClubTests，6 项 FeatureFlagService 单测）；CI 统一入口 `scripts/run-all-checks.sh` 五步全量实测 ALL CHECKS PASSED；Swift 链 52/52。**遗留**：PHP 套件未纳入（需 php+MySQL runner，见 R-40）；真机测试仍缺 | `docs/v2/evidence/phase1/README.md` 批 2 | PARTIAL→OPEN | PHP docker 化后更新 CI；真机项随签名证书解决 |
| R-05 | P2 | 无灰度发布设施（分桶/TestFlight 分组数据回收） | 无灰度代码/文档 | OPEN | TestFlight 外部测试分组起步；app_config 增加 build 白名单字段（向后兼容默认全量） |
| R-06 | P2 | 文档即真相：~180 个过程文档与代码可能漂移（文档声称的"已验收"未复核） | `修复交付-20261020.md` 等均为自述 | ACCEPTED | 本审计已对关键声明做代码核对（02 号报告 §17/§22）；后续以代码+测试为准 |

## B. 数据与一致性风险

| ID | 等级 | 风险 | 证据 | 状态 | 缓解建议 |
|---|---|---|---|---|---|
| R-07 | **P0**（对 V2 数据层） | **单 JSON 文档与 V2 领域表冲突**：app_states ≤16MB 文档+cloud_parts 分片是训练/饮食/身体唯一云存储；直接引入领域表会产生双权威 | `schema.sql:123-129`、`sync-schema-v59.sql`、`Models.swift:401-426` | OPEN | 04 号报告数据迁移策略：领域表只作服务端读投影（expand→dual-read→reconcile），写入仍走文档+命令通道；cutover 前不 contract |
| R-08 | P1 | **Outbox 消费者为空实现**：domain_outbox 事件全部直接标记成功，跨模块联动（提醒/洞察失效/投影）实际不存在 | `process-domain-outbox.php:47-56` | OPEN | Phase 3 实现 ScheduleMoved→洞察失效+提醒重排 两个真实消费者后再扩展 |
| R-09 | P1 | 三方 JSON 合并的隐性数据丢失面：通用合并器+墓碑并集在复杂并发（双端同日多练编辑）依赖专项规则（R01 互斥替换） | `CloudSync.swift:107-311`、`cloud-validation.php:442-675` 多个 preserve/reconcile 函数 | MITIGATED(部分) | 保持既有 preserve 规则；新增卡片/提案数据进文档前必须先加 cloudSchemas 校验+合并测试 |
| R-10 | P1 | 分区账号命令通道拒绝：_partitioned=2 账号（大状态用户）不能走 /me/commands，V2 AI 写入路径会对其失效 | `commands.php:80-83` | OPEN | V2 Action Orchestrator 设计时必须覆盖分区账号（改用 /me/state 或分区感知命令） |
| R-11 | P2 | 报告/周报与源数据 revision 链存在但客户端旧报告缓存刷新策略未见强制 | backend `report_archive.source_revision`（`automation_core.py:11-17`） | UNVERIFIED | Phase 2 契约测试：源 revision 变化后旧卡必须标 stale |
| R-12 | P2 | 无数据备份**恢复演练**执行证据；备份工具完备（backup.py AES-256-GCM 全量含 MySQL/SQLite/.p8/配置，restore.py+演练流程文档，14 份保留+异地选项） | `account-server/deploy/backup.py`、`BACKUP-RECOVERY.md`；`11_TESTFLIGHT_READINESS.md` 未列演练完成 | OPEN(演练 UNVERIFIED) | 上线前执行一次 `restore.py --apply --target` 空目录演练并归档结果 |

## C. 已知历史问题回归风险（V2 17.2 强制回归清单）

| ID | 等级 | 问题 | 现状（02 号报告 §17 详证） | 缓解建议 |
|---|---|---|---|---|
| R-13 | **P0** | 首页中断其他 App 音频 | **机制仍在**：静音 hero 视频激活默认会话（`HomeWorkoutVideo.swift:5-27`） | Phase 1 首项修复：视频播放前 `AVAudioSession` 设 `.ambient`+`.mixWithOthers`（或直接移除视频改静态图）；回归测试=冷启首页+后台音乐不中断（真机） |
| R-14 | P1 | AI 提醒关闭后复现 | 胶囊 dismissedID 不持久化（`DesignTokens.swift:943`）；进行中不可关（`:1003`） | 新 Shell 重做胶囊状态（持久化 per-day dismiss + 进行中仅完成/取消可消）；列入 Phase 1 验收 |
| R-15 | P1 | 后台配置不生效 | 客户端不消费 ai/club 开关 | 与 R-03 一并修复：FlagService 消费闭环+配置版本遥测 |
| R-16 | P2 | 识别后滚动卡顿/动画卡顿 | 风险点定位（`MealEditorView.swift:94-109`），无实测 | Phase 1 建立性能基线（Instruments/ MetricKit）后复测；卡片化改造时避免同 ScrollView 动画插卡 |
| R-17 | P2 | 图表难懂 | 首页趋势图无 x 轴（`HealthOverview.swift:175-180`） | V2 卡片设计统一图表规范（轴标签/空态/单点态）；Phase 1 Design Token 附图表样式 |
| R-18 | P2 | 页面过长 | 首页 5+ 卡堆叠、NutritionView 长滚动 | V2 留白式工作台直接解决；旧首页作为回退不投入 |
| R-19 | P3 | 组间休息按钮 | 已修复（跨页存活+钳制）；残留 owner-0 写入小瑕疵（`WorkoutView.swift:446`） | 顺手清理；训练中心改造时保持 ClubRestStorage 语义不变 |
| R-20 | P3 | 身体面板只显示体重 | 已修复（7 指标可配） | 回归项保留 |

## D. 安全与隐私风险

| ID | 等级 | 风险 | 证据 | 状态 | 缓解建议 |
|---|---|---|---|---|---|
| R-21 | P1 | **网络面配置不齐**：客户端基址为裸 IP `https://117.50.119.49`（证书有效性未知）；Release 预定域名 `api.gongxiang.cloud` **NXDOMAIN**（2026-10-20/21 记录）；`dongzuo` 媒体 nginx 配置文件仅见 80 端口（客户端却用 https） | `AccountService.swift:181-197`、`11_TESTFLIGHT_READINESS.md:49-53`、`dongzuo.nginx` | UNVERIFIED | 正式发布前：域名解析落地或确认 IP 证书有效；dongzuo 补 TLS 块核实 |
| R-21b | P1 | **部署期间服务器 root 密码曾被共享**（交付包自述），未轮换 | `PACKAGE-README.txt` 安全备注（2026-10-21） | OPEN | 立即轮换 root 密码 + 审计近期登录；改用密钥登录 |
| R-22 | P1 | 无 BOLA/IDOR 越权自动化测试 | 代码普遍按 user_id 过滤（`index.php:803-806` 等）但无测试面 | OPEN | Phase 1/2 各加一组越权契约测试（跨用户 media/job/claim/proposal） |
| R-23 | P2 | 管理 API 面暴露度：admin AI 代理 9 个端点仅靠同一 APP_TOKEN+admin 会话；admin-session 强度未审 | `admin/bootstrap.php:126-140` | UNVERIFIED | 渗透式复核：登录限速/会话固定/CSRF/角色越权 |
| R-24 | P2 | 健康数据出境面：照片/健康摘要发第三方 LLM（功能必需，已有同意域+fail-closed） | `ai_core.py:1276-1287` | MITIGATED | 保持 fail-closed 原则：新增供应商必须显式加入同意域；隐私政策随 V2 更新披露 |
| R-25 | P2 | 敏感日志无审计流程：健康数据日志脱敏靠约定（PHP 只记异常类名；Python 关闭访问日志） | `index.php:930-935`、`server.py:972-973` | MITIGATED | V2 新增任何日志点需过隐私审查清单（04 号报告附） |
| R-26 | P3 | exercise-server 无鉴权（公开只读设计声明） | `exercise-server/api.py` | ACCEPTED | 保持只读+限流；禁止未来加写接口而不加鉴权 |
| R-27 | P3 | 单共享 APP_TOKEN：持 token 者可调全部内部端点（含 admin AI 设置） | `server.py:952-953` | MITIGATED(内网绑定) | 可选：拆 admin 专用 token；token 轮换流程文档化 |

## E. 发布与合规风险

| ID | 等级 | 风险 | 证据 | 状态 | 缓解建议 |
|---|---|---|---|---|---|
| R-28 | P1 | 远程推送 entitlement 缺失+默认编译关闭：V2 主动洞察的推送依赖未打通 | `BojiClub.entitlements`（无 push）；`ClubRemotePush.swift:7` | OPEN | 产品决策：若 V2 需推送，补 entitlement+APNs 环境（服务端 APNs 栈已全备 `club-push.php`）+ 开启编译开关的构建验证 |
| R-29 | P1 | TestFlight 准入**正式判定不通过**：`check-release-ready.py` → `ready:false`，4 项阻断：①APNs entitlement 缺失；②api.gongxiang.cloud NXDOMAIN；③`.dev` 后缀 Bundle ID 未确认可上架；④法律文档全部为草案（PRIVACY-POLICY v0.6 无公开 URL、LegalReviewed=false） | `scripts/check-release-ready.py`、`docs/audits/boji-v2-quality/11_TESTFLIGHT_READINESS.md:9-19,49-66,95` | OPEN | Phase 1 期间逐项解除；法务文本定稿+托管为上架前置 |
| R-29b | P2 | 服务器包内配置与实际主机漂移：nginx conf/deploy.sh 按 php8.2-fpm/Debian 写，实际 Rocky Linux 10.1/PHP 8.3.33（部署走选择式文件同步而非 deploy.sh） | `13_DEPLOYMENT_20261021.md:9` vs `bojiclub-account-location.conf` | OPEN | 配置文件随实际主机修订；部署流程文档化（已有 deploy-experience-sync.sh 为准） |
| R-30 | P2 | RevenueCat 商品矩阵漂移：客户端 Info.plist（yuefu/nianfu/yongjiu）与服务端默认（bojiclub_halfyear_2990/yearly_4290）不一致，靠兼容列表兜底 | `Info.plist:9-18` vs `revenuecat.php:30` | OPEN | 单一来源化商品配置（服务端 app_config 下发或构建注入），对照 SUBSCRIPTION-LOCALIZATIONS 复核 |
| R-31 | P2 | 无指标/埋点：V2 第 21 章对照验证无法执行 | 无 Analytics 依赖 | OPEN | Phase 1 决定最小埋点方案（自研事件经现有 /me 通道或第三方），先只埋 V2 验收所需 6-8 个事件 |
| R-32 | P3 | 法律文档（隐私政策/用户协议）版本随 V2 功能（记忆/洞察/推送）需更新 | legal/ 目录存在 | OPEN | Phase 4 记忆功能上线前完成法务复核 |

## F. V2 实施特有风险（前瞻）

| ID | 等级 | 风险 | 缓解建议 |
|---|---|---|---|
| R-33 | P1 | 双模式 Shell 改造触碰全部入口（TabView→RootHeader+模式容器），回归面大 | Feature Flag 全局开关（默认旧 TabView）；新旧并行一个版本周期；UI 测试先行补齐 5 Tab 壳回归 |
| R-34 | P1 | god-store（AppStore 2,814 行）直接承载对话流+卡片状态会进一步膨胀 | V2 新增 ClubAIFlowState 独立 ObservableObject，只经 AppStore 读写 SavedState；不改既有域接口 |
| R-35 | P1 | 卡片协议先行但服务端 Card Composer 缺位时，容易退化为"客户端解析模型文本" | 契约先行：02 报告建议 Phase 2 第一个交付就是 card schema JSON Schema+双方契约测试，无服务端校验不接 UI |
| R-36 | P2 | iOS 17.0 部署目标与 UI 规范的"Liquid Glass"期望不符 | UI 规范已注明按部署目标适配；用系统材质（.regularMaterial）+现有 Token 实现玻璃层；不升部署目标除非产品明确放弃老设备 |
| R-37 | P2 | 记忆功能的数据最小化与删除级联复杂（用户删记忆→洞察/推送策略同步失效） | Phase 4 设计评审前不写代码；复用 account-deletions 的队列模式做记忆删除 |
| R-38 | P2 | AI 成本：对话式首页将大幅提高调用量（现状配额按日按账号，已有限流） | Phase 2 上线前在 ai_user_usage 基础上加对话维度配额+每日成本看板（后台 AI 服务中心已有雏形） |
| R-39 | P2 | tests/php/ 子目录 4 个测试（plan_lifecycle/media_store_atomic/cloud_dictionary_types 等）不在 run_php_suite.sh 的 glob（仅 `tests/test_*.php`）内，存在静默漏跑 | `tests/run_php_suite.sh:36-58` glob 范围 | 修 runner 纳入子目录或移动文件 |
| R-40 | P2 | 签名 Archive/TestFlight 上传从未在本仓执行（Build 113/114 止步于模拟器+无签名真机构建）；RevenueCat 续费/退款沙盒场景未验收 | `README.md` 未验证清单；`PACKAGE-README.txt` | Phase 1 末完成一次完整 Archive→TestFlight 内部上传闭环 |
| R-41 | ~~P1~~ **已解决**（2026-10-24，提交 187a5c2） | Swift 规则回归链过期（29/52）：7 处 harness 侧修复（过期桩/断言文案/macOS 26 临时目录 completeFileProtection EPERM 归一/缺符号补提取），**现状 52/52 全绿**；生产代码零改动 | `docs/v2/evidence/phase1/README.md` 批 2、`tests/build_*.py` | RESOLVED | 纳入 CI（scripts/run-all-checks.sh 第 2 步）防再过期 |
| R-42 | P3 | iOS 26 模拟器无障碍审计在"active workout + 放大动态字体"测量态下对 4 个既有组件（Composer 计数器/洞察卡详情/快捷问题 chip/mini 条计时器）报对比度失败；同一元素在标准字号审计（testV2WorkspaceAccessibilityAudit 通过）与截图人工核对中均达标。审计会按辅助字号整屏重渲染测量（录像证据 docs/v2/evidence/phase2），放大态下固定高度容器与文字层叠导致测量失真 | `BojiClubUITests.swift` testV2ActiveWorkoutAccessibilityAudit（R-42 按 label 放行+打印）、`BojiClub/TrainingRegistrationViews.swift`（计时器 fixedSize 防折行已修） | OPEN（文档化放行） | polish 批次：辅助字号下重排 mini 条/计数器/chip 容器（内容自适应高度），复测后关闭 |

---

## G. 风险总览统计

P0：4（R-01 无版本控制、R-02 无 CI、R-07 数据模型冲突、R-13 音频中断未修复）
P1：16（含 R-21b root 密码轮换、R-29b 配置漂移、**R-41 Swift 回归链过期**）；P2：18；P3：5；UNVERIFIED 待生产/真机确认：8 项

**Phase 1 准入门槛（建议）**：R-01、R-02、R-03（Flag 基建）+ R-13（音频修复）+ **R-21b（root 密码轮换，立即执行）**+ **R-41（Swift 回归链修复或冻结声明）**必须先行完成；R-07 需在 Phase 2 设计评审中形成书面决策；R-29 四项 TestFlight 阻断应在 Phase 1 期间并行解除。
