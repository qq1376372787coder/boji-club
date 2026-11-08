# 发布确认配置

ReleaseChecklist.example.plist 是发布确认项模板。复制为 ReleaseChecklist.local.plist，填写实际运营主体与客服渠道；正式确认前保持 LegalReviewed=false。

## 字段说明（scripts/check-release-ready.py 消费）

| 键 | 作用 |
|---|---|
| `OperatorName` / `SupportContact` | 运营主体与客服渠道，空则门禁不通过 |
| `LegalReviewed` | **必须为 `true`** 才放行（法务复核完成的书面确认） |
| `PrivacyPolicyURL` | 隐私政策公开地址，门禁会真实请求该 URL 校验 HTTP 200（缺省 `https://bojiclub.fun/doc/privacy`） |
| `TermsURL` | 可选；填写后同样做可访问性校验 |

法律文本正文的唯一真源是 `legal-site/seed/<lang>/*.md`（Build 139 起，旧 `legal/` 目录已不再存放协议正文）。

该文件供 scripts/check-release-ready.py 检查，不是运行时配置，也不会进入 App 包。私有 local 文件不得包含在源码交付包中（已由 `.gitignore` 拦截）。
