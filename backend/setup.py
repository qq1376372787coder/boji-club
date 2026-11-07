"""Interactive local setup; provider keys never appear on stdout."""
import getpass
import os
from pathlib import Path
import secrets

path = Path(__file__).resolve().parent / ".env"
if path.exists():
    choice = input("配置已存在。输入 update 更新模型密钥，直接回车保留：").strip()
    if choice != "update":
        print("内部 AI worker：http://127.0.0.1:8787")
        print("本机后端配置保持不变。")
        raise SystemExit(0)
    old = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line and not line.startswith("#"))
else:
    old = {}

print("密钥输入不会显示在屏幕上。直接回车会保留原有密钥。")
minimax = getpass.getpass("MiniMax API Key：").strip() or old.get("MINIMAX_API_KEY", "")
deepseek = getpass.getpass("DeepSeek API Key：").strip() or old.get("DEEPSEEK_API_KEY", "")

if not minimax and not deepseek:
    raise SystemExit("至少配置一个密钥后才能启动。")
if any("\n" in key or "\r" in key for key in (minimax, deepseek)):
    raise SystemExit("密钥不能含换行符。")
token = old.get("APP_TOKEN") or secrets.token_urlsafe(32)
session_secret = old.get("SESSION_SIGNING_KEY") or secrets.token_urlsafe(48)
os.umask(0o077)
old.update(MINIMAX_API_KEY=minimax, DEEPSEEK_API_KEY=deepseek,
           APP_TOKEN=token, SESSION_SIGNING_KEY=session_secret)
old.setdefault('PORT', '8787')
old.pop('MAX_JOBS_PER_DAY', None)  # Runtime capacity is managed in the admin console.
path.write_text(''.join(key + '=' + value + '\n' for key, value in old.items()), encoding='utf-8')
path.chmod(0o600)
print("模型密钥已保存在本机隐藏配置文件中。")
print("内部 AI worker：http://127.0.0.1:8787")
print("App 需要账号服务代理。请同时部署 account-server，并在服务器配置同一 APP_TOKEN；不要把内部连接码放进 App。")
