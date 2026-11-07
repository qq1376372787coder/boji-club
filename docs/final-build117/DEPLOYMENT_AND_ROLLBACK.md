# 部署与恢复记录

- 主机：117.50.119.49；RockyLinux10.1 / PHP8.3 / MariaDB10.11。
- 运行路径：`/opt/bojiclub-account`、`/opt/bojiclub-ai`。
- 发布：`20261025-build117`；最终132个业务文件哈希与本地一致（macOS元数据不计入，已按确切哈希清除本次复制的副本）。
- 最终备份：`/root/bojiclub-deploy-backups/20261025T070549Z-build117`。
- 首次成功发布前的旧版本备份：`/root/bojiclub-deploy-backups/20261025T055719Z-build117`；其后备份为中间Build117，不应误当原版本。
- `ai_streaming_v2`、`ai_native_home` 已发布为true，保留其他配置；不强制最低客户端版本。
- 六项timer均active：action-jobs、ai-runs、ai-run-prune、domain-outbox、domain-notifications、domain-reconcile。旧重复outbox timer停用。
- SSE独立池4进程，其他请求继续使用普通池。未宣称大并发容量保证。

## 可重复发布

`scripts/deploy-final-repair.py <stage> --plan` 做完整候选Nginx/PHP-FPM预检与差异计划；`--apply` 加进程锁、正式文件哈希CAS、root私有代码/配置/数据库备份、增量schema迁移、原子拷贝、systemd安装和服务健康检查。stage下须有candidate/account-server与candidate/backend，沿用服务器既有配置。

此脚本针对当前已识别的Rocky/nginx拓扑。首次新服务器或不同目录应调整后再执行。源码里的通用service模板为www-data，本脚本按当前服务器nginx运行账户转换安装。

## 回滚

部署过程中异常会恢复该次备份的代码/服务配置并恢复原timer；保留兼容的增量schema，不破坏性恢复数据库。本轮首次配置错误确实触发ROLLED_BACK，相关记录保留。

如上线后需人工回退，先停止六个timer及对应正在执行的oneshot任务，再停止PHP-FPM/AI；按所选备份manifest中的existing清单逐一恢复files目录中的确切路径、删除本次新增文件，daemon-reload、校验nginx/PHP-FPM、启动服务并按备份timers.json恢复timer。先核对备份日期和版本。不要整目录覆盖media/.env/config.php，不要直接用旧SQL覆盖已有用户的新记录；schema属于加法迁移，可保留。

备份中包含生产数据和凭证，目录0700、敏感文件0600，仅保留在服务器root目录；未纳入交付包。禁止把这些备份公开下载。
