# Build119 修复交付报告

版本：0.15.3（119），2026-10-25。基于用户提供的 Build118 完整源码，在独立目录修复；原包未改。

本轮独立核实的14组缺陷均已修复，并补上AI资料变更工具卡、提案恢复/拒绝、任务切换、无身体数字的训练计划、离线复核和饮食草稿竞争保护。不能据此宣称所有真实设备、真实供应商场景已通过。

## 已修复缺陷

|编号|优先级|原问题|修复及代码证据|验证|
|---|---|---|---|---|
|B118-01|P1|新账号创建引导500|stdClass改为领域数组，JSON边界再输出对象。 `account-server/public/profile-facts.php:131`|http-repair.json fresh_create；php-repair.log|
|B118-02|P1|预览/确认闭包遗漏幂等key|所有需要key的事务闭包显式捕获。 `account-server/public/onboarding-v2.php:515`|HTTP preview/confirm；同key同回执/异payload409|
|B118-03|P1|已确认字段仍重复追问、计划永远未就绪|仅向字段规则传递facts，恢复正确缺项与就绪状态。 `account-server/public/onboarding-v2.php:399`|HTTP confirm plan_ready=true、required_missing_fields=[]|
|B118-04|P1|清除资料后被旧同步复活|新增撤回标记表；只有新的明确确认才能恢复被撤回字段。 `account-server/public/profile-facts.php:281`|php-repair.log：清除后重放legacy import|
|B118-05|P1|旧预览覆盖新草稿|绑定提案原始会话版本及资料版本，冲突409保留后续修改。 `account-server/public/onboarding-v2.php:568`|php-repair.log stale-confirm|
|B118-06|P1|无关成功命令冒充计划采用|校验归属、会话关联、任务类型及真实云端采用记录；pending同key可推进。 `account-server/public/onboarding-v2.php:782`|php-repair.log wrong-command、pending_sync→committed|
|B118-07|P1|资料与同步状态投影不原子|统一事务更新事实、旧资料、app_states版本与cloud_parts.meta。 `account-server/public/profile-facts.php:438`|php-repair.log：数据库触发器故障回滚、分片保留验证|
|B118-08|P1|显著不适漏拦截及否定句误判|补齐已复现的呼吸困难表达和显式否定处理；生成入口再次执行服务端防护。 `account-server/public/profile-facts.php:351`|php-repair.log：严重喘息、无胸痛|
|B118-09|P2|任务分页、业务状态及轮询状态错误|修复过滤顺序、50条截断、同秒跨类型游标、采用状态及同步失败优先级；查询实际任务元信息，暂不可用标为unknown。 `account-server/public/task-center.php:61`|php-repair.log：55条分页、同秒三类型分页、列表/详情采用状态|
|B118-10|P2|引用上下文不参与幂等身份|保留来源类型、ID和版本进入请求哈希。 `account-server/public/ai-runs.php:36`|php-repair.log context source；ai-runs.log|
|B118-11|P2|失败丢输入、重试更换身份、离线恢复缺失|提交前保存受保护账号级日志；固定payload身份；网络未知保留pending、冲突转复核；输入成功后才清空。 `BojiClub/OnboardingV2.swift:891`|xcode-final.log：幂等身份、账号隔离；静态核验重放入口|
|B118-12|P2|已有Run测试重复include而崩溃|修复为require_once，完整保留原测试断言。 `tests/test_ai_runs.php:24`|ai-runs.log AI_RUNS_OK|
|B118-13|P1|实际发布脚本遗漏新表迁移|将候选版本V2迁移加入发布前检查与执行；检查真实列类型/空值/索引/外键，并在apply后复核。 `scripts/deploy-final-repair.py:61`|php-repair.log：fresh/check/apply/repeat/三类漂移；部署脚本仅静态及语法检查|
|B118-14|P1|新用户默认28/175/68被当作已知事实|新资料默认unknown；历史JSON缺元数据保持兼容；旧备用表单必须实际填写并确认，计划只传已知事实。 `BojiClub/Models.swift:352`|xcode-final.log fresh/legacy/unknown tests；HTTP无编造年龄|

## 补齐的功能和边界

- F07：`profile.preview_change`贯通服务端工具注册、运行时schema、预览卡、显式确认/暂不采用和任务中心找回。确认资料不会自动改训练日历；未来计划仍独立预览与确认。`account-server/public/ai-router.php:437`、`BojiClub/AICards.swift:643`。
- 首句选择对应任务，可切换任务并保留各任务草稿；预览原ID随状态恢复。`BojiClub/OnboardingV2.swift:83`、`account-server/public/onboarding-v2.php:849`。
- 新版训练条件满足即可生成训练计划，不再为此强制补齐体重/身高；服务端重建资料载荷，选用称重必须匹配实际记录。`BojiClub/Models.swift:353`、`account-server/public/profile-facts.php:466`。
- 整餐明确半份/四分之一可直接更新待核对草稿；组件份量与整餐食用比例分离。改名仍重新估算并清除旧信任；异步结果核对完整草稿快照与账号，避免覆盖后续编辑。`BojiClub/MealEditorView.swift:253`、`backend/ai_core.py:1179`。
- 清除标记纳入导出，外键级联删除。恢复文件账号隔离、文件保护、禁止备份，不存token。`account-server/public/export.php:72`、`BojiClub/OnboardingV2.swift:891`。
- 新增 `user_profile_tombstones`，已有表不破坏性重建；不兼容schema会非零退出，禁止假报APPLIED。新增资料提案读取/拒绝接口；新增提示词 `boji.draft_correction.v2` 并更新SHA。

## 实际验证

|检查|最终结果|证据|
|---|---|---|
|iOS Debug模拟器完整单元测试|79项，0失败；主App/Widget编译通过|evidence/fixed119/xcode-final.log|
|MySQL8.4真实事务、投影、迁移及业务回归|55项通过|evidence/fixed119/php-repair.log；源码tests/test_build119_repair.php|
|Python契约与引擎回归|84项，0失败|evidence/fixed119/python-final.log|
|真实本地PHP HTTP（合成用户）|17项通过|evidence/fixed119/http-repair.json、http-repair.log|
|已有AI Run数据库回归|AI_RUNS_OK，未删除失败断言|evidence/fixed119/ai-runs.log|
|改动PHP语法/改动Python编译/共享JSON|13个PHP文件通过；Python和JSON通过|evidence/fixed119/php-lint-final.json|

原包曾出现：PHP缺filter/ctype导致环境500、扩展构建缺autoconf、一次Python启动缺tests模块路径；这些均按环境问题纠正后重跑。原包Run测试重复include属于真实测试代码缺陷，已修复。早期修复过程的Swift编译错误已修正，最终79项全部通过。没有删除或跳过失败的业务断言来取得通过。

## 外部验收与交付边界

- 未部署服务器、未调用真实付费模型、未支付/恢复真实订阅、未上传TestFlight、未读取生产数据。
- HealthKit增删、StoreKit/RevenueCat购买、APNs点击恢复、第三方音频/后台计时、实体设备液态玻璃/动态字体/降低透明度，以及真实模型全链，仍需真实设备和隔离测试账号；这些标为PARTIALLY VERIFIED或UNKNOWN，不能用合成数据代替验收。
- 日历/动作/营养原有确定性规则保留；本次安全修复针对可复现的表达，关键词规则不能证明所有自然语言症状均可识别。
- 任务中心保留原90天窗口，修复错误截断与游标；本轮没有进行大规模负载验收。
- 旧版交付报告与manifest仍属历史材料；以本目录报告及SOURCE_MANIFEST_SHA256.json为本次依据。

完整验收矩阵见 ACCEPTANCE_MATRIX_UPDATED.csv。完整修复差异见 CODE_DIFF.patch、SCHEMA_DIFF.patch；部署/回退建议见 RELEASE_GATE.md。
