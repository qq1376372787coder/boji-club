# BOJI CLUB 法律协议网站 · 部署说明

一套自托管的协议/隐私政策网站：9 种语言、深浅色模式、移动端适配、带在线编辑后台。
**纯 Python 标准库实现，零第三方依赖**。源码中的协议是待核对模板，不等于已完成律师审阅或所在地合规认定。

---

## 一、文件结构

```
legal-site/
├── server.py            # 唯一的服务程序（站点 + 管理后台 + API）
├── seed/                # 内置默认协议内容（9 种语言 × 7 份文档）
│   ├── zh-CN/ … zh-TW/ en/ ja/ ko/ th/ vi/ id/ ms/
├── assets/              # Logo（深浅色）、favicon、样式、脚本
├── data/                # 运行数据（自动生成，需备份）
│   ├── content.json     # 当前生效的全部协议内容（后台编辑后写入）
│   ├── config.json      # 站点设置（运营者、联系方式、备案号等）
│   ├── auth.json        # 管理员密码哈希（PBKDF2）
│   ├── sessions.json    # 登录会话
│   └── backups/         # 每次保存的自动备份（保留 30 份）
├── tools/validate.py    # 内容完整性校验脚本
└── DEPLOYMENT-GUIDE.md
```

包含的页面与协议：

| 页面 | URL 路径 | 说明 |
| --- | --- | --- |
| 官网首页 | `/` | 产品落地页：亮点、真机截图、下载按钮（后台可改 App Store 链接与公告条） |
| 协议中心 | `/legal` | 全部协议与政策的列表页 |
| 常见问题 | `/faq` | FAQ（后台可编辑） |
| 更新日志 | `/changelog` | 版本记录（后台可编辑） |
| 用户服务协议 | `/doc/terms` | |
| 隐私政策 | `/doc/privacy` | |
| 购买、订阅与退款政策 | `/doc/purchase` | |
| 账号注销与数据删除说明 | `/doc/deletion` | |
| AI 服务说明 | `/doc/ai-notice` | |
| 健康与运动风险提示 | `/doc/health-disclaimer` | |
| 关于我们与联系方式 | `/doc/about` | |

另有 `/sitemap.xml`（全部页面 × 全部语言的站点地图，供搜索引擎收录）。

所有页面均支持语言参数 `?lang=zh-CN|zh-TW|en|ja|ko|th|vi|id|ms`（也接受 `?hl=`），
以及主题参数 `?theme=light|dark|auto`；不传参数时自动跟随系统语言与深浅色设置。
官网图标为内联 SVG（随主题着色）；官网截图位于 `assets/screenshots/`（替换同名文件即可更新官网展示）。
官网首页文案（标语、功能列表）在 `seed/{语言}/home.json` 中，修改后重启服务生效。

---

## 二、本地快速体验

```bash
cd legal-site
python3 server.py --port 8765
# 浏览器打开 http://127.0.0.1:8765        → 协议首页
# 浏览器打开 http://127.0.0.1:8765/admin   → 管理后台
```

**首次启动**会自动生成管理员初始密码：

- 若设置了环境变量 `BOJI_ADMIN_PASSWORD`，则使用该密码；
- 否则自动生成随机密码，写入 `data/ADMIN_INITIAL_PASSWORD.txt` 并打印到控制台。
  **登录后请立即在「账号安全」中修改密码，并删除该文件。**

---

## 三、部署到你的服务器（Linux + systemd，推荐）

1. 上传整个 `legal-site` 目录到服务器，例如 `/opt/boji-legal/site/`：

```bash
mkdir -p /opt/boji-legal/site
# 上传后解压
cd /opt/boji-legal/site
python3 --version   # 需要 Python 3.9+（无需 pip 安装任何东西）
```

2. 创建 systemd 服务 `/etc/systemd/system/boji-legal.service`：

```ini
[Unit]
Description=BOJI CLUB Legal & Privacy Site
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/boji-legal/site
Environment=PORT=8770
Environment=HOST=127.0.0.1
Environment=BOJI_LEGAL_DATA=/var/lib/boji-legal
EnvironmentFile=-/etc/boji-legal.env
ExecStart=/usr/bin/python3 /opt/boji-legal/site/server.py
Restart=always
RestartSec=3
User=boji-legal
Group=boji-legal
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/boji-legal

[Install]
WantedBy=multi-user.target
```

3. 启动：

```bash
systemctl daemon-reload
systemctl enable --now boji-legal
curl -I http://127.0.0.1:8770/    # 发布门未打开时应返回 503
curl -I http://127.0.0.1:8770/admin  # 管理后台应返回 200
```

### 宝塔面板

- 「网站 → Python 项目 → 添加项目」：项目路径选 `boji-legal-site`，启动文件 `server.py`，端口自定；
- 或用上面的 systemd 方式运行，再用「网站 → 反向代理」把你的域名代理到 `127.0.0.1:8770`。

### Nginx 反向代理 + HTTPS（推荐）

```nginx
server {
    listen 443 ssl http2;
    server_name bojiclub.fun;

    ssl_certificate     /path/fullchain.pem;
    ssl_certificate_key /path/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8770;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # 管理后台 Cookie 需要
        gzip on;
        gzip_types text/html text/css application/javascript image/svg+xml;
    }
}
```

> **务必启用 HTTPS**：App 内 WebView 加载 `http://` 明文页面会被 iOS ATS 拦截，且管理后台登录 Cookie 需要 HTTPS 才会加 `Secure` 标记。`bojiclub.fun` 当前备案和 DNS 尚未就绪，现阶段只允许回环地址预览，不要配置公网 Nginx 反代或打开 `BOJI_LEGAL_PUBLISH=1`。

---

## 四、上线前必须做的 6 件事

1. **改管理员密码**：登录 `/admin` → 「账号安全」→ 修改初始密码；
2. **填写站点设置**：`/admin` → 「站点设置」→ 运营者名称、联系邮箱、网站域名（含 https://）、ICP 备案号（如已备案）、**App Store 链接**（官网下载按钮将指向该链接，格式如 `https://apps.apple.com/app/idXXXXXXXXX`）；如需在官网顶部显示公告，填写"官网公告条"；
   - 站点设置中的值会**实时替换**进所有语言的协议正文（`{{operator_name}}` 等占位符），改一处全站生效；
3. **确认数据存储地描述**：站点设置中「数据存储地」默认为"中华人民共和国境内"，如你的服务器实际位于境外（如香港、新加坡），请据实修改——这直接影响隐私政策的准确性；
4. **备份 data 目录**：`data/` 是全部生效内容，定期复制备份即可；后台也可「导出全部内容备份」；
5. **中国大陆上架**：需完成 ICP 备案/APP 备案并把备案号填入站点设置（页脚自动展示）；如 App 面向大陆公众提供生成式 AI 服务，按《生成式人工智能服务管理暂行办法》完成相应手续；
6. **发布前核对**：这些协议和本部署指南是模板，不代表已满足任一国家或地区的全部法律要求。必须按实际 App Store 上架地区、经营主体、服务商合同和数据流逐项核对；多地区上线前请由熟悉相关地区规则的律师审阅，特别是敏感健康信息、向 AI 服务商提供数据、跨境处理、未成年人、责任限制与消费者权益。

---

## 五、App 内接入

在 App 的「我的 → 设置 → 关于薄肌俱乐部」中，把各协议入口指向（替换域名）：

```
https://bojiclub.fun/doc/terms?lang={lang}&theme={mode}
https://bojiclub.fun/doc/privacy?lang={lang}&theme={mode}
https://bojiclub.fun/doc/purchase?lang={lang}&theme={mode}
https://bojiclub.fun/doc/deletion?lang={lang}&theme={mode}
https://bojiclub.fun/doc/ai-notice?lang={lang}&theme={mode}
https://bojiclub.fun/doc/health-disclaimer?lang={lang}&theme={mode}
```

- `{lang}`：跟随 App 当前语言（`zh-CN / zh-TW / en / ja / ko / th / vi / id / ms`）；不传则按 WebView 的 Accept-Language 自动匹配；
- `{mode}`：`light` / `dark` / `auto`，跟随 App 当前外观；不传则跟随系统；
- **App Store Connect** → App 隐私 → 「隐私政策网址」填：`https://bojiclub.fun/doc/privacy`；
- App Store Connect 审核信息里的「服务条款网址（Terms of Service (EULA)）」可填：`https://bojiclub.fun/doc/terms`（或保留 Apple 标准 EULA 链接）；
- 账号删除：Apple 要求 App 内提供清晰的账号删除入口；协议网页只能说明流程，不能替代 App 内删除能力。上线前应从当前发布构建实际走通删除流程。

### App 隐私标签对照（仅作核对清单，不是可直接照抄的申报结论）

| 数据类型 | 是否收集 | 与身份关联 | 用于追踪 |
| --- | --- | --- | --- |
| 联系信息（Apple 登录标识） | 是 | 是 | 否 |
| 健康与健身（健康数据、身体资料、训练/饮食记录） | 是 | 是 | 否 |
| 照片或视频（餐食/身体照片，用户主动提供） | 是 | 是 | 否 |
| 购买项目（订阅状态） | 是 | 是 | 否 |
| 标识符（安装标识、推送令牌） | 是 | 是 | 否 |
| 诊断（崩溃/使用日志、反馈附带版本信息） | 是 | 是 | 否 |
| 位置 / 浏览历史 / 广告数据 | 否 | — | — |

---

## 六、日常维护

| 操作 | 方式 |
| --- | --- |
| 修改协议内容 | `/admin` → 协议文档 → 点击对应语言单元格 → 编辑 → 保存 |
| 换 Logo / 改配色 | 替换 `assets/BojiMark-light.svg`、`BojiMark-dark.svg`；配色改 `assets/app.css` 顶部变量 |
| 误改想恢复 | 编辑页「恢复该语言默认内容」（回到 seed 内置版本） |
| 查看历史版本 | `data/backups/`（每次保存自动留档，保留 30 份） |
| 迁移服务器 | 打包整个目录即可；`data/` 携带全部生效内容与设置 |
| 校验内容完整性 | `python3 tools/validate.py` |

## 七、安全设计说明

- 管理密码使用 PBKDF2-HMAC-SHA256（20 万次迭代）加盐哈希存储；
- 登录接口按 IP 限速（10 分钟内 6 次失败锁定），Cookie 为 HttpOnly + SameSite=Strict（HTTPS 下自动附加 Secure）；
- 所有管理端写入操作校验 CSRF Token；每次保存前自动备份上一版本；
- `/admin` 与 `/api/admin/*` 均返回 noindex 响应头，robots.txt 亦声明 Disallow；
- 公开页面不使用 Cookie 追踪、不加载任何第三方脚本（字体、统计、CDN 均无）——隐私政策中"本网站不用广告 Cookie"的表述与实现一致。
