# Build122 AI 引用与双模型升级交付

日期：2026-10-26（Asia/Shanghai）。版本：0.15.6（122）；App 与 Widget 一致。基线为本聊天交付的 Build121。

本轮已实现记录引用、双模型路由、前置确定性意图、流式/队列提速、后台分配与授权兼容，并部署到117.50.119.49，发布名20261026-build122。用户明确排除的200条专项用例未执行；不以普通检查代替全量业务验收。

## 功能与代码

|功能|最终行为|代码证据|
|---|---|---|
|引用入口与选择面板|五类入口、日期范围、搜索、最多5项，图片最多3张；雾霾蓝与原生组件。|`BojiClub/AIContextReference.swift:71`|
|引用草稿与来源卡|胶囊可移除、可刷新；草稿按账号/会话恢复；发送后的来源卡可展开，相关数据变化隐藏旧快照。|`BojiClub/SharedComposer.swift:61`|
|服务端权威解析|客户端只交对象描述和版本；服务器重载自己的记录，排除未知和未登记值，来源变化/删除拒绝继续使用。|`account-server/public/ai-context.php:85`|
|引用安全存储|AES-256-GCM、30天过期、账号删除级联；来源与会话绑定、同账号也不能跨会话挪用bundle。|`account-server/public/ai-context.php:74`|
|五类详情聊天入口|身体、饮食、当天计划、计划版本、训练总结进入根Club AI；保留旧本场训练上下文兼容。|`BojiClub/AIContextReference.swift:183`|
|DeepSeek + MiniMax|新候选只含deepseek-flash与MiniMax-M3.1-Flash；不再将LongCat/MiMo放入新路由。|`backend/ai_core.py:1210`|
|模型参数分别适配|DeepSeek默认非思考；MiniMax默认low，深入分析high，不发送disabled/none；独立输出长度设置。|`backend/model_router.py:24`|
|按任务路由|普通80/20、引用/提案70/30、复杂与图片50/50；一次选一家；授权/能力/熔断优先，总attempt最多2。|`backend/model_router.py:13`|
|可观察与后台配置|按桶记录P95首正文/完成耗时、失败、tokens；样本足够后小幅调权，后台可调初始比例与关闭路由。|`account-server/admin/ai-router-panel.php:4`|
|前置意图与直接业务|明确查询/开始/恢复/结束/俱乐部进度走确定性解析，沿用持久job、流事件和领域命令，0模型调用；复杂语句一次模型结构化。|`backend/fast_intent.py:8`|
|否定与疲劳防误写|直接命令需核对真实用户原文；否定、条件、疑问及未明确登记不直接写入；未登记组结束沿用确认提案。|`account-server/public/fast-intent.php:28`|
|Streaming与队列|沿用有序持久SSE；内部有界长轮询；两个常驻PHP worker，Python交互预留槽与老任务公平调度；iOS沿用50ms合并更新。|`account-server/process-ai-runs.php:458`|
|按需深入分析|加号和对话选项有深入分析开关，常规快速路径不默认高深度；同一对话返回。|`BojiClub/SharedComposer.swift:85`|
|授权与兼容|旧授权不自动扩大给MiniMax；新说明明确同意、服务端记授权，再放行routing v3；旧v2兼容DeepSeek。|`BojiClub/AIContextReference.swift:213`|
|功能开关与迁移|ai_context_references_v1 / ai_fast_intent_v1 / ai_router_v3，新增三表兼容迁移，旧字段保留。|`account-server/migrate-ai-context.php:7`|
|部署与回退|生产已更新147个业务文件；两模型官方端点连通；常驻worker代替旧聊天timer；回退材料仅留服务器root私有目录。|`scripts/deploy-ai-router122.py:20`|

记录引用支持身体数据/测量、训练场次/范围、饮食单条/当天、某天计划和整套版本/已同步AI候选。候选明确标识未确认采用；计划与实际分开。计划已登记组优先使用开训基线中的目标，目标不存在不将实际值冒充原目标。引用内容和OCR低信任，不授予直接写权限。

来源改变采用更保守的处理：必须刷新并重新核对，避免继续向模型传已撤回内容。引用不是修改授权。旧训练总结入口继续兼容，新通用入口走根Club AI。未同步数据会先同步，失败保留草稿并说明未发送。

## 模型与速度

DeepSeek官方端点：https://api.deepseek.com/chat/completions；model=deepseek-flash。MiniMax当前密钥属于国内平台，国际端点401后已按[官方国内文档](https://platform.minimax.cn/docs/api-reference/text-openai-api)切到https://api.minimax.cn/v1/chat/completions，model=MiniMax-M3.1-Flash，真实调用成功。密钥通过SSH隐藏输入暂存并写服务器私有配置，未写入客户端、源码、测试或报告。

请求按任务分配，保留熔断、能力与授权过滤；相同请求不同时双发。两个模型使用不同思考/输出参数，普通对话预算20秒，复杂60秒，长计划90秒；共享总期限且最多两个候选attempt。新路由记录真实正文首字，不将推理或loading当TTFT。后台能调整分配与查看分桶数据。

真实合成图片+Streaming协议抽查：DeepSeek首正文851ms、完成1023ms；MiniMax首正文1853ms、完成2397ms。**每家仅一次样本，不是App全链P95，也不构成速度保证。** 初始权重没有冒充大规模评测的最优解。价格没有硬编码，当前统计真实usage/tokens，不伪造人民币费用。

明确指令的确定性结果仍走原有持久job与事件链，确保任务恢复、账本及重试一致；业务动作复用同一事务/幂等/版本服务。普通模糊问答、食物纠错、多约束计划仍需要模型理解一次，不靠宽泛正则直接写入。

## 检查与部署

原生92项通过；最后4项引用针对性通过（与92项有重叠，不可相加）。Python52项通过。服务器独立MariaDB/OpenSSL合成库20项检查通过。最终TestFlight配置真机架构未签名编译成功，包含Widget。引用面板做1张模拟器合成预览静态核对，未录视频。

部署后以remote/live-verification.json为准：147文件哈希一致；nginx/php-fpm/AI、两个常驻聊天worker及五个其他timer正常；新引用/授权接口返回401验证保护路由可达；三个新flags开启；五组迁移检查通过。私有持久job与流事件的合成抽查返回deterministic，模型调用为0，无领域业务写入。

服务器仍保存部署备份，配置/数据没有打入交付包。初始Build121→122回退备份：/root/bojiclub-deploy-backups/20261025T180317Z-build122；最终小修备份见remote/deployment-result.json。期间的小修也单独备份，没有覆盖原始回退点。

## 明确保留的验收边界

- 200条专项全部保持NOT_RUN，没有执行其全量真实业务、并发压力、购买、HealthKit、APNs场景。
- 本轮只有少量真实文字/图片/SSE协议检查和一个0模型私有job契约抽查，不能称所有AI业务E2E已通过。
- 未重新验证真实Apple登录、实体机健康写入、购买恢复、通知恢复或完整跨设备用户旅程。
- 未做签名Archive或上传TestFlight；手机界面需要安装新Build122，服务器部署不会替换已安装App。
- 本机PHP未编译OpenSSL，新增加密数据库用例在本机因此失败；未删/跳过用例，已在目标服务器独立MariaDB与真实OpenSSL重跑20项通过，保留原失败日志。

源码根BUILD122_SOURCE_MANIFEST_SHA256.json为当前清单；保留的旧交付报告和manifest仅作为历史材料。源包不包含私有.env、服务密钥、数据库备份、构建缓存或本轮真实用户数据。
