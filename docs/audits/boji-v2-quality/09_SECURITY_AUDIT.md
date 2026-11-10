# 安全与权限审计

## 1. 已确认并修复

| 项 | 风险 | 修复 | 验证 |
|---|---|---|---|
| Apple identity token 重放 | 截获 `(identity_token, nonce)` 可在 exp 前反复换取会话 | `apple_auth_nonces` 一次性 nonce（10 分钟）；重复返回 401 | 迁移已应用；完整签名 token 的 HTTP 重放测试仍缺（需 Apple 夹具） |
| 会员权益跨账号覆盖 | 全局唯一交易号 + `ON DUPLICATE KEY UPDATE` 可把 A 的权益改成 B | 去掉 `last_transaction_id` 全局唯一；迁移；两账号同交易号测试 | **通过** |
| 管理员无权限隔离 | 任意管理员可发实物、改会员、换 AI 密钥 | 5 角色 RBAC；页面/动作双校验；服务端 403 | HTTP 3 角色矩阵通过 |
| 管理员账号枚举 | 不存在的用户名跳过 `password_verify` | dummy hash；IP+用户名/用户名双桶限流 | 登录 HTTP 测试通过 |
| 俱乐部全局锁 DoS | 锁内调用 AI HTTP，可阻塞全部申领 | 进度计算移到锁外 | 代码审计；无生产并发压测 |
| 后台“测试发送”假成功 | 只写队列，不发送，误导运营 | 真实单成员 APNs；失败记录 | 无 APNs 配置，未做真实送达 |
| 配置生效不透明 | 后台保存与 App 行为无证据链 | 发布版本 + 公开端点 + 服务端 gate | HTTP/ETag/开关测试通过 |
| 删除审计 | 用户注销会删除 admin_audit | 脱敏保留 | 代码审计 |
| 隐藏按钮当权限 | 仅 UI 过滤 | 服务端 `requireAdminPage`/`requireAdminWrite` | HTTP 403 |
| 供应商密钥无法清除 | 泄露后只能停用 | `clear_key` + 轮换重置熔断 | 单元验证/代码审计 |

## 2. 现有控制（已验证）

- **会话**：管理员 `HttpOnly + Secure + SameSite=Strict` Cookie；`session.use_strict_mode`；30 分钟无操作/12 小时绝对过期；改密/停用/改角色使 `session_version` 失效。
- **CSRF**：所有管理员 POST 使用 32 字节随机 token + `hash_equals`；CSP `form-action 'self'`。
- **输出编码**：后台统一 `h()`；未发现直接拼接用户输入的 HTML。
- **SQL**：后台查询使用 prepared statement；LIMIT/OFFSET 使用整数；本轮未发现新的注入点。
- **普通用户/管理员隔离**：管理员入口 `/admin/` 独立会话与表；普通 App token 不能调用 admin；公开 `/config` 只读白名单。
- **AI 密钥**：只在 PHP `config.php`/Python 环境；后台只显示后缀/配置状态，不回显完整 Key。
- **AI 私有接口**：绑定 127.0.0.1、Bearer token 常量时间比较、禁用重定向、无 CORS。
- **文件**：媒体 ID 限定 UUID；JPG 魔数校验；路径 basename 校验；`nosniff`。
- **RevenueCat**：webhook Authorization 校验、事件去重、事务、商品/环境/App ID 过滤、跨账号转移保护（既有测试）。
- **注销**：持久队列、失败重试、AI owner 擦除、Apple token 撤销、会话删除。

## 3. 仍开放的安全风险

| 风险 | 严重度 | 说明 | 建议 |
|---|---|---|---|
| 实物奖励资格可伪造 | **P1** | Club 训练/饮食/健康天数来自同步状态；无 App Attest/DeviceCheck | 设备证明/服务端可验证指标/人工核验策略；在完成前限制高价值实物发放 |
| 远程推送无 entitlement | **P0（发布）** | 客户端无法注册 APNs token；服务端配置再正确也无法送达 | Apple Developer 开启 Push Notifications，补 `aps-environment`、Provisioning、APNs Key，真机验证 |
| Bundle ID/APNs topic 不一致风险 | **P0/P1（发布）** | TestFlight/Release 使用 `.dev`；若正式 App 非此 ID，登录 audience/推送/商品/App Group 不一致 | 与 App Store Connect 核对并统一；不要仅改代码字符串 |
| 管理员无 2FA | P2 | 强密码 + 限流，但无第二因素 | 高权限账号加 TOTP/Passkey；至少限制 IP/设备 |
| 会员权益仍依赖 RevenueCat/Apple 配置 | P1（业务） | 代码无法替代商店结算；当前未做 Sandbox 实测 | 完成购买/恢复/退款/续期/重复 webhook 的 Apple 侧验收 |
| 媒体墓碑并发 | P2 | 已确认上传/删除锁顺序风险 | 设计提交协议/版本化墓碑；加入并发测试 |
| 法律/隐私 | **P0（发布）** | 文件是草案，`LegalReviewed=false`，运营主体未填 | 法务审核、公开 URL、App Store Connect 隐私答案 |
| AI 输出内容安全 | P2 | 规则已加强，但仍是生成式内容；无医疗诊断边界的外部审核 | 保留免责声明、人工抽检、敏感人群策略 |
| 后台配置无灰度 | P2 | 发布即对所有请求生效 | 如需要，增加按构建/比例灰度与自动回滚；当前不做假灰度 |

## 4. 凭据与数据卫生

- 本地测试 `account-server/config.php` 已被 `.gitignore` 忽略；未进入任何提交。
- `REVENUECAT_PUBLIC_SDK_KEY` 是客户端公开 SDK Key，已在工程设置中；不是服务器密钥。服务器端的 RevenueCat API v2 Key/webhook secret 未出现在源码包/本报告。
- 未发现新的硬编码数据库密码、APNs 私钥、AI owner token。
- 本报告不包含真实用户手机号、地址、照片、健康数值。

## 5. 结论

- 管理后台从“单一全权限账号 + 仅前端隐藏”提升为**服务端强制 RBAC**，并补齐配置/审计/登录防护。
- 账号 API 的高风险权益覆盖、Apple 重放、俱乐部锁 DoS 已修。
- **不能宣称安全验收完成**：实物奖励自报资格、APNs/Apple 配置、法律合规仍需人工/平台侧完成；这些已列为发布阻断/剩余风险。
