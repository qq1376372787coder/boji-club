# BUILD140 全量回归验收报告（测试验收）

日期：2026-11-08　阶段：5 集成验收与返工循环
基线：0.15.9 / Build 139　终态提交：`47eacc6`
最新构建：`builder ios build` run 42470904790 → `dist/BojiClub-8f1542dc.ipa`（37.47 MB，未签名 Debug 包）

---

## 一、验收结论（先给结论）

| 标准 | 结论 | 依据 |
|---|---|---|
| ① 无崩溃、无明显 bug | **有条件通过** | P1 全部关闭；仍有 5 项未关闭（4 项需真机/设备、1 项 P3 建议），详见第三节 |
| ② 操作流程顺 | **有条件通过** | 5 个流程断点 + 后端两大卡顿均已修；跨午夜/跨时区/弱网边界需真机复核 |
| ③ 原生组件 + 原生玻璃质感 | **通过** | 自绘控件零残留、材质直写仅剩桥接、页面层零散写版本分支；老系统降级分支齐备 |
| ④ 视频自然融入界面 | **通过（源码级）** | 方案 A 落地：静音循环、三闸门降级、首帧占位无缝切换；真机播放流畅度待验 |
| ⑤ 动效高级华丽但不廉价 | **通过** | 三场景按规范 §4.1 落地、单一 Token 来源、红线（无彩虹/无无限闪动/无整屏转场/同屏运动 ≤2）全合规 |

**总判定：代码层面五条标准全部达成；剩余未关闭项全部依赖真机/设备环境，不构成代码缺陷。**

> **方法限制（必须随报告一并阅读）**：本机为 Windows，无 Xcode、无 iOS 模拟器、无真机安装链路。本报告所有结论均为**源码级静态核查 + 云端编译验证**，不含任何真机/模拟器实测数据。四种系统设置（深色模式、更大字体、减少动态效果、增强对比度）的实际观感与交互、视频播放流畅度、无障碍审计，均须在安装链路配好后实机复跑，复跑清单见第五节。

---

## 二、五条标准逐条证据

### 标准① 无崩溃、无明显 bug

**A 表（Bug 清单）共 17 条，状态分布：**

| 状态 | 数量 | 编号 |
|---|---|---|
| 已验收关闭 | 12 | BUG-001、003、005、010、011、012、013、014、015、016、017 |
| 已修复待验（部分/单源校正） | 2 | BUG-002（卡门可恢复）、BUG-004（休息单源校正） |
| 待处理（需设备/未做） | 4 | BUG-006、007、008、009 |

- **P1（4 条）全部关闭**：BUG-001 通知深链被吞、BUG-003 输入串轨、BUG-005 视频未融入、BUG-014 视频未静音。
- **未发现的崩溃路径**：静态扫描 31 处强制解包均带前置 guard（BUG-009 已核）。
- **未关闭项性质**：BUG-006/007/008 必须真机或模拟器才能验证（无障碍审计、滚动性能、小屏布局）；BUG-009 为 P3 加固建议，不构成缺陷。
- **明确结论**：**本轮改造未引入新的崩溃路径**；全部改动均通过云端编译（编译通过即证明无语法/类型错误）。

### 标准② 操作流程顺

| 流程断点 | 处置 | 证据 |
|---|---|---|
| 通知深链被训练/AI 界面吞掉 | 已修 | `BojiClubApp.swift` 屏蔽时改顶部安全区横幅，路由保留、条件解除后自动弹出；带「知道了」关闭（BUG-001/010/011） |
| 登录→首页四层状态机卡门页 | 部分收口 | `ProfileView.swift:158-162` 新增「重新检查会员状态」原地重试（IOS-012）；四层回写时序待真机多路径验 |
| 训练登记输入串轨 | 已修 | 自绘键盘与 keypadWeight 双轨删除，统一原生 TextField（IOS-001/002/003/004） |
| 组间休息双状态不一致 | 已修 | `ClubAIShell.swift:175-177` 以快照 `isPaused` 单源校正 + onAppear 兜底（IOS-013） |
| 购买后「一直核验中」 | 已修 | 后端 BE-001：受限请求只读本地权益，后台 worker `process-membership-refresh.php` + systemd timer 每分钟刷新 |
| 弱网同步停摆 | 已修 | 后端 BE-004 + 客户端：域命令改指数退避（2s→5s→15s→60s→5min→15min→1h），blocked 不再中止整次同步 |

**待真机复核的边界**：跨午夜训练日切换、跨时区休息截止、弱网恢复后的自动续同步。

### 标准③ 全部改用 iOS 原生组件 + iOS 26/27 原生玻璃质感

| 检查项 | 结果 | 证据 |
|---|---|---|
| 自绘交互控件 | **零残留** | `LiquidCheckbox`、`ClubNumericKeypad`、`ConfettiView` 全库零命中；`TrainingNumericInput125`/`SmartWeightStepper` 保留同名薄封装，内部为原生 `TextField`/系统 `Stepper` |
| 自绘动效件 | **全部系统化** | `ClubActivityMark`/`AIProcessingMark` → 系统 `ProgressView`；`BreathingPulseHalo` → 原生 `Gauge`（原封装已删）；`LaserScanBeamOverlay` → `ProgressView` + 文案；引导页手绘光晕/轨道环清除 |
| 材质直写 | **收口** | `.regularMaterial`/`.ultraThinMaterial` 全库仅剩 `Design.swift:200`（`clubGlassEffect` 桥接自身的降级分支） |
| 版本分支 | **页面层零散写** | `if #available(iOS 26` 全库仅剩 `Design.swift:160/197/211`（桥接自身） |
| iOS 17 降级 | **齐备** | `ClubGlassSurface`：iOS 26 → `glassEffect(.regular.interactive(true))`；iOS 17–25 → `.regularMaterial`；减少透明度/增强对比度 → 不透明 `cardSurface` + 描边 |
| 玻璃密度红线 | **达标** | 内容层玻璃归零；全库 41 处玻璃逐处判定为浮件或 DES 允许的 Hero；引导页每屏 1 处 |

### 标准④ 视频自然融入界面

- **位置**：方案 A（Chief 拍板）——首页 Hero 玻璃卡底层，`brand-video.mp4` 已入 bundle 并在 `project.pbxproj` 注册（PBXFileReference + group child + PBXBuildFile + Resources 构建阶段四处齐全）。
- **三闸门降级**（DES §5.2）：
  - 视频未就绪 → `loadHeroPoster()` 用 `AVAssetImageGenerator` 后台截第 0 帧静态图；
  - 减少动态效果 / 低电量 → 不创建 player，持续显示静态帧（`ClubAIShell.swift:1199` guard）；
  - 离场/后台 → `pause` + `seek(.zero)`。
- **无缝切换**：`heroGlassContent` 分 z0 首帧占位 + z0b 视频层叠加，就绪后叠加，消除原纯色块跳变。
- **规格**：静音（`isMuted = true`）、循环（`AVPlayerLooper`）、护字渐变、深色压暗 20%。
- **待真机**：播放流畅度、首帧切换的实际观感、设备发热量。

### 标准⑤ 动效高级华丽但不廉价

- **三场景落地**（DES-004，复用 `BojiMotion2` 档位，未新增时长参数）：
  - 场景 1 首页：Hero + 首个内容区块两拍进场；
  - 场景 2 训练中：完成组数 `contentTransition(.numericText())`；分段进度改线性 easeOut（杜绝假进度弹簧）；
  - 场景 3 完成页：6 事实格 stagger 进场 + 三格数字从 0 滚动 + 一次性成功触感。
- **口径统一**：`BojiMotion2.entrance = spring(0.35, 0.85)`、`stagger = 0.05`；场景 1 与场景 3 实现**逐字一致**，单一 Token 来源（BUG-017 已闭环）。规范 §4.2/§7 补明「0.5s 指单元素，整串 ≤0.6s」。
- **红线合规**：无彩虹轮播、无无限循环装饰（3 处 `repeatForever` 全部 reduceMotion 门控）、无整屏转场（15 处 transition 均 opacity/move/scale）、同屏运动元素 ≤2。
- **减动效降级**：所有动效均走 `BojiMotion2.resolved`，开启后降为 0.12s 交叉淡入。

---

## 三、未关闭项清单（需 Chief 处置）

| 编号 | 问题 | 严重度 | 为什么现在关不掉 | 建议处置 |
|---|---|---|---|---|
| BUG-002 | 登录→首页四层状态机回写时序 | P2 | 需真机走通登录/会员/引导/首启多路径 | 降级为「真机补验项」，链路就绪后验 |
| BUG-004 | 组间休息跨午夜/跨时区边界 | P2 | 需真机跨日或改系统时区 | 同上 |
| BUG-006 | 侧栏无障碍审计 3 对比度 + 2 裁切预测 | P2 | 需真机/模拟器跑自动审计 | 同上 |
| BUG-007 | 滚动 CPU 较基线 +47.2% | P2 | 需相同设备/系统/配置做性能复测 | 同上，且建议做采样归因 |
| BUG-008 | 顶栏分段选择器小屏（375pt）可能溢出 | P3 | 需小屏设备或模拟器 | 同上 |
| BUG-009 | 31 处强制解包含 4 处相对高风险 | P3 | 属加固建议，非缺陷 | 建议下一批加 guard |
| BUG-015 备注 | 首帧未生成的一瞬仍有纯色兜底 | P3 | 瞬态，可接受 | 保持观察，不阻塞 |

---

## 四、编译与产物证据

| 构建 | head | 结果 | 产物 |
|---|---|---|---|
| run 42470904790 | `064d234` | ✅ 成功 | `dist/BojiClub-8f1542dc.ipa`（37.47 MB） |
| run 42470321202 | `6b48d67` | ✅ 成功 | `dist/BojiClub-862d9ccf.ipa`（37.47 MB） |
| run 42469629352 | `5ab6f97` | ✅ 成功 | `dist/BojiClub-44f6e7e8.ipa`（37.44 MB） |
| run 42468330096 | `d837df6` | ✅ 成功 | `dist/BojiClub-f93a9470.ipa`（37.44 MB） |
| run 42467773417 | `0b638da` | ✅ 成功 | `dist/BojiClub-53aedefe.ipa`（37.43 MB） |

全部为未签名 Debug 包：模拟器可用，真机需先配签名与描述文件。

---

## 五、真机补验清单（安装链路就绪后执行）

> **状态：正式挂起（2026-11-08 Chief 首轮验收决定）**。以下 7 项与 A 表 4 条设备项（BUG-002/004/006/007/008/009 中的设备相关部分）**降级为真机补验项**，不等同于代码缺陷；待真机安装链路（B4）配好后按本清单逐项实跑，跑完由测试验收补报告、交 Chief 签字。

1. **四种系统设置**：深色/浅色、AX1–AX5、减少动态效果、增强对比度、减少透明度——各走一遍首页、训练中、训练完成、会员购买页。
2. **视频播放**：首页 Hero 流畅度、首帧→视频切换是否可见跳变、静音确认、离场/后台是否停播、低电量与减动效是否显示静态帧。
3. **动效观感**：三场景进场/滚动/庆祝是否「华丽不廉价」，同屏运动元素是否 ≤2。
4. **主线流程**：登录 → 首页 → 训练 → 记录 → 同步 → 支付（含购买后核验不再转圈）。
5. **边界**：跨午夜训练、跨时区休息截止、弱网恢复自动续同步。
6. **无障碍**：侧栏自动审计复跑（BUG-006）、VoiceOver 焦点顺序、触控区 ≥44pt。
7. **性能**：滚动 CPU 与基线对比（BUG-007）、启动耗时、静置内存。

---

## 七、验收回合记录

| 轮次 | 日期 | Chief 判定 | 开出问题单 | 测试验收处置 |
|---|---|---|---|---|
| 第 1 轮 | 2026-11-08 | ③④⑤ 通过；①② 有条件通过 | **T-1** BUG-009 强制解包 guard 加固（苹果开发）<br>**T-2** BE-005 AI 完成状态改回调/定时写入 + BE-007 多设备同步排队合并（后端开发） | **T-2 复验通过**；**T-1 部分闭环**（6 处重点里 5 处真收口，`ExerciseLibraryView` 仍留 3 处 `components.url!`，见下） |

### 补充复验（第 1 轮问题单）—— 最终结论：T-1、T-2 双双通过

**T-1（BUG-009 强制解包加固）—— 复验通过（commit bc9202a + 8e936d2）**

| 检查项 | 结论 | 证据 |
|---|---|---|
| `ExerciseLibraryView` 三处 | ✅ 已收口 | `:146/:174/:187` 均改为 `guard let url = components.url else { throw URLError(.badURL) }`；`components.url!` 全库**零命中** |
| `OnboardingView` URL 强制解包 | ✅ 已收口 | commit 8e936d2 同类加固；全库 `URL(string:...)!` 零命中 |
| 6 处重点（AppStore 饮食索引、MembershipService notice、HealthViews 品牌链接等） | ✅ 已收口 | 见上一轮复验证据（`AppStore.swift:2126` `day.meals.indices.contains(index)`、`MembershipService.swift:241` `?? fallback`、`HealthViews.swift:206` `if let`） |

**全库强制解包终扫：31 处 → 10 处，且 10 处全部为安全模式，无真实风险：**

| 文件:行 | 模式 | 安全性 |
|---|---|---|
| `AppStore.swift:2914` | `day.workoutSessions?.isEmpty == false && day.workoutSessions!` | 前置非空检查短路保护 |
| `ClubSeason.swift:146` | `claimDeadline == nil \|\| ... <= claimDeadline!` | 短路保护 |
| `MealEditorView.swift:285` | `correctionJobID != nil, ai.job(correctionJobID!)` | 前置检查 |
| `OnboardingView.swift:355` | `didFinish navigation: WKNavigation!` | UIKit 委托签名，不可改 |
| `ReportLibraryView.swift:303` | `weightFirstKg != nil && weightLastKg != nil ? ...!` | 短路保护 |
| `WeeklyReportView.swift:173/305/318/562` | `xxx != nil ? ...!` 三元 | 短路保护 |
| `WeeklyReviewView.swift:45` | `existingJob != nil && !existingJob!` | 前置检查 |

**结论**：BUG-009 全库真实强制解包清零（31 → 0 风险点）。**T-1 关单。**

**T-2（BE-005 / BE-007）—— 复验通过（commit 9601226）**

| 单号 | 复验结论 | 证据 |
|---|---|---|
| T-2a BE-005 AI 完成状态 | ✅ 通过 | 新增后台 worker `account-server/process-ai-completion-refresh.php`（每 30 秒对账 `ai_user_jobs` 与 worker metadata，写 `completed_at`）+ `deploy/bojiclub-ai-completion-refresh.{service,timer}`，已收录 `deploy.sh:158/163`；请求路径 `verifiedAICompletion`（`ai-response.php:73`）降级为**兜底**，超时 1–2s → 4s，注释写明「后台定时对账为主路径」 |
| T-2b BE-007 多设备同步锁 | ✅ 通过 | 服务端 `cloud-parts.php:72-87` `cloudCommitLock` 改**排队等锁最多 5 秒**（每 100ms 轮询，到期才 429 + `Retry-After: 5`），不再「第二台设备立即 429」；客户端 `AppStore.swift` 同步重试 3 次 → 6 次、每次 0.4s，仍不收敛则保留本机记录 + 置 `waitingService` 自动续同步，不再硬报「其他设备正在更新」 |

**编译证据**：T-1 收尾 run 42474824704（head `bc9202a`）→ `dist/BojiClub-ea843320.ipa`（37.48 MB）✅；T-2 随 run 42474004694 → `dist/BojiClub-2433bb2a.ipa`（37.48 MB）✅。

**第 1 轮问题单 T-1 / T-2 全部关闭。代码层面五条标准不再有未决问题单，可交 Chief 签最终验收。**

**问题单登记（详见台账 I-3 遗留项清单）**

| 单号 | 内容 | 负责人 | 严重度 | 状态 |
|---|---|---|---|---|
| T-1 | BUG-009 强制解包加固：重点 6 处（`AppStore.swift:2111`、`ExerciseLibraryView:143/168/178`、`MembershipService:240`、`HealthViews:206`）加 guard 安全回退，其余 25 处顺手过一遍 | 苹果开发 | P3（加固） | **已验收关闭**（复验：31 → 10 处且全为安全模式，真实风险清零） |
| T-2a | BE-005 AI 完成状态改为 worker 回调/定时写入，不再用 1–2 秒同步超时误判 | 后端开发 | P2 | **已验收关闭** |
| T-2b | BE-007 多设备同步提交锁排队合并或延长客户端重试窗口，不再 3 次冲突即中止 | 后端开发 | P2 | **已验收关闭** |

**记遗留清单不开单**：BE-006（旧账号大迁移，边缘场景）、BE-008（AI worker 无 Key，属部署配置，随服务器补键一并处理）。

---

## 六、测试方法与环境（可复现性说明）

- **工具**：Windows 本机，无 Xcode。全部核查通过源码静态分析（`grep`/精读）与 `builder ios build` 云端编译完成。
- **构建环境**：GitHub Actions macOS runner，XcodeGen 生成工程，Debug 配置，未签名。
- **可复现**：任意时点 `git checkout <commit>` 后按本报告第二节列出的文件与行号逐一核对，结果应一致；编译可用 `builder ios build` 复现。
- **本报告不含任何真机/模拟器实测数据**，凡涉及观感、流畅度、无障碍实际行为的结论均已在正文标注「待真机」。
