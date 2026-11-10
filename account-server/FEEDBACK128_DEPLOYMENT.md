# 用户反馈 Build128 部署

新增三张 member_feedback_* 表；先执行 migrations/20261026-member-feedback128.sql（仅 CREATE TABLE IF NOT EXISTS），再安装 public/member-feedback.php、public/index.php、public/export.php 及 admin/member-feedback.php、bootstrap.php、index.php、style.css。

当前服务器 Rocky Linux 10 使用 php-fpm 与 /run/php-fpm/www.sock。反馈上传路径 /account/v1/me/feedback/attachments/ 需独立 Nginx location，client_max_body_size 22m、fastcgi_read_timeout 180s；其余 API 与 SSE 规则保留。模板中的 PHP socket 需对应实际部署。

依赖：PHP pdo_mysql、mbstring、fileinfo、GD，以及 /usr/bin/ffprobe 和 /usr/bin/ffmpeg。GD 重新编码 JPEG；ffprobe 校验视频，ffmpeg 仅复制 H.264/AAC 轨道并移除普通容器元数据，限制 file/pipe 协议和禁止外部轨道引用。视频最长 60 秒、20 MB；图片 3 MB；每消息 4 个附件、账号反馈媒体总量 300 MB。

Rocky 的 noopenh264 是占位库，不能用于真实 H.264 校验。实测使用官方 Fedora Cisco OpenH264 EPEL 10 仓库安装 openh264 替换占位包，启用 GPG 校验，未关闭签名校验。参考：https://fedoraproject.org/wiki/OpenH264 ，仓库：https://codecs.fedoraproject.org/openh264/epel/10/x86_64/ 。当前环境命令：

```sh
dnf install -y ffmpeg-free php-gd
dnf --repofrompath=boji-cisco-openh264,https://codecs.fedoraproject.org/openh264/epel/10/x86_64/ --setopt=boji-cisco-openh264.gpgcheck=1 --setopt=boji-cisco-openh264.gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-10 -y swap noopenh264 openh264
```

模块已接入原有用户登录、管理员 Session/CSRF/RBAC、管理员审计、账号数据导出和注销清理。媒体位于账号私有 media/{user_id}/feedback128/ 目录，不生成公共链接，不进入 AI 请求或训练/饮食记录。未提交附件和进程中断遗留文件超过 24 小时后，在该账号下次上传时清理。

测试仅针对 disposable boji_feedback128_test 数据库和 localhost:18928，绝不对生产库运行 tests/test_member_feedback128_storage.php。HTTP 测试中使用自生成的纯色视频和图片，未上传真实用户资料。
