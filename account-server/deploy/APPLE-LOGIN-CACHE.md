# Apple 登录公钥缓存：部署与验收

2026-10-21 真机登录发现：Apple 公钥接口可达，但默认 `cache/apple-keys` 不存在；部署根目录由 root 持有，PHP-FPM 用户 nginx 无法自行建立缓存目录。`cachedAppleKeys()` 在读取 Apple 公钥前就因 `cache unavailable` 失败，HTTP 登录接口返回 503“Apple 验证服务暂不可用”。

## 部署前创建目录

先确认线上配置 `apple_keys_cache_dir`：没有设置时，使用账号服务根目录下 `cache/apple-keys`。应在 PHP-FPM worker 的身份下验收，不能仅用 root 执行 PHP 后判断可用。

本次主机的 PHP-FPM worker 为 nginx，安装根目录为 `/opt/bojiclub-account`。确认目录不存在且路径无符号链接后执行：

```sh
install -d -o root -g nginx -m 0750 /opt/bojiclub-account/cache
install -d -o nginx -g nginx -m 0700 /opt/bojiclub-account/cache/apple-keys
```

其他主机需替换安装目录、实际 PHP-FPM 用户与组；如果配置了自定义缓存路径，应准备该路径。仅授予缓存目录所需权限，不要放宽整个安装目录，也不要把密钥或令牌放入这个公开 JWK 缓存。

## 验收

1. 在 nginx 用户下验证目录可读写，并用 `cachedAppleKeys()` 拉取、保存和复用 Apple 当前公钥；`keys.json` 与 `keys.lock` 应由 worker 持有且权限为 0600。
2. Apple 公钥地址为 `https://appleid.apple.com/auth/keys`，使用正常 HTTPS 证书校验。
3. 用当前 Apple `kid`、故意无效签名的测试凭证请求 `/account/v1/auth/apple/verify`，应返回 401，而不是缓存故障 503；该请求不得建立账号或会话。
4. 用真实 iPhone 重新发起 Apple 登录确认成功。不得关闭签名、audience、nonce、过期或重放检查来绕过登录故障。

## 本次修复

线上已建立上述目录，缓存含 3 把 Apple 公钥。nginx 身份读写检查通过；线上无效签名探针返回 401。没有修改客户端、验证代码、证书、数据库或用户记录，不需要重新打包 App 或重启 PHP-FPM。

真实 iPhone 登录的重试结果需单独记录，前述探针仅验证服务可达及拒绝错误凭证，不能替代成功登录。

## 回滚与清理

本次只新增公钥缓存目录和文件，不涉及用户数据。服务运行期间应保留缓存；删除缓存会使下一次校验重新拉取公钥。若需回滚本次目录准备，应先停用对应登录入口、确认无并发访问及目录仅包含本功能缓存，再清理新增路径。无需数据库回滚。
