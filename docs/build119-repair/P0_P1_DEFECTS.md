# P0/P1缺陷关闭清单

本轮未确认P0；原包确认以下P1。CLOSED表示修复及所列局部回归成立，不代表外部全链验收完成。

## B118-01 CLOSED — 新账号创建引导500

stdClass改为领域数组，JSON边界再输出对象。 `account-server/public/profile-facts.php:131`。证据：http-repair.json fresh_create；php-repair.log。

## B118-02 CLOSED — 预览/确认闭包遗漏幂等key

所有需要key的事务闭包显式捕获。 `account-server/public/onboarding-v2.php:515`。证据：HTTP preview/confirm；同key同回执/异payload409。

## B118-03 CLOSED — 已确认字段仍重复追问、计划永远未就绪

仅向字段规则传递facts，恢复正确缺项与就绪状态。 `account-server/public/onboarding-v2.php:399`。证据：HTTP confirm plan_ready=true、required_missing_fields=[]。

## B118-04 CLOSED — 清除资料后被旧同步复活

新增撤回标记表；只有新的明确确认才能恢复被撤回字段。 `account-server/public/profile-facts.php:281`。证据：php-repair.log：清除后重放legacy import。

## B118-05 CLOSED — 旧预览覆盖新草稿

绑定提案原始会话版本及资料版本，冲突409保留后续修改。 `account-server/public/onboarding-v2.php:568`。证据：php-repair.log stale-confirm。

## B118-06 CLOSED — 无关成功命令冒充计划采用

校验归属、会话关联、任务类型及真实云端采用记录；pending同key可推进。 `account-server/public/onboarding-v2.php:782`。证据：php-repair.log wrong-command、pending_sync→committed。

## B118-07 CLOSED — 资料与同步状态投影不原子

统一事务更新事实、旧资料、app_states版本与cloud_parts.meta。 `account-server/public/profile-facts.php:438`。证据：php-repair.log：数据库触发器故障回滚、分片保留验证。

## B118-08 CLOSED — 显著不适漏拦截及否定句误判

补齐已复现的呼吸困难表达和显式否定处理；生成入口再次执行服务端防护。 `account-server/public/profile-facts.php:351`。证据：php-repair.log：严重喘息、无胸痛。

## B118-13 CLOSED — 实际发布脚本遗漏新表迁移

将候选版本V2迁移加入发布前检查与执行；检查真实列类型/空值/索引/外键，并在apply后复核。 `scripts/deploy-final-repair.py:61`。证据：php-repair.log：fresh/check/apply/repeat/三类漂移；部署脚本仅静态及语法检查。

## B118-14 CLOSED — 新用户默认28/175/68被当作已知事实

新资料默认unknown；历史JSON缺元数据保持兼容；旧备用表单必须实际填写并确认，计划只传已知事实。 `BojiClub/Models.swift:352`。证据：xcode-final.log fresh/legacy/unknown tests；HTTP无编造年龄。
