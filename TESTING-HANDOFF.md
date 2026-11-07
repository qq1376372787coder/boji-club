# 测试交接说明（BOJI CLUB V2 — 2026-10-25 交付）

本包为 Phase 0-5 全量源码（git 主干 5f22fb8）。上一 agent 已完成的验证与
**本次明确未做的大规模测试**都在 docs/v2/evidence/phase2/README.md 与
docs/v2/04_PHASED_IMPLEMENTATION_PLAN.md §7。

## 固定回归命令集（按顺序执行）

1. Python 离线：`python3 -I tests/run_offline.py`（上测 672/672）
2. Swift 规则回归链：`python3 tests/run_swift_regressions.py --output /tmp/boji-rules --jobs 3`（上测 52/52）
3. 编译：`xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build`
4. iOS 单测：`xcodebuild ... test -only-testing:BojiClubTests`（上测 34/34）
5. UI 全量：`xcodebuild ... test`（上测 31/31；已知 testCompositionAccessibilityWorkoutAndNutrition 偶发滚动抖动，单跑复核即可）
6. PHP 套件（需 PHP8.3+pdo_mysql+可弃 MySQL，或服务器）：`OPENSSL_CONF=/etc/ssl/openssl.cnf BOJI_TEST_DSN_BASE='mysql:unix_socket=<sock>' bash tests/run_php_suite.sh`（服务器上测 43/43）

## 本次新增、**尚无专项测试**的重点（优先补测）

- insights.php 评分排序（score 公式/同类去重/俱乐部事实）
- weekly.php 新端点：POST /me/ai/feedback（批量上限/认证/kind 区分）、coach 日配额（AI_COACH_DAILY_LIMIT=100）
- ai_usage_ledger 中继延迟记录
- 客户端：ClubProposalSync.confirmDraftCard、AccountService.trackEvent 三个发射点、ClubAIMemoryView 成员控制 UI、主动程度三档 Picker

## 生产状态

- 服务器 117.50.119.49 已部署至本包同版本；迁移 M-1/M-2/M-3 + ai_feedback_events/
  ai_usage_ledger 已应用（SCHEMA_OK）；RELEASE-*.txt 哈希留档。
- 测试库跑法（服务器 root socket）：`BOJI_TEST_DSN_BASE='mysql:unix_socket=/var/lib/mysql/mysql.sock'`。
- 注意：UI 测试间共享模拟器 App 状态——新卡测试收尾必须结束训练（见 testV2CoachCardStartsTraining 注释）。
