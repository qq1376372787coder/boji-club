#!/usr/bin/env python3
"""部署配置契约（文本级，不需要 PHP）。

背景：deploy.sh 首次部署生成的 config.php 曾只包含数据库与短信键，漏掉
Apple 登录、RevenueCat 回调与 API v2 相关键。漏键不会让部署失败，而是让接口
在运行时静默失败——webhook 全部 401、/me/membership/verify 返回
rc_not_configured（客户端长时间"核验中"）、Apple 登录 503。

本测试从 deploy.sh 中抽出 config.php 生成模板，按 account-server/config-contract.php
列出的必需键做文本断言，保证模板不再漏键；密钥类值必须走环境变量，不得写死在模板里。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "account-server" / "deploy.sh"
CONTRACT = ROOT / "account-server" / "config-contract.php"

REQUIRED_KEYS = [
    "dsn",
    "db_user",
    "db_password",
    "otp_secret",
    "apple_client_ids",
    "apple_keys_cache_dir",
    "apple_team_id",
    "apple_key_id",
    "apple_private_key_path",
    "apple_token_encryption_key",
    "revenuecat_webhook_authorization",
    "revenuecat_product_ids",
    "revenuecat_lifetime_product_ids",
    "revenuecat_environment",
    "revenuecat_store",
    "revenuecat_app_id",
    "revenuecat_entitlement_id",
    "revenuecat_project_id",
    "revenuecat_v2_entitlement_id",
    "revenuecat_v2_products",
    "revenuecat_api_v2_key_file",
]

# 模板里这些值必须来自环境变量，不得出现明文常量。
SECRET_KEYS = ["db_password", "otp_secret", "revenuecat_webhook_authorization", "apple_token_encryption_key"]

failures: list[str] = []


def check(ok: bool, label: str) -> None:
    if not ok:
        failures.append(label)


def main() -> int:
    deploy = DEPLOY.read_text(encoding="utf-8")
    contract = CONTRACT.read_text(encoding="utf-8")

    check("function bojiRequiredConfigKeys" in contract, "config-contract.php 定义 bojiRequiredConfigKeys")
    check("function bojiValidateConfig" in contract, "config-contract.php 定义 bojiValidateConfig")
    check("bojiValidateConfig" in deploy, "deploy.sh 调用配置契约校验")

    match = re.search(r"<<'?PHP'?\n(.*?)\nPHP\n", deploy, re.S)
    check(match is not None, "deploy.sh 含 config.php 生成模板")
    if match is None:
        report()
        return 1
    template = match.group(1)

    for key in REQUIRED_KEYS:
        check(f"'{key}'" in template or f'"{key}"' in template, f"config.php 模板包含键 {key}")

    for key in SECRET_KEYS:
        # 只拒绝明文常量；${VAR} 占位是允许的。
        hit = re.search(rf"'{key}'\s*=>\s*'(?!\$\{{)[^']*'", template)
        check(hit is None, f"config.php 模板未把 {key} 写成明文常量")

    # 模板里出现的 ${VAR} 占位都应在 deploy.sh 中有来源：必填环境变量、
    # 自动生成密钥的函数，或从环境变量映射而来的本地变量。
    placeholders = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", template))
    sourced = set(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)="', deploy, re.M))
    # 必填校验：BOJICLUB_* 环境变量有 :? 守卫，其值映射到本地变量后写入模板。
    for env_name in re.findall(r':\s*"?\$\{([A-Za-z_][A-Za-z0-9_]*)\??', deploy):
        if env_name.startswith("BOJICLUB_"):
            local = re.findall(rf'^\s*([A-Za-z_][A-Za-z0-9_]*)="\${{{env_name}}}(?![A-Za-z0-9_])', deploy, re.M)
            sourced |= set(local)
    for name in sorted(placeholders - sourced):
        check(False, f"模板占位符 {name} 在 deploy.sh 中缺少必填校验或生成来源")

    check(
        "install -d" in deploy and "cache/apple-keys" in deploy,
        "deploy.sh 创建 Apple 公钥缓存目录",
    )
    check(
        "generate_config_secret" in deploy,
        "deploy.sh 在密钥缺失时生成随机密钥",
    )
    for var in ("BOJICLUB_APPLE_TEAM_ID", "BOJICLUB_APPLE_KEY_ID"):
        check(f"{var}:?" in deploy or f"${{{var}:?" in deploy, f"{var} 有必填校验")

    report()
    return 1 if failures else 0


def report() -> None:
    if failures:
        for item in failures:
            print(f"FAIL: {item}", file=sys.stderr)
        raise SystemExit(1)
    print(f"deploy-config-contract OK ({len(REQUIRED_KEYS)} keys checked)")


if __name__ == "__main__":
    raise SystemExit(main())
