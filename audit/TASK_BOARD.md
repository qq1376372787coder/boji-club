# Build136 三家成果融合交付

## 最新发布状态（2026-10-28 16:22 北京时间）

Build137对应服务端已部署到117.50.119.49，业务源码提交`155749c`。更新35个文件，全部160个运行文件SHA256与候选一致。公网账号配置200、后台200、匿名账号接口401；PHP→AI确定性规则接口通过。5个核心服务正常，原有定时器恢复，私有配置指纹保持一致。

发布前在独立MariaDB 10.11.18测试库完成7次真实CLI初始化/重复迁移检查；生产结构比对无缺列。本次没有执行生产DDL或导入测试数据。代码备份：`/root/bojiclub-deploy-backups/20261028T082128Z-build137-fusion`。发布证据：`outputs/BOJI_CLUB_Build137_SERVER_DEPLOYMENT_20261028`。

下文“未部署”等表述为上次源码交付时的历史状态；以上发布状态为准。手机Logo与字号需要安装Build137客户端；本次未上传TestFlight。

版本：0.15.9 / Build136。共同基线 `29edfc6`。集成分支 `integration/three-agent-audit-20261028`。
三份原始成果保存在 `sources/deepseek-20261028`、`sources/glm-20261028`、`sources/gemini-20261028`；原交付目录未改动。
第三份 ZIP SHA256：`a5d2ea8634c59fe3824adf4d186beaa65f5b37fa642113a24c83cf20145f5d5e`。

## 已完成

- 合并三家的有效修复，处理后台、配置、统计等重叠冲突；保持 AI 首页、导航、品牌色、单饮食入口和独立上传照片。
- 双向测量删除墓碑、旧记录身份迁移、删除后新增不误删；已确认训练保护、分块同步按 key 对齐、离线重试不误计。
- 营养数据修订保留用户确认值；AI 提案日期校验、完整 SSE 错误封套、真实业务回执与页面刷新失败提示。
- 模型正文中的当前操作“已保存”修正为待确认表述；完成事实只来自业务回执。保留历史描述，不因这类话术直接丢弃整个回答。
- 后台业务分区、默认单分区、定位恢复、键盘切换与校验错误定位；权限、标签、发货和草稿保留字段。
- 配置保存/发布/回滚的版本检查置于真实行锁内；Worker 每任务刷新、长任务配置缓存最多 1 秒，未知开关关闭。
- 新手引导关闭时不阻塞普通聊天；相机预览层真实附着；Fitness 计算接收业务时区。
- 实际空库初始化 CLI 与测试共用 SQL 执行器，已有库拒绝初始化，增量迁移可重复执行。
- 补齐故障恢复、陈旧配置、相机层、双向删除等回归；资料保存失败固定显示，开发预览的本机编辑可用。

## 本次独立验证

| 范围 | 结果与证据文件 |
|---|---|
| Python | `python3 -I tests/run_offline.py`：837 项通过，0 失败；`python-offline.log` |
| Swift规则 | `python3 tests/run_swift_regressions.py --output <tmp> --jobs 2`：54/54；`swift-results.json` |
| iOS | Xcode 26.6 / iOS 26.5 模拟器构建成功；189 项 XCTest 全部通过；`ios-unit.log` |
| iOS重点UI | 5 个不同场景最终通过：训练首屏、长对话避让、原生输入菜单、导航切换、资料修改保留计划；`ios-ui-initial.log` 与 `ios-profile-final.log`。首次资料用例失败已保留证据并修正预览保存路径。 |
| PHP/SQL | PHP 8.3.12 + 专用 MySQL 8.4.0 Unix Socket；72/72 组通过；最终完整套件结果见 `php-summary.log` / `php/results.tsv`；AI Run 中 75 条断言包括 SQL 故障恢复、重放、取消和真实业务回执。 |
| 数据库入口/并发 | 实际 `init-schema.php --apply`、重复初始化拒绝、真实增量迁移重复执行、InnoDB 配置锁等待均通过；`php/test_schema_runtime.log` |
| 后台HTTPS | 实际PHP页面 + 本机TLS代理：4项通过，覆盖5角色权限、配置发布/ETag、陈旧草稿保存/发布/回滚拒绝；`admin-https.log` |
| 后台DOM | 18项检查通过：分区导航/校验7、奖励6、实时监控5；`admin-dom.log` |
| PHP语法 | 174个文件通过；`php-lint.log` |
| 交付检查 | Git diff空白检查通过；源码密钥模式扫描未发现真实API密钥/私钥；打包只使用Git已提交文件，排除运行数据、本机配置与凭据。 |

验证使用专用本机数据库、合成账号与私有接口夹具；没有访问生产数据，没有调用付费模型，没有部署。模型接口夹具不等于真实供应商验收。初次直接 unittest discover 误载入需要服务的HTTP套件失败；随后按项目离线/服务端/HTTP通道分别运行，未删除测试。早期PHP缺扩展、夹具日期/重复依赖/残留限流窗口等失败均定位处理；原断言场景保留，并为新规则补充断言。

## 待外部环境验收

- 未运行真实设备 Apple 登录、HealthKit、APNs、相机拍摄、StoreKit/RevenueCat 真实沙盒及供应商模型联调；模拟器/合成接口结果不代替这些验收。
- 生产资料记载 MariaDB 10.11；本次实际数据库为 MySQL 8.4。MariaDB版本实跑与生产发布不在本次完成声明内。
- 新用户真实服务器 UI 用例需要其专用账号服务，未计入上面的5项UI；共享资料与首次计划持久化由PHP回归独立验证。
- 正式域名备案/解析状态未在本次改变。协议网站与App既有接入完整保留。

## 复跑

在未配置生产连接的隔离副本中：

```sh
python3 -I tests/run_offline.py
python3 tests/run_swift_regressions.py --output /tmp/boji-rules --jobs 2
PHP=/path/to/php BOJI_TEST_DSN_BASE='mysql:unix_socket=/path/to/disposable.sock' bash tests/run_php_suite.sh
node tests/test_admin_tabs.js
node tests/test_admin_v17.js
node tests/test_throughput_admin.js
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test -only-testing:BojiClubTests
```

PHP需要 pdo_mysql、openssl、mbstring、filter、ctype、session、fileinfo、gd。SQL套件会重建固定测试数据库，只能使用专用实例；脚本拒绝已配置checkout。PHP套件会自行启动并清理隔离Python规则服务18792（只运行确定性规则、不启动模型Worker）；端口占用会明确失败，固定测试token见 `tests/test_intelligence_closure.php`。后台HTTPS测试入口 `tests/test_admin_v2_http.py`，需要专用管理员fixture与TLS；测试使用真实安全Cookie，没有降低生产Cookie配置。

真机或TestFlight请打开 `BojiClub.xcodeproj`，配置自己的签名并选择TestFlight配置。本次没有上传TestFlight或部署服务器。

## Build137 · 2026-10-28 首页标识微调

在Build136融合版本上，仅缩小Club AI首页品牌标识：Logo 64→48pt，中文名称caption→caption2，字距2→1.5，内部间距10→8pt。动态字体仍由系统控制。Build号137，版本0.15.9；本次增量iOS模拟器构建通过（`/tmp/boji137-ui-build.log`），没有重复运行全量业务测试。上文189/837/72等为Build136融合验证结果。

本次没有部署服务器或上传TestFlight。工程已采用自动签名及TestFlight Scheme；本机只读检查当前可用代码签名身份为0，正式上传需由Xcode完成账号权限及签名配置。

## Admin workspace reconstruction (approved 2026-10-28)

In progress: seven task-based modules; server-selected subpages; native editor dialogs and member drawer; feedback split view; scoped configuration saves; concise Chinese copy; real browser and HTTP verification before server rollout. Preserve action handlers, permissions, CSRF, data and existing routes.

## Admin R1 · 当前交接节点（2026-10-28）

已完成代码与本地验证：7模块导航、服务端分栏、列表分页/筛选、成员抽屉与原生编辑弹窗、反馈左右布局、配置分栏保存与版本保护、易懂中文、真实功能范围标注、成员编号识别、统计去重、推送单位纠错、备份状态发布与5分钟只读监控。详细问题见BUG_TRACKER，逐项功能及缺口见ADMIN_AUDIT。

验证：73 PHP套件通过；11 HTTPS用例通过（五角色、持久化/重复提交/陈旧窗口/CSRF/AI控制消费）；8加密备份用例通过；104 PHP文件语法通过（另有未新增PHP语法的测试fixture）；DOM18项通过。截图为本机合成测试数据，不是生产数据。未重跑iOS或拍视频。

待办（不能当作已完成）：
- SSH恢复后，先只读核对`bojiclub-backup.timer/service`、其journal、root备份结果JSON、加密文件是否存在和PHP runtime目录权限。当前连接在SSH协议认证前关闭，网站HTTPS返回200；用户确认未改端口和安全组。没有证据证明线上备份从未运行。
- 在root执行环境备份当前代码、核对差异后部署本轮Admin文件；本轮无DDL、无App二进制变化、无生产数据删除。保留config.php、.env、媒体、数据、已发布App配置。
- 备份脚本需安装到`/root/bojiclub-rebuild-v59/backup.py`；先核对现有脚本与实际文件位置，不能跳过必须恢复项来让备份假成功。
- 创建/核对`/opt/bojiclub-account/runtime`目录；备份service新增此目录写权限；安装新backup-monitor service/timer。每日backup.timer改为显式Asia/Shanghai，保持03:17+最多5分钟随机延迟。
- `backup.py --dry-run`应完整通过；`--status-only`只更新摘要、不生成备份；再运行一次备份，检查本机文件及只读解密校验，确认后台真实显示。未配置异地副本时必须仍显示“未配置”；未实际恢复演练时仍显示“尚未验证”。
- 不执行旧deploy.sh全量DDL，不向生产发送测试通知，不修改生产模型密钥，不把本地fixture配置复制上服务器。

测试复跑：`tests/test_admin_workspace.php`；`tests/test_admin_v2_http.py`与`tests/test_admin_workspace_http.py`需要合成账号库、真实本地PHP/Python和TLS。`tests/fixtures/admin_workspace_fixture.php`只接受固定测试库；`BOJI_WORKSPACE_TICKET`传入生成的反馈UUID。`tests/test_backup_status.py`完全使用临时文件、模拟数据库导出和真实加密/解密，不连接生产。

## Build139 合并与运营闭环 · 2026-10-29

已完成代码：以本仓库 Admin R1 为基线，仅合入外部 Build138 的 iOS 升级，升级为 Build139；修正伪造默认体重/热量/训练周数、无依据订阅折扣、首次引导权限及深链冲突。新增通知计划真实调度/队列、订阅来源与权益核对、后台异常提醒、加密备份状态和隔离恢复演练。

独立验证：iOS App/Widget 构建成功；DataIntegrityRegressionTests 11/11；PHP 75组全通过；后台真实 HTTPS 13/13（含新增页面角色隔离、通知草稿持久化、过期编辑拒绝）；DOM 18项；PHP语法115文件；备份9、可选接收器16、告警20、隔离恢复12项通过。证据暂存 /tmp/boji139-* 与 /tmp/boji-build139-review-*，交付时复制到 outputs。均为本机隔离数据/接口夹具，不代替正式 APNs、付费模型或商店交易。

当前部署节点：SSH 已恢复为可用的验证主机指纹的密码连接；线上 MariaDB10.11.18，现有备份文件确实存在（每天03:25旧任务，最近文件约426MB），后台未接入状态，不能将其误判为从未备份。准备版本校验、增量迁移、代码切换和真实加密备份恢复演练。未完成前不宣称已部署。

最新用户决定：仅在服务器保留备份，取消 Mac 异地接收安装，不把生产备份或解密数据下载到 Mac；邮件待用户稍后配置，后台告警先启用。当前没有真实邮件发送，也没有开启通知群发。

下一步：完成远端候选完整哈希比对；先备份，再执行两项只增建表的迁移并核验；切换代码并恢复原任务；安装备份监控/通知队列/告警定时器；停用旧异地复制定时器；真实服务器隔离恢复；记录结果并提交交付。

## 2026-10-29 · 实际部署结果与准确断点

已完成并观察到：
- 主体代码0028d258（Build139）已部署：73个运行文件更新，213文件完整哈希核对；AI服务/PHP/两常驻处理进程健康；App公开配置version1保持，线上config.php/.env指纹保持。
- 两项迁移均apply/check通过，只新增5张表；最初用业务账号迁移被CREATE权限拒绝，未扩大其权限，改用服务器本机root迁移。实际恢复旧备份89表后再迁移，以及两个新模块72断言，在隔离MariaDB10.11.18中通过。
- 备份在服务器已真实运行，并非从未执行。部署前新包bojiclub-full-20261028T170135Z.boji的SHA256=76bd2c09256f9a08ce926ba3a2e4074c62f044a8e8a84eb59d7b888e76abf8ca；已还原89表/296条数据并通过AI SQLite校验，临时库清理完成，未连接生产socket执行恢复。
- 部署后又运行新版完整备份，service结果success；尚未完成对这份最新包的再恢复，不能将旧SHA演练结果用于新包。
- 每日03:17北京时间+最多5分钟随机延迟、5分钟备份监控、每分钟通知计划、5分钟后台异常采集已安装启用。通知计划空队列真实执行成功：runs/recipients/sent均0。旧异地复制timer已disable，未安装Mac接收器，没有把生产备份下载到Mac。
- 用户随后明确同意启用今后新分析完成提醒；本地67b8839提交已增加必填UTC启用边界、nginx用户和缓存权限修正，27条断言通过。另修复告警服务只读挂载不兼容SQLite WAL的问题，沙箱只读查询对照已通过。

**未完成，不可宣称已生效**：最后5个文件的小修正与新结果通知启用仍未部署；SSH持久会话中断后，密码验证前连续被服务器关闭（Paramiko/OpenSSH均复现，HTTPS后台仍200）。密码此前已实际成功使用，不是缺密码。仅有主体0028d258已上线，最终67b8839还未上线。后台可能仍有AI采集权限误报及“分析完成提醒未启用”两条告警；不得隐藏告警当作修好。邮件按用户决定暂缓。

恢复SSH后立即续做（根目录候选与脚本均已上传，不要重新合入或覆盖生产配置）：
1. 排查sshd认证前拒绝原因（云控制台），不关闭鉴权/主机指纹校验、不重启整台服务器、不把密码当故障原因。
2. 运行 `python3 /root/boji139-rebase.py`，它先校验主体部署哈希，再解开5文件差异包；然后 `python3 /root/boji139-server-candidate/deploy-verified-runtime.py /root/boji139-server-candidate --apply`；最后 `python3 /root/boji139-enable-results.py`。每步必须成功才继续。注意rebase不得重复运行覆盖初始部署证据；先检查manifest/运行哈希是否已经更新。
3. 核对UTC启用边界文件 `/etc/bojiclub/push-activation.env` 已安装且未回退；nginx实际APNs签名预检必须通过，不打印token。通知按用户设置和免打扰，仅处理启用后新结果，不给真实设备发测试通知。
4. 再运行服务器备份并对最新包执行 `/opt/bojiclub-account/deploy/restore-drill.py`（使用既有cryptography虚拟环境Python、独立数据目录/无网络socket），更新backup-monitor/operations-alerts，核对两条告警真实恢复、0未知项。辅助脚本已保存在交付目录operations-tools；勿把备份下载到Mac。
5. 下载无隐私的部署/迁移/恢复摘要与哈希清单到交付证据；再次提交最终台账。此次断点不代表最终服务器验收完成。

当前源代码已完成且可构建；尚未上传TestFlight。iOS修改需要安装新的客户端，不能靠服务器部署改变已安装的App二进制。
