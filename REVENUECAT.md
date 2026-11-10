# RevenueCat 接入与验收

2026-10-02 第二轮修复版。

App 以 `boji-<内部用户 ID>` 登录 RevenueCat，会员权益 ID 为 `club_member`。服务端是最终授权依据；缺少 SDK Key 时，App 会显示配置问题并保持会员门禁。

## 两个商品

| Product ID | 订阅周期 | 产品目标价格 |
| --- | --- | --- |
| bojiclub_halfyear_2990 | 6 个月 | ¥29.9 |
| bojiclub_yearly_4290 | 12 个月 | ¥42.9 |

实际展示价格采用 App Store 返回的本地化价格。App Store Connect 必须建立对应产品；RevenueCat current Offering 同时绑定 sixMonth / annual Package，并关联 `club_member`。

## 正式配置

1. 在 Apple Developer / App Store Connect 完成 App ID、登录能力、订阅与 In-App Purchase Key 配置。
2. 在 RevenueCat 完成 iOS App 与商店关联，确认产品和 Offering。
3. 将 iOS 公共 SDK Key 填入 Xcode 的 `REVENUECAT_PUBLIC_SDK_KEY`；源码仍为空，不应填写 Secret API Key。
4. Webhook 地址为 `https://api.gongxiang.cloud/account/v1/webhooks/revenuecat`。在 RevenueCat 填入与服务器 config.php 完全相同的 Authorization Header。已在服务器生成该值，未放入修复包或报告。
5. 将 RevenueCat App ID 填入服务器 `revenuecat_app_id`；当前此项为空，产品与环境过滤已启用，精确 App ID 过滤待完成。

```php
'revenuecat_product_ids' => ['bojiclub_halfyear_2990', 'bojiclub_yearly_4290'],
'revenuecat_environment' => 'PRODUCTION',
'revenuecat_app_id' => '填写 RevenueCat 后台实际 App ID',
'membership_enforcement' => true,
```

正式服务器已启用会员校验并仅接受 PRODUCTION 事件。Sandbox 购买应使用独立测试环境和数据库，将该环境设置为 SANDBOX；不要关闭正式授权或把沙盒权益写入正式账号。

## 已验证与待验证

隔离 MariaDB 已验证交易写入、重复事件、乱序到期、退款、同时间戳退款优先、多订阅及管理员赠送权益；未知产品/错误环境不授予会员。另外已用合成事件验证扣款宽限、账号转移、赠送叠加与转移后的旧账号清理。App 已增加购买后有限等待、重新查询、商品加载失败重试和到期后的账号管理入口。

真实 Apple 登录、Sandbox 购买、恢复购买、续费、退款、Webhook 控制台投递以及账号迁移/TRANSFER 等完整商店流程仍需平台配置与真机验收。不能用合成测试代替真实购买验收。

## 0.13.17 修复补充

购买、恢复和刷新共用操作锁；重新查询会主动拉取当前环境的商店状态，再查询服务端。前台恢复和 CustomerInfo 更新会刷新会员信息。商品加载超过 12 秒会给出重试提示，过时回调不能覆盖新的请求；这不改变仍在处理中的购买。

TRANSFER 的 environment 属于官方可选字段，缺少时只迁移此前已通过环境／商品策略的服务端记录。明确 SANDBOX 和不匹配的 App ID 仍被过滤；重复事件幂等，旧账号权益重新计算。

注销旧账号会级联删除原订阅行。没有可转移记录时不再将恢复假报为完成，也不写入成功事件，Webhook 保留重试。重建这类订阅仍需要 RevenueCat 服务端读取权限和权威查询流程，当前未完成。不可通过客户端传来的会员标记直接授予权益。

字段依据：https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
