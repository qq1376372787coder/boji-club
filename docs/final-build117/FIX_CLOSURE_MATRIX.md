# 缺陷关闭与补齐矩阵

VERIFIED 仅表示列出的代码/测试层级通过；外部设备与专业审阅见单独清单。

|编号|问题|本次状态/处理|代码位置|证据|
|---|---|---|---|---|
|RA-01|取消后领域写入|VERIFIED：事务内父Run栅栏；统一锁顺序|`account-server/public/action-support.php:22`|race-inspect.txt、php-suite-final/test_final_repair.log|
|RA-02|模型冒认营养来源|VERIFIED：模型不授信；质量/来源/误差分离，原生编辑使旧来源失效|`backend/food_core.py:10`|local/python-final.log、remote/final-engine-smoke.json|
|RA-03|补偿覆盖后续更改|VERIFIED：原操作指纹、预览及提交双校验；补齐长期计划/模板/偏好逆向版本|`account-server/public/action-compensation.php:47`|php-suite-final/test_final_repair.log|
|RA-04|严重喘息给积极训练建议|VERIFIED：急症优先、模型入口提前拦截；特殊情况/评估失败保守处理|`backend/fitness_intelligence.py:280`|local/python-final.log、remote/final-engine-smoke.json|
|RA-05|不同器械重量混合进阶|VERIFIED：解析唯一变体；过滤取消/未保存会话；确认来源及确定性负重边界|`account-server/public/ai-router.php:519`|php-suite-final/test_final_repair.log、local/python-final.log|
|RA-06|HTTP错误触发第二提交通道|VERIFIED：明确不支持才回退；5xx保留不确定身份，409/429不换通道|`BojiClub/AIRunStream.swift:269`|local/xcode-unit.log|
|RA-07|事件清理未调度|VERIFIED：独立清理service/timer已安装运行|`account-server/deploy/bojiclub-ai-run-prune.timer:4`|remote/final-live-verification.json|
|RA-08|批量领取超过租约与服务时限|VERIFIED：服务显式每次领取1项，部署适配nginx运行账户|`account-server/deploy/bojiclub-ai-runs.service:10`|remote/final-live-verification.json|

补充：真正逐段流已通过真实供应商+原worker+HTTP链；生产食品数据与查库能力已落地；长期计划补偿的keep_date/模板/偏好与再补偿通过真实MariaDB事务用例；Run接受消息故障注入保证事务原子性。

历史 IA-01～13 的失败项已由上述修复覆盖，原有SQL/Outbox/权限/幂等/trace用例包含于57套件。记忆质量、主动通知的实际设备触达、跨网络恢复体验和后台管理浏览器交互仍不提升为全面实机 VERIFIED。
