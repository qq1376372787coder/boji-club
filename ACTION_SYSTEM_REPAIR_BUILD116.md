# BOJI CLUB AI Action System 修复与补齐交付 — Build 116

日期：2026-10-25。版本：0.15.1 / Build 116。基于用户最新 `BojiClub-V2-Phase1-20261025.zip` 独立工作副本修改，原 ZIP 不变。本说明取代旧交付报告中的完成度、默认开关、迁移和回滚描述。根目录其他历史报告与 manifest 保留溯源，不代表本包验收状态；本包文件哈希以 `ACTION-SYSTEM-BUILD116-MANIFEST.json` 为准。

本次完成了独立复核的 AS-01～AS-32 对应代码修复，并补齐核心能力的业务、iOS 与后台衔接。保留此前已完成的 AI 唯一主界面、原生胶囊选择、液态玻璃组件与旧首页移除结果。没有部署生产、操作真实账户数据或上传 TestFlight；没有录制视频或运行大规模 UI/性能矩阵。这里的“修复”表示代码落地并按下表范围检查，不声称所有设备和生产依赖已经验收通过。

## 已补齐的核心流程

- 15 个核心能力通过注册表和领域服务处理。模型能提出预览，确认、撤销、放弃训练草稿使用独立用户接口。浏览历史对话只读取行动状态，不触发历史写入。消息、子行动、幂等键和租约可跨请求恢复。
- 开始、恢复、记组、结束训练与活动会话约束衔接。未完成目标提供保存实际组并结束、继续、放弃未完成草稿三种选择；放弃保留已记录组，后续训练产生新会话与新目标。结束快照与已记录事实不一致时报告冲突，数值纠正走明确勘误入口。
- 改期、单次换动作、新计划启用均基于具体前后快照确认；有目标冲突或受保护训练时拒绝静默覆盖。排程独立版本与身体/饮食版本分离。原生手动入口保留现有 Repository/Store：命令入口与分片/旧整包兼容适配器共用账号锁、事实校验、审计和 Outbox，未大规模替换用户数据结构。
- 新计划进入真实持久队列，保存输入、会员校验、服务端身份与配额归属，调用现有私有 AI 服务，支持稳定 ID、轮询、失败和超时。生成时参考有上限的已确认表现与可撤回偏好。候选必须匹配打包的 678 项动作库或当前账号个人动作；编辑后保存草稿，再生成绑定版本的服务端预览，明确确认后启用不可变计划版本。
- 长期换动作生成 **28 天明确日期的候选版本**，保留已有训练事实，经编辑与确认后同时保存可复用模板和已确认偏好。不把无限未来伪装为已排程；后续周期通过已有模板继续安排。
- 饮食草稿可编辑餐次、份量、营养值和估算标记，保留识别置信信息。保存编辑原子取消旧确认卡片并生成新卡片，最终确认前不写正式餐食。同一编辑响应丢失可沿用编辑 ID 恢复。
- 身体记录按独立测量实体保存，同日多笔、来源、测量时间、删除墓碑均保留。记录页可逐笔纠正和删除；同步按实体更新时间合并，不冻结初始数值；删除墓碑跨设备合并。撤销不会回填整天旧快照。
- HealthKit 使用本地按账号隔离的 anchored 样本缓存，分页、anchor、新样本和删除一并保存；明确共享后才进入云同步。写回体重另需单独开关与系统授权，以样本同步标识防回流重复。健康源样本仍由健康 App 管理。
- 离线队列保留新增项、重试次数和阻塞项；账号切换后的旧响应不操作新队列。提供失败项查看、重试以及备份本地冲突后采用云端当日数据的明确处理入口。
- Outbox 按消费者实际订阅去重、对账；权威状态即时读取，派生投影标记版本与真实缺口。已同步后失效相关缓存，并延迟合并刷新记忆与首页洞察。通知队列接入 APNs worker，遵守账号、登录会话、设备、用户偏好、静默时段及预算；记组不会发送“整场已保存”通知。

数据库中的计划版本、发生日期与完成事实继续映射现有文档/分片实体，并未虚构已经存在独立 `workout_occurrence` 等全部 SQL 表。文档“建议额外支持”的独立模型工具没有一口气全部扩张：暂停/恢复计时、饮食修改、趋势查看等已有原生入口继续使用；本轮提供 `action.get_status` 和用户撤销。核心能力与可选建议应区别验收。

## 32 项复核问题对照

| 编号 | 原问题 | 本次落实 | 主要代码 |
|---|---|---|---|
| AS-01 | 撤销操作使分片历史脱离权威读取路径 | 撤销沿用分片写边界并保留 _partitioned，窗口外历史不脱离权威读取 | ai-router.php / business-state.php |
| AS-02 | 撤销较早体重记录会抹掉之后的新测量 | 体重拥有独立测量 ID；撤销仅删除目标 ID，后续测量保留 | action-support.php / ai-router.php |
| AS-03 | 模型白名单包含高影响确认能力，可绕过独立用户确认 | 模型白名单排除确认和撤销；服务端独立用户确认端点再次鉴权 | capability-registry.php / action-execution.php |
| AS-04 | 能力写入绑定消息视图生命周期，存在漏执行和重放 | 接收消息时登记；服务端完成编排；持久化 message/call ID；界面仅查询结果 | weekly.php / action-execution.php / ClubCoachView.swift |
| AS-05 | 换肌群和启用计划确认使用未赋值变量，必然拒绝 | 确认分派前解析提案类型与存储载荷 | commands.php |
| AS-06 | 三个训练能力缺少命令映射；记组契约还会把完成组当未完成 | 三种训练能力映射完整；上下文按真实 ID 解析；记组使用实际完成语义 | action-plans.php / training-commands.php |
| AS-07 | 异步生成计划只插入映射表，没有真正入后台任务队列 | 持久任务、输入、租约、重试、超时、真实私有服务提交与轮询 | action-jobs.php / process-action-jobs.php |
| AS-08 | 启用计划的工具输入与提案输入互不兼容 | 按账号和草稿 ID 读取可信内容，绑定当前安排生成预览 | action-plans.php / index.php |
| AS-09 | 饮食直存工具没有提供业务层必需的 entry_id 契约 | 可信行动层为每餐生成稳定实体 ID，严格校验每个食物项 | ai-router.php / capability-registry.php |
| AS-10 | 饮食与体重降级预览的卡片协议接不上客户端 | 饮食与体重使用注册卡片类型及顶层原生载荷，类型解码失败不确认 | ai-router.php / AICards.swift |
| AS-11 | 高影响预览只显示通用句子，用户看不到具体变更 | 预览包含具体日期、动作、组数与前后差异；计划进入编辑与比较页 | AICards.swift / PlanView.swift |
| AS-12 | iOS 手动体重命令未携带服务端必需幂等键 | 原生直记载荷携带幂等键、命令 ID、测量 ID | AppStore.swift / ClubProposalSync.swift |
| AS-13 | 刷新队列时会删除等待期间新加入的命令 | 按命令 ID 从当前队列删除已确认项，保留 await 期间新增项 | AppStore.swift |
| AS-14 | 队列重试次数不落盘，达到上限反而删掉仍称已保留的操作 | 每次重试次数落盘；达到上限阻塞且保留，设置页可核对重试 | AppStore.swift / ProfileView.swift |
| AS-15 | 执行状态查询和错误恢复协议不一致 | 统一状态 DTO 和 execution ID；断网查询原操作状态，成功别名归一 | action-execution.php / ClubProposalSync.swift |
| AS-16 | 同一天多次真实称重没有保存为多笔测量 | 同日测量列表与删除墓碑；记录页逐笔显示、纠正和删除 | Models.swift / BodyWeightView.swift / action-support.php |
| AS-17 | 按内容哈希充当意图幂等，合法新操作被误判为旧重试 | 操作身份取自用户意图/message/call，不再取数值内容；相同 A/B/A 可独立保存 | action-execution.php / ai-router.php |
| AS-18 | 结束训练没有验证 session 与日期对应关系 | 结束操作验证会话、日期与当前活动槽；保留已保存事实 | commands.php / training-commands.php |
| AS-19 | 单活跃会话守卫没有覆盖真正使用的分片同步路径 | 分片提交与整包同步共用活动会话预检，先合并整批 override 再验证 | action-sync.php / cloud-parts.php / index.php |
| AS-20 | 28 天训练历史查询漏掉中间两周分片 | 加载完整查询窗口，中间分片也读取；新增实际动作与组数值明细 | ai-router.php / ClubCoachView.swift |
| AS-21 | 疲劳建议忽略用户的问题，把缺记录视为可以正常训练 | 疲劳问题传入评估；缺少证据不能给正常训练结论；建议不改日程 | ai-router.php |
| AS-22 | 复合任务发生一条错误时会中断整批，已成功部分不返回 | 子行动作用域异常可独立处理，保留已成功及后续子结果 | action-support.php / action-execution.php |
| AS-23 | 取消或失效提案再次请求时，被假装成新的待确认预览 | 读取真实终态，取消/过期不会包装成新的等待确认 | ai-router.php / action-execution.php |
| AS-24 | 取消接口有竞态，可能显示取消成功但操作已执行 | 取消在账号锁、事务、状态 CAS 下执行；不能覆盖已经提交的状态 | index.php |
| AS-25 | 对账把不关心该事件的消费者也当缺失，形成永久重排 | 只为订阅该事件的消费者计算缺失回执；消费者与事件去重 | domain-consumers.php |
| AS-26 | 对账 CLI 将已处理计数当缺口，且取标量结果时当数组 | 修正 CLI 标量读取与计数口径；报告真实 missing 与 requeued | reconcile-domain-outbox.php |
| AS-27 | 新增提醒只写展示日志，没有接入实际发送、用户偏好与预算 | 持久通知队列、APNs 发送 worker，验证有效登录、偏好、静默时段与预算 | domain-consumers.php / process-domain-notifications.php |
| AS-28 | 投影新鲜度在消费者缺失时仍报告同步完成 | 新鲜度同时计算待发布与已发布缺失回执，不再误报全同步 | ai-router.php / domain-consumers.php |
| AS-29 | 新迁移 SQL 在 MySQL 8.4 上不能执行 | 移除 MySQL 不支持的 ADD IF NOT EXISTS 用法；重复扩展不缩小已有枚举 | migrate-v2-repair.php |
| AS-30 | 迁移 --check 只检查表，列和索引缺失也会通过 | 检查表、声明列、索引、主键、幂等唯一索引与提案枚举 | migrate-v2-repair.php |
| AS-31 | “全阶段默认关闭、删新表列即可回滚”的承诺不成立 | 增加可独立停用的 AI 行动总开关；回退保留增量表列与已写事实 | app-config.php / admin / 本交付说明 |
| AS-32 | 提案过期时间不是客户端约定的带时区 ISO 格式 | 输出带 UTC 时区的 ISO 8601；无效时间客户端安全禁用 | action-support.php / AICards.swift |

## 本轮实际验证

| 检查 | 实际结果与范围 |
|---|---|
| iOS Debug / arm64 模拟器构建 | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` 成功；未运行 UI、性能或视频检查 |
| PHP 语法 | account-server 的 68 个 PHP 文件通过 |
| 训练领域集成 | 65 项断言通过 |
| AI 路由集成 | 83 项断言通过 |
| 投影/事件集成 | 22 项断言通过 |
| 本轮补充集成 | 56 项断言通过：实体撤销、重放、子行动失败隔离、实际换动作确认、队列到草稿到版本激活、长期模板/偏好、饮食编辑失效旧卡片、放弃后新场次、历史明细、会员拒绝和版本缺失拒绝等 |
| MySQL 8.4 迁移 | 隔离数据库实际 apply、重复 apply、缺列负例检测和恢复后 check 通过；未据此声称 MariaDB 实机验收 |
| Swift 规则/协议 | 99 项组合检查通过；额外实际队列函数 4 项回归、实际合并函数 2 项回归通过。后两组沿用前述基础链，不重复加总基础断言 |
| Python 工具协议 | 10 项测试通过；含上下文的计划请求通过真实请求校验器；相关 Python 文件可编译 |
| CI | 新增 Linux + MySQL 8.4 后端检查任务；本地执行同一脚本通过，未声称托管 CI 已运行 |

异步计划集成使用明确标记的私有服务 transport fixture，验证排队、派发协议、草稿保存及真实领域确认；它不等于真实模型的端到端调用。真实模型供应商、生产会员与 APNs 凭据、HealthKit 系统授权/删除/后台增量、真机强杀与双设备网络时序，仍需接入实际环境验收。本轮按用户要求不消耗这些服务、不增加视频或大规模设备测试。测试修正同时包含原交付夹具中的错误账号、空训练组、错误 SELECT 结果复用等问题，未把错误夹具的原结论当作有效证据。

复现命令：`BOJI_TEST_DSN_BASE=... PHP=php bash tests/run_action_checks.sh`，**仅允许指向可丢弃测试实例**，该脚本重建 `bojiclub_it`；Swift 定向脚本为 `tests/run_training_commands.sh` 和 `tests/build_action_queue_swift_tests.py`。关键日志摘录在 `docs/action-system-build116/verification.txt`。

## 上线、监控与安全回退

本节是交接步骤，本次没有执行生产部署。

1. 备份生产数据库、现有代码及私有配置。暂停 AI 行动开关和对应 timer，先完成兼容迁移，再切换依赖新列的代码；有条件使用维护窗口，避免跨版本写入。
2. 使用 DDL 维护账号执行 `account-server/migrate-v2-repair.php --apply`，随后 `--check`。脚本支持 `BOJI_MIGRATION_DSN/USER/PASSWORD` 和服务器维护用 `BOJI_MIGRATION_ROOT=1`；应用日常 DML 账号不需要永久获得 DDL 权限。迁移可重复，不收缩已有扩展枚举。
3. 部署完整 `account-server`（必须包含 resources）及 backend Python 修改，保持现有 loopback AI 服务令牌/额度配置，安装 action-jobs、domain-outbox、domain-notifications、domain-reconcile 的 service/timer。`deploy.sh` 已接入安装及检查，但这里未运行它。通知还需既有 APNs 配置和有效设备授权。
4. 默认配置：`action_system_enabled=true`、`training_commands=true`、`direct_records=true`；用户的 AI 快速直存默认 **false**，HealthKit 写回另行授权。已有发布配置中的旧值保持有效，需要后台核对，不能假设安装后自动覆盖旧设置。
5. 观察 action jobs 的 pending/running/failed_retryable/failed_final、Outbox pending/processing/dead_letter、订阅缺失回执与通知失败状态；对账会把真实缺口重排而非循环投递无订阅事件。不要只看 HTTP 202 或某个“已受理”卡片判定完成。
6. 若需停用：关闭 `action_system_enabled` 并停用 action-jobs timer，保留查询与必要撤销恢复通道；必要时暂停通知/Outbox timer。保留所有增量表列、已提交记录与不可变版本。**不要 DROP 新表/列或回填旧整包**。恢复只支持经过 schema 检查、能理解新增记录的兼容代码；需要灾备回滚时按备份与审计制定数据恢复方案，不能将旧源码直接覆盖后继续写。

## 文件与交付边界

`docs/action-system-build116/changed-files.csv` 列出代码修改/新增文件，`filename-repairs.json` 记录继承包中中文文件名乱码的修复。本包完整源码包含之前 UI 资产、后端、测试、worker、迁移和本轮文档；不包含 .git、构建缓存、私有 config.php、测试数据库或新视频。历史 manifest 仅供追溯，本包清单覆盖所有实际打包文件。
