# 验证结果与复现入口

所有测试日志在 evidence/。未录制视频，未删除或跳过失败测试。

1. `python3 -I tests/run_offline.py`：732 测试通过。期间可见故障注入预期 OperationalError 日志，最终退出码0。最后新增真实HTTP营养用例覆盖“先搜索后计算”及全新计算请求。
2. `python3 tests/run_golden_evals.py --report <临时报告路径> --json <临时JSON路径>`：120 个确定性案例，0失败；不是供应商质量/成本评测。
3. `xcodebuild test -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug -destination 'platform=iOS Simulator,id=<专属模拟器>' -derivedDataPath <隔离构建目录> -jobs 2 -only-testing:BojiClubTests CODE_SIGNING_ALLOWED=NO`：62 测试，0失败。
4. `xcodebuild build -project BojiClub.xcodeproj -scheme BojiClub -configuration Release -destination generic/platform=iOS -derivedDataPath <隔离构建目录> -jobs 2 CODE_SIGNING_ALLOWED=NO`：成功。具体实际命令保留在日志首行。
5. 在服务器创建独立、仅Unix socket可访问的 MariaDB 实例，DSN为 `mysql:unix_socket=/var/tmp/boji-fix-testdb-20261025/mysql.sock`，以 `BOJI_TEST_DSN_BASE` 传入，执行 `bash tests/run_php_suite.sh`：57/57 PASS。该入口会清空测试schema，只允许指向独立测试实例；不得改为正式DB的socket。部分引擎联动用例使用另起的127.0.0.1确定性服务，不把它当供应商验收。
6. 三个迁移脚本 `migrate-build112-compat.php`、`migrate-v2-quality.php`、`migrate-v2-repair.php` 对正式库结构的无数据副本执行apply/check，再在部署中对正式库执行增量迁移及check，均通过。正式用户行未复制到测试库。
7. 原取消竞态复现：两个PDO连接与仅测试库的SLEEP触发器放大窗口，action子调用与cancel竞争。修复后子调用cancelled，没有BodyWeight领域写入，见race-*.txt。
8. 真实LongCat测试：沿用服务器既有供应商配置，仅合成训练咨询一条；25真实delta，后端源流持续4.783秒，首delta早于完成。真实worker第一次在测试服务未就绪时重试，保留原身份后完成，retry日志保留。不是全供应商质量保证。
9. 隔离PHP HTTP测试：SSE200/40事件/25delta/单completion；断点续读；未登录401；相同身份同Run；payload变更409；会话限流429；取消；日志过期410仍可取最终快照。
10. 线上小范围检查仅使用本次创建的合成账户和预置Run，不产生模型任务，10订阅取消均收到事件；4进程池上限有效，普通配置和取消约17ms。合成用户已按ID和唯一subject删除。这不是50/100用户压测。
11. 最终线上探针实际调用内部营养和安全HTTP接口：1根香蕉缺质量为未知，明确100g返回89kcal；严重喘息SAFETY_ESCALATION；特殊情况ASK_FOLLOWUP。不读取真实用户健康数据，不额外调用付费模型。

曾出现的非通过结果与处理：首次PHP四项因测试runner引用macOS OpenSSL路径，已改为只在该文件存在时设置；另两项部署防护测试发现临时测试配置，移出候选源码后完整重跑57项通过。首次Nginx配置解析错误自动回滚，修复并增加完整预检后发布成功。最后线上营养计算空响应查明为局部import作用域错误，移除多余import，新增HTTP断言，完整Python重跑至732通过，再部署并重跑线上HTTP检查。原始失败记录未当作成功计数。

隔离测试MariaDB与引擎已经停止；正式服务保留运行。Apple真机等未执行项目在EXTERNAL_VALIDATION_PENDING.md。
