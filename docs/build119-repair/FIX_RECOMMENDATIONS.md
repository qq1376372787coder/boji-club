# 后续接手说明

本次已实现代码修复，不是待执行开发建议。请先阅读 BUILD119_REPAIR_REPORT.md 与 CODE_DIFF.patch；不要用历史Build118报告覆盖本次结果。

源码关键入口：
- `account-server/public/onboarding-v2.php:61`：锁账号、payload哈希幂等、领域事务。
- `account-server/public/profile-facts.php:438`：事实与同步投影。
- `BojiClub/OnboardingV2.swift:891`：受保护离线日志与同身份重试。
- `account-server/public/ai-router.php:437`：AI只生成资料提案，不能代替用户确认。

新增接口：GET /me/profile-facts/proposals/{id}；POST /me/profile-facts/dismiss；既有preview/confirm/clear保持。资料与未来计划分开确认，失败后不能把部分成功写成全部完成。

后续验收重点：用隔离账号验证真实模型输出、多字段追问、首次计划创建/导入/采用及重启；真实iOS视觉辅助设置；StoreKit/HealthKit/APNs/音频后台；不要将本地合成用例视作这些外部验收。
