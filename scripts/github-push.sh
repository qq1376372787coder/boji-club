#!/usr/bin/env bash
# 将本地仓库推送到 GitHub（P0-3）。
#
# 凭据规则：
#   · token 只从环境变量 GITHUB_TOKEN 读取，绝不写入任何文件、远程 URL、
#     shell 历史参数或输出；askpass 临时脚本本身只含变量名，不含值。
#   · 若用户已自行配置 git 凭据（credential helper / SSH 密钥），可省略
#     GITHUB_TOKEN，本脚本直接用已有凭据推送。
#   · 本脚本可以安全提交进仓库（已核验不含任何真实凭据）。
#
# 用法：
#   GITHUB_TOKEN=<token> bash scripts/github-push.sh https://github.com/<owner>/<repo>.git
#   bash scripts/github-push.sh https://github.com/<owner>/<repo>.git   # 已自配凭据时
set -euo pipefail

repo_url=${1:?用法: bash scripts/github-push.sh <git-repo-url>}
cd "$(dirname "$0")/.."

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$repo_url"
else
  git remote add origin "$repo_url"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  askpass=$(mktemp)
  trap 'rm -f "$askpass"' EXIT
  cat >"$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "x-access-token" ;;
  Password*) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
ASKPASS
  chmod 700 "$askpass"
  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git push -u origin main develop --tags
else
  GIT_TERMINAL_PROMPT=0 git push -u origin main develop --tags
fi

echo "PUSH_OK -> $repo_url（main / develop / tags）"
