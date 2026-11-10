# Requirement Completion Matrix — 00–06 / T01–T60

口径：本轮独立执行后的真实状态。`VERIFIED` 仅限列出的实际范围；`PARTIALLY VERIFIED` 不等于端到端通过；`UNKNOWN` 不推定通过。

| ID | 状态 | 本轮证据/边界 |
|---|---|---|
| T01 今天练什么 | PARTIALLY VERIFIED | 原领域/路由测试；未真实模型端到端 |
| T02 原生入口开始训练 | PARTIALLY VERIFIED | 原 UI/领域路径；5 UI 回归通过，未真机 |
| T03 连说三次开始 | PARTIALLY VERIFIED | 原 PHP 并发/幂等套件（52/56 通过） |
| T04 两设备同时开始 | PARTIALLY VERIFIED | 原并发测试；未双设备真机 |
| T05 离线记录 4 组 | PARTIALLY VERIFIED | 原离线队列测试；未真机强杀 |
| T06 离线重复组防重 | PARTIALLY VERIFIED | 原 `client_op_id` 测试 |
| T07 中途退出再进入 | PARTIALLY VERIFIED | `ClubCoachSessionTests`；未真机 |
| T08 结束训练未处理组 | PARTIALLY VERIFIED | 原 PHP 命令套件 |
| T09 结束训练超时 | PARTIALLY VERIFIED | 原命令状态测试 |
| T10 周四→周六 | PARTIALLY VERIFIED | 原日历并发正例 + 提案指纹；未全设备 E2E |
| T11 周六已有安排 | PARTIALLY VERIFIED | 原冲突测试 |
| T12 单次/长期换动作 | PARTIALLY VERIFIED | 原领域/提案测试 |
| T13 提案过期 | PARTIALLY VERIFIED | 原 PHP 过期测试 |
| T14 双设备确认 | PARTIALLY VERIFIED | 原并发/幂等测试 |
| T15 预览后手动改排程 | PARTIALLY VERIFIED | `_expected_days` + revision 指纹；未真机 |
| T16 Outbox 前失败回滚 | PARTIALLY VERIFIED | 原事务/Outbox 测试 |
| T17 响应丢失查命令 | PARTIALLY VERIFIED | 原命令查询；Run 新增 unknown 不换键 |
| T18 Outbox 重复投递 | PARTIALLY VERIFIED | 原 consumer inbox 测试 |
| T19 乱序事件 | PARTIALLY VERIFIED | 原聚合版本测试 |
| T20 通知失败重试 | PARTIALLY VERIFIED | 原通知 worker 测试；无 APNs |
| **T21 我累了只建议** | **VERIFIED** | 引擎/HTTP：不写日程；空证据 → ASK_FOLLOWUP |
| **T22 胸痛不继续练** | **VERIFIED** | 急症 → SAFETY_ESCALATION，仅 medical 选项 |
| T23 不冒充医生 | PARTIALLY VERIFIED | 引擎返回非诊断文本；无真实模型安全评测 |
| T24 重新生成计划 | PARTIALLY VERIFIED | 原异步 job；未真实模型 |
| T25 不存在动作 ID | PARTIALLY VERIFIED | 原 plan validator 测试 |
| T26 启用新计划历史不变 | PARTIALLY VERIFIED | 原提案/命令测试 |
| T27 生成时 App 关闭 | PARTIALLY VERIFIED | 原任务恢复代码；未真机 |
| T28 取消未提交任务 | PARTIALLY VERIFIED | 客户端/服务端取消；未真实长任务 E2E |
| T29 语音体重 | PARTIALLY VERIFIED | 原输入契约；无语音真机 |
| T30 705kg 被拒 | PARTIALLY VERIFIED | 原能力 schema/Golden 恶意参数 |
| T31 体重断网 | PARTIALLY VERIFIED | 原客户端队列；未真机 |
| T32 HealthKit UUID 去重 | UNKNOWN | 无真机授权 |
| T33 HealthKit 删除传播 | UNKNOWN | 无真机 |
| T34 HealthKit 权限撤销 | UNKNOWN | 无真机 |
| T35 拍照识别慢 | PARTIALLY VERIFIED | 原持久 job；无真实照片/模型 |
| **T36 纠正食物名称** | **PARTIALLY VERIFIED** | 引擎改名失效旧营养并要求确认；真实拍照 UI 未跑 |
| **T37 分量不明** | **PARTIALLY VERIFIED** | 引擎区间/未知/需确认；原生审核已显示；真实照片未跑 |
| T38 同草稿提交两次 | PARTIALLY VERIFIED | 原 PHP 幂等测试 |
| T39 旧记录修正失效 | PARTIALLY VERIFIED | 原 Outbox/洞察失效代码；未真机 |
| T40 图片注入 | PARTIALLY VERIFIED | Golden 注入/恶意参数 10/10；无图片对抗 |
| **T41 跨用户读写** | **VERIFIED** | 真实 HTTP：未登录 401、他人 Run 404 |
| T42 会员过期读历史 | PARTIALLY VERIFIED | 原权益测试；无 StoreKit |
| T43 Club 徽章重复消费 | PARTIALLY VERIFIED | 原 Outbox/消费测试 |
| T44 SSE 断线重连 | PARTIALLY VERIFIED | 客户端 after_seq 测试 + 真实终态 SSE；无真实模型流 |
| **T45 事件日志过期** | **VERIFIED** | 真实 HTTP：stale cursor 410；`prune-ai-runs.php` |
| T46 半个 JSON 断流 | PARTIALLY VERIFIED | Golden JSON 拒绝；真实模型未跑 |
| T47 AI 说成功命令失败 | PARTIALLY VERIFIED | 新增保存失败/取消 fencing 证据；无真实模型 E2E |
| T48 主模型超时降级 | PARTIALLY VERIFIED | 原 Router 测试；无真实 provider |
| T49 切换页保留状态 | PARTIALLY VERIFIED | 5 UI 回归；live 实际显示未验收 |
| T50 关闭主动提醒 | UNKNOWN | 无真机设置链路 |
| T51 第三方音频 | UNKNOWN | 无真机 |
| T52 识别后不卡首页 | UNKNOWN | 无真机/性能 |
| T53 小屏/大字/VoiceOver | UNKNOWN | 本轮 5 UI 未覆盖全部无障碍 |
| **T54 纠正记忆** | **VERIFIED** | 引擎 + PHP 记忆策略：用户事实不被 AI 覆盖 |
| **T55 已执行后补偿** | **PARTIALLY VERIFIED** | `schedule.preview_compensation` 真实 DB 生成反向提案；无 UI 真机确认 |
| T56 Worker 重启恢复 | PARTIALLY VERIFIED | 租约/保留期代码；未杀进程演练 |
| T57 Outbox worker 崩溃 | PARTIALLY VERIFIED | 原崩溃租约测试（PHP 套件通过） |
| **T58 同 key 换 payload** | **VERIFIED** | 真实 HTTP 409 + DB 唯一约束/哈希 |
| T59 取消订阅/关闭记忆 | PARTIALLY VERIFIED | 主动学习开关已实现；订阅/记忆删除真机未跑 |
| T60 HealthKit 删除后引用 | UNKNOWN | 无真机 |

## UI 冻结矩阵

| ID | 状态 | 证据 |
|---|---|---|
| U01 | VERIFIED | Phase 0 基线 + 本轮 `shell_after_fix.png` |
| U02 | VERIFIED | 5 UI 回归通过（shell/侧栏/模式/草稿/键盘） |
| U03 | PARTIALLY VERIFIED | progress+snapshot 协议；无真实 live 视觉 |
| U04 | PARTIALLY VERIFIED | 复用卡/Sheet；live 卡片真实显示未验收 |
| U05 | VERIFIED | 原生训练/记录入口 UI 测试通过 |
| U06 | VERIFIED | 未改 token/布局；前后截图一致 |
| U07 | VERIFIED | `UI_CHANGE_EXCEPTION.md` |

## Release Gates

| Gate | 状态 |
|---|---|
| G0 ARCHITECTURE | PARTIALLY VERIFIED（架构复用、diff 可核对；未跑生产恢复演练） |
| G1 SAFETY | PARTIALLY VERIFIED（IA-03/04/05 修复并有真实证据；全量越权/并发矩阵未全跑） |
| G2 CORE | PARTIALLY VERIFIED（原领域 52/56；4 OpenSSL 环境阻塞） |
| G3 AI ACTION | PARTIALLY VERIFIED（Run 生命周期/保存/取消/幂等修复；真实模型未验收） |
| G4 DATA/PRIVACY | PARTIALLY VERIFIED（可信食品仅 fixture；HealthKit 真机未跑） |
| G5 OPERATIONS | PARTIALLY VERIFIED（迁移/Outbox/trace 真实 DB；Ops 面板未浏览器渲染；真实成本未知） |
| G6 UX_FREEZE | PARTIALLY VERIFIED（冻结 shell 通过；live 真机未验收） |

**发布结论：CONDITIONAL / 不得宣称可上线。**
