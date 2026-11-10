# 每周身体复盘 0.9.0

入口：首页日历下方「每周身体复盘」。首次创建以当天为复盘截止日，统计包括当天的过去7个自然日，建议范围为之后7天。本周尚未结束的当日数据可能不完整，报告须说明。首次填写本周体重留空，避免把旧档案体重误当成新测量。

## 数据与删除

本机 Application Support/BojiClub/weekly-账号ID：reviews.json 与随机 UUID.jpg。文件启用完整文件保护，目录排除备份。原图只在选图/裁剪过程暂存内存，不写入复盘存储；裁剪后重新生成JPEG，不保留原GPS/EXIF。裁剪位置需要用户确认，不能保证自动定位人脸。

照片可不提交。带照片提交的说明包括本周照片、用户主动勾选的历史照片、MiMo处理、服务端临时任务及结果摘要同步。最多6张，每张550KB；不送通用AIService/cloudJobs，不把图片写进账号云同步JSON。图片任务只路由MiMo，文本任务允许现有备用服务。

账号API `/account/v1/me/weekly/jobs/<客户端UUID>` 支持POST/GET/DELETE。PHP通过账号会话验证用户，用user ID+客户端ID经HMAC映射为服务端任务ID；内部owner token只保存在服务器config.php。公开AI开发会话不能提交、查询、重试或删除weekly_review任务。

服务端只在排队和重试期间保存上传内容，成功或最终失败清除payload；超过24小时的排队/重试任务过期清除。删除写入无内容tombstone，晚到的POST不能复活。Worker完成及失败不会覆盖deleted状态；SQLite启用secure_delete。第三方模型已收到的内容不能撤回，磁盘备份/供应商保留不等于已从所有副本物理抹除。删除账号摘要使用现有账号同步，离线可能需要后续重试。

本地照片删除前验证随机文件名格式，防止从同步数据引用任意路径。卸载App/更换手机不能恢复照片。云端返回的历史摘要仍能查看。

## 计划规则

报告字段：summary/training/nutrition/recovery/appearance/photoFeedback/decision/reason/notes/sessions。decision为keep/adjust/insufficient。用户报告疼痛或状态不明时强制停止调整。少于2天完成记录，或建议总组数超过原记录计划组数的1.2倍，降级为资料不足。该数值是产品保守限制，不表示通用医学阈值。

新建议重量一律为空，用户预览时确认。App把未设置重量显示为0，提示自重/未设置区别。用户可逐组修改重量次数、选择应用哪些训练日。当前版本保持建议动作与组数；若要替换动作可在应用后通过训练页调整。原计划快照保留在复盘摘要，应用时比较最新日历快照；只改未来日期、只替换所选日期、拒绝覆盖已有完成组。未选择的旧训练日不会自动删掉或转成休息日。

## 本机提醒

用户选择星期，19:00本机通知，需系统授权，不创建外部自动化。退出账号移除该账号待发提醒。本周跳过时延后，预排后续8次，重新进入账号后按设置继续安排。系统关闭权限时不会保证送达。

## 运维

新增 backend/weekly_core.py；更新ai_core.py、server.py。账号侧public/index.php引入public/weekly.php，必须一起部署。新增admin/weekly-summary.php，入口页面引用它。work/deploy_weekly.sh完成备份、PHP/Python语法检查、私密代理配置、安装并重启AI服务；配置失败或服务不能启动时不应视为交付完成。

测试脚本 work/check_weekly_review.py 使用合成记录和本地HTTP服务，无供应商调用、无真实身体照片。work/check_weekly_public.py使用临时账号确认HTTPS鉴权、跨账号隔离、删除与原账号接口兼容，结束时清理临时账号及任务。

尚需Mac/iPhone验收：Xcode编译、摄影叠影与倒计时、拒绝相机/通知权限、照片裁剪、应用重启恢复查询、带图模型反馈、两台设备同步冲突、删除与计划应用。没有宣称本轮已完成以上真机验证。SwiftUI仍沿用黑白配色。
