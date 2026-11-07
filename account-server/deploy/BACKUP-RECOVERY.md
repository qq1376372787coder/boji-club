# 全恢复备份与恢复演练（FIX-009 / AUD-009）

## 覆盖范围

`backup.py` 的必需清单（缺失即失败，不会生成“看似成功”的备份）：

- `/opt/bojiclub-account`（源码、配置、媒体、私有 RevenueCat/APNs 配置）
- `/opt/bojiclub-ai`（源码、供应商配置、SQLite 任务库；SQLite 使用 `backup()` 一致性快照）
- `/etc/bojiclub/apple-signin.p8`（Apple 登录私钥；此前遗漏）
- `/etc/nginx`、`/etc/php-fpm.d/www.conf`
- systemd：AI、账号注销、备份、自动跟进、推送、IP 证书续期（存在即打包）
- MySQL：`mysqldump --single-transaction --routines --triggers`

`recovery-manifest.json` 记录每个文件/目录的类型、权限、大小与关键文件 SHA256；`database.sql`、`ai-jobs.sqlite3` 也记录哈希。

## 密钥边界

- 备份密码从仅 root 可读的 `backup-password` 读取，**不会写入归档、清单、日志或结果 JSON**；只记录 `key_fingerprint`（SHA256 前 16 位）用于核对。
- 必须在站外另行保管同一密码；丢失密码无法恢复。
- 归档使用 AES-256-GCM + scrypt（n=32768, r=8, p=1）。失败即不落盘或保留旧归档。
- 保留最近 14 份；站外复制通过 `BOJI_OFFSITE_CMD`（如 rclone/restic）执行，结果只记录 ok/failed，不记录命令或凭据。

## 定时与双调度

- `bojiclub-backup.service` + `.timer`：每日 03:17（本地时区）+ 5 分钟随机延迟。
- 自动跟进/推送提供 systemd unit，但**不得与现有 Cron 同时启用**；部署前用 `systemctl list-timers` 与 `crontab -l` 二选一。
- 备份 unit 只写 `/root/bojiclub-rebuild-v59` 与 `/root/bojiclub-backups`。

## 恢复演练（隔离目标机）

```bash
python3 backup.py --dry-run          # 只读检查清单覆盖
python3 restore.py <archive>         # 校验格式、密码、清单、路径安全
python3 restore.py <archive> --apply --target /srv/recovery-drill
```

`--apply` 只解压到**新的空目录**，不会启动服务、不会覆盖生产。随后人工执行：

1. 安装 systemd unit，`systemctl daemon-reload`，按既有调度二选一启用。
2. 恢复 MySQL 与 AI SQLite，核对表/行数与备份记录。
3. 核对 `/etc/bojiclub/apple-signin.p8` 权限（0600，属主 root）。
4. 用合成账号验证登录、注销、自动任务和推送。
5. 记录恢复耗时与数据窗口，再决定是否切换流量。

## 本地演练记录

2026-10-18 在 macOS 隔离目录完成：dry-run 10/10 必需路径；生成 8.6 KB 加密归档（17 个成员）；`restore.py` 校验通过并解压出 `database.sql`、`ai-jobs.sqlite3`、Apple 私钥条目与备份 timer。未使用生产数据、未启动生产服务。完整空白主机恢复仍需独立目标环境。
