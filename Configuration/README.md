# 发布确认配置

ReleaseChecklist.example.plist 是发布确认项模板。复制为 ReleaseChecklist.local.plist，填写实际运营主体与客服渠道；正式确认前保持 LegalReviewed=false。

该文件供 scripts/check-release-ready.py 检查，不是运行时配置，也不会进入 App 包。私有 local 文件不得包含在源码交付包中。
