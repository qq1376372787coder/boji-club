# 重放与检查命令

在独立解压的源码根目录运行，PHP8.3需pdo_mysql、mbstring、filter、ctype。MySQL只用可丢弃测试实例。测试会创建/重置 boji_build119_repair_test、boji_build119_migration_test；不要配置到生产。

```sh
BOJI_TEST_DSN_BASE='mysql:unix_socket=/path/to/isolated-mysql.sock' php tests/test_build119_repair.php
PYTHONPATH=tests:backend python3 -m unittest tests.test_onboarding_v2_contract tests.test_final_repair tests.test_capability_calls tests.test_intelligence_engines tests.test_multi_meal
BOJI_TEST_DSN_BASE='mysql:unix_socket=/path/to/isolated-mysql.sock' php tests/test_ai_runs.php
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO -only-testing:BojiClubTests test
```

最终测试证据来自本机自建iPhone17/iOS26.5模拟器、Xcode Debug、PHP8.3.12与MySQL8.4，依赖使用本机缓存；命令的完整绝对路径见日志。

关键原包复现/修复预期：

1. 全新无资料账号POST /me/onboarding/v2/sessions，plan_create：原500；修复200、未知身体资料仍空。
2. PATCH明确训练条件，POST profile-preview，再GET状态：原预览失败；修复返回proposal_id，重载保持同一ID。POST profile-confirm后plan_ready=true、missing=[]。同幂等key重放同回执，变payload409。
3. 预览后再PATCH新草稿，尝试携带最新会话版本确认旧proposal：原可覆盖；修复409，后续草稿保持。
4. profile_weight_kg先明确确认后清除，再重放legacy云资料：原字段复活；修复撤回标记持续生效，只有显式新确认能恢复。
5. 向app_states UPDATE注入真实数据库错误：修复事实版本/提案回执/投影一起回滚。分片用户meta更新、days及appliedAIJobs保持。
6. 使用BodyWeight成功命令作为计划采用凭证：原错误接受；修复409。无云采用记录pending_sync；云同步后同key可推进committed。
7. 同用户55条任务分20条遍历，必须55条；三种类型同秒更新分1条遍历，必须3条无重无漏。同步失败优先显示需处理；计划已采用在列表/详情一致。
8. /me/profile-facts/proposals/{id}外账号404；明确dismiss后confirm409；过期确认410；含confirmed等信任字段或重复字段422。
9. 新MemberProfile与真实旧JSON分别测试：新资料默认unknown；旧有效资料兼容；draft/model_candidate不等于confirmed。整餐半份保持原组件营养，consumed_fraction单独校验，单个食物半份不能被误判为整餐比例。
10. 迁移：空库check2/apply0/check0/repeat0；删除facts_json、索引、归属外键均check2；apply不得假报成功。

原包SSE事件游标、同Run重放与跨账号、12并发引导预算测试另有original118证据。修复版Run数据库回归重跑通过；未把它冒称真实模型/弱网实体设备全链。
