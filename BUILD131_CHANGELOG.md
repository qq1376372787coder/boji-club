# Build131 交付说明

本次基于 Build130 源码提交 `c2b6a820d4c26af8b0a940e74a650126e0d2026b` 实施已确认选项。Build 号为 **131**，版本号 **0.15.6**。

以下“已实现”指代码已落地并通过本次普通检查，不等于所有型号真机及真实模型业务验收已完成。第 15 项云端语音识别已按用户要求取消，其余已确认项均已实施。

| 项目 | 选项 | 实际落地 | 主要代码 |
|---|---|---|---|
| 1 | B | 常见食物目录匹配、可修改份量和确定性营养计算；长尾描述使用候选真实食物 ID 归一化，不冒充精确称重。 | [backend/nutrition_intake131.py](backend/nutrition_intake131.py) |
| 2 | B | 首页“安排训练”打开对话内的制定计划卡：补条件、选起始日、生成一周计划、查看并调整，确认后才加入日历。 | [BojiClub/Experience131.swift](BojiClub/Experience131.swift) |
| 3 | 已指定 | 引用显示为输入框上方可删除 chip，正文不再自动插入 @标题；保留输入 @ 的最近记录联想。 | [BojiClub/SharedComposer.swift](BojiClub/SharedComposer.swift) |
| 4 | B | 移除加号菜单的换行；回车发送，输入法组词期间不误发；原生编辑菜单与 Shift+Return 可换行。 | [BojiClub/Experience123.swift](BojiClub/Experience123.swift) |
| 5 | 已指定 | 加号选择记录或联想选择后立即显示 chip，并轻震动反馈。 | [BojiClub/SharedComposer.swift](BojiClub/SharedComposer.swift) |
| 6 | B | 发送本机选中记录的只读副本，不再等待整库同步；明确标记来源，不将副本写回业务记录。 | [account-server/public/local-context131.php](account-server/public/local-context131.php) |
| 7 | A | 日报、周复盘按钮直接路由到 Club AI，移除旧的弹层内桥接链；按按钮所属日期选择范围，不重复提交。 | [BojiClub/ClubCoachView.swift](BojiClub/ClubCoachView.swift) |
| 8 | A | 顶部 Club AI / 训练 / 记录三页切换；记录有独立导航栈，聊天草稿与训练日期保留。 | [BojiClub/ClubAIShell.swift](BojiClub/ClubAIShell.swift) |
| 9 | A | 设置入口改为系统语义主文字色，辅助信息灰色、危险操作红色，支持深色模式。 | [BojiClub/Experience130.swift](BojiClub/Experience130.swift) |
| 10 | A | “我的”四个主入口统一线性系统图标、字号、宽度与行高。 | [BojiClub/ProfileView.swift](BojiClub/ProfileView.swift) |
| 11 | A | 缺少训练条件时只列出缺项，编辑后重新读取权威资料并继续生成；包含年龄范围，取消泛化红色拦截循环。 | [BojiClub/Experience131.swift](BojiClub/Experience131.swift) |
| 12 | A | 后台新增删除账号及个人数据：角色权限、CSRF、确认目标 ID、原因与事务内审计；撤销会话，使用持久清理任务和失败重试，保留未完成礼品申领拦截。 | [account-server/admin/bootstrap.php](account-server/admin/bootstrap.php) |
| 13 | A | 侧边栏标题保留 BOJI CLUB 文字，移除左侧 Logo；其他品牌展示保留。 | [BojiClub/ClubAIShell.swift](BojiClub/ClubAIShell.swift) |
| 14 | A | 三页切换、发送、引用选择及收到回复等关键事件轻震动；不逐 token 震动，回复事件按账号与消息去重。 | [BojiClub/Experience131.swift](BojiClub/Experience131.swift) |
| 15 | 取消 | 按用户最新要求，保留 Apple 本机语音识别，不新增云端 ASR、SDK、服务凭证或付费语音测试。 | [BojiClub/MealSpeechInput.swift](BojiClub/MealSpeechInput.swift) |
| 16 | A | 文字/语音餐食识别自动支持一餐至多餐，移除手动多餐开关；单纯列出多种食物不代表多餐，仍逐餐核对保存。旧草稿及只记录名称路径保留。 | [BojiClub/MealEditorView.swift](BojiClub/MealEditorView.swift) |
| 17 | A | 先显示餐食与营养摘要，修正、份量、明细和说明按需展开；保留底部保存入口与草稿保护。 | [BojiClub/MealEditorView.swift](BojiClub/MealEditorView.swift) |
| 18 | A | 保留 SwiftUI 聊天列表；稳定消息身份、消息插入动画、批量流式刷新和跟随滚动，兼容减弱动态效果。 | [BojiClub/ClubCoachView.swift](BojiClub/ClubCoachView.swift) |
| 19 | B | 安全请求预拦截与模型范围规则；账号/安装标识/IP 限速；真实出站尝试预算包含失败、重试和备用模型，限制无关闲聊，不因出现政治词语直接封禁。 | [backend/usage_guard131.py](backend/usage_guard131.py) |
| 20 | B | 已保存但未同步的本次训练可直接引用复盘；服务端与输出校验双层限制副本为只读，涉及实际改动仍走正式业务确认。 | [account-server/public/action-execution.php](account-server/public/action-execution.php) |

## 检查与服务器

- iOS：27 项针对性单元测试通过，包含 5 项新增测试及聊天登录、引用与输入回归；最终 TestFlight 配置模拟器构建结果见证据文件。
- Python：本机与隔离服务器各 41 项测试通过，无付费模型请求。
- 数据库：独立 MariaDB 测试库完成 21 条断言，验证未同步记录分析、跨账号/对话隔离、过期、加密、限速、禁用用户删除、重复删除及审计失败回滚；测试库已删除。
- 服务端：17 个运行文件部署到 117.50.119.49，逐文件 SHA256 复核；AI 健康接口 HTTP 200，PHP、AI、流式 Worker、Nginx 正常，未登录后台访问维持 403。
- 数据库迁移：仅新增 `ai_guard_buckets131` 请求计数表，不改写已有训练、饮食、身体或用户业务记录。第一次尝试因应用数据库账号没有建表权限中止并恢复原服务；之后使用现有数据库管理权限完成，不扩大应用账号权限。
- 未做视频、200 条付费模型业务测试、真机触感/麦克风/相机验收或 TestFlight 上传。手机需要重新安装 Build131 才会出现新的界面和交互；部署服务器不会更新手机包。

## 使用边界

1. 引用与训练复盘不再依赖先完成整库同步，但云端 AI 分析本身仍需要网络。模型不能将本机副本当作服务器已保存或已执行的事实。
2. 食物营养为明确标记的估算；大小、馅料、生熟做法有差别时可修改份量，无法合理判断的食物仍需补充一个关键条件。没有声称任意食物都能精确识别。
3. 安全规则和限速降低滥用成本，不声称能识别所有语义绕过；仍建议后续由独立 Agent 进行真实业务与安全边界审查。
4. 预算按出站尝试与保守 token 上界预留，失败、重试不返还；它不是供应商账单。默认每账号每日 120 次出站尝试、240 万 token 上界、15 条触发模型的闲聊；全局每日 6000 次/5000 万 token 上界。可以用 `BOJI_MODEL_*` 与 `BOJI_CASUAL_MESSAGES_ACCOUNT_DAY` 环境变量调整。原有会员权益/成功次数限制仍生效。
5. 账号删除会清理个人数据与媒体并撤销登录，Apple 订阅需由用户在系统中另行取消；清理外部 AI/Apple 授权失败时会保留可见的重试任务。

## 复核入口

本目录包含源码 ZIP、SHA256 清单、代码差异、部署状态与普通检查日志。源码包不含 API 密钥、服务器配置、签名私钥、真实用户数据库、DerivedData 或视频。
