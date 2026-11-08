# Git 分支模型与发布流程（P0-1 版本控制）

自 2026-11-07 起本仓库纳入版本控制（此前为 zip 交付、无 `.git`，改坏无法回滚）。

## 分支模型

| 分支 | 作用 | 保护 |
|---|---|---|
| `main` | 发布基线。每个可发布版本在此打 tag | 直接提交禁止；只接受 `develop` 合入 |
| `develop` | 集成分支，日常开发的默认目标 | 只接受 feature 分支合入 |
| `feature/<编号>-<描述>` | 功能/修复，从 `develop` 拉出，完成后合回 `develop` | 例：`feature/p0-release-gate` |

命名规范：`feature/<P0/P1/P2或任务号>-<kebab描述>`；修复类也可用 `fix/` 前缀，规则相同。

**绝对禁止**：直接在 `main` / `develop` 上提交、在别人正在编辑的文件上代为提交、
`git add -A` / `git add .` 一把梭（会把他人在途改动一起带走）。

## 多人/多 Bot 共享工作区纪律

本仓库是**共享工作目录**：多名成员（含 Bot）可能同时在同一工作区编辑文件。
首次入库当晚即出现真实案例：法务成员在 `legal-site/seed/` 活跃编辑（未暂存改动
`health-disclaimer.md`），与运维的门禁修复提交在同一工作区并行。

规则：

1. **只提交自己的文件**：`git add <明确路径>`，禁止 `git add -A`；
2. **提交前必看**：`git status --short`——出现不属于本次任务的 `M`/`??` 行，
   一律留在工作区不动，不 stash、不 checkout、不 reset（那是别人的在途成果）；
3. **开工前先拉**：`git checkout develop && git pull`（远端接入后）再拉自己的
   `feature/*`，避免基于过期状态开发；
4. **改共享文件先说**：若你要改的文件 `git status` 显示已被他人修改，先在群里
   确认谁先完成，不要覆盖；
5. **禁止改写历史**：不 `git commit --amend` 已合并的提交、不 `reset --hard`
   覆盖工作区、不 `git checkout -- <别人的文件>`。

## 游离头指针（detached HEAD）危害与防护

**事故**：共享工作区已发生 3 次「提交落在游离头上」（苹果开发 ×2、文档管理 ×1）。
根因是同一条习惯命令：

```sh
git checkout origin/main    # ❌ 远端跟踪引用一 checkout 就进游离态
```

此后 `git commit` 不会进入任何分支；等 `git switch main` 切回来后，那些提交就从
main 上消失（只能靠 reflog / cherry-pick 捞回）。

**只看远端状态，用只读命令**（不动 HEAD）：

```sh
git fetch origin                 # 更新远端引用
git log origin/main -5           # 看远端历史
git diff main origin/main        # 看差异
```

**已装的本地守卫**（`.git/hooks/`，不入 git；换机或重建 `.git` 后需重装）：

| 钩子 | 作用 |
|---|---|
| `pre-commit` | 游离头状态下**拒绝提交**，并打印恢复步骤 |
| `post-checkout` | 一旦 checkout 进游离态**立即告警**，提示 `git switch main` |

重装内容（分别写入 `.git/hooks/pre-commit` 与 `.git/hooks/post-checkout`）：

```sh
#!/bin/sh
# pre-commit
if [ -z "$(git symbolic-ref -q HEAD)" ]; then
  echo "已阻止提交：当前是游离头指针状态（detached HEAD）。"
  echo "恢复：git switch main && git status 确认后再提交。"
  exit 1
fi
```

```sh
#!/bin/sh
# post-checkout
if [ -z "$(git symbolic-ref -q HEAD)" ]; then
  echo "注意：这次 checkout 已把 HEAD 切到游离状态。看完请 git switch main"
fi
```

**builder 与游离头无关**：`logs-builder-*.log` 里的 “Checkout repository /
Checkout working-tree snapshot” 是 GitHub Actions **云端 runner** 的步骤名，
不碰本地 HEAD。排查本地 HEAD 变动用 `git reflog`。

## 提交前自检清单（每次提交过一遍）

```sh
# 1) 看清工作区：只允许出现你自己的改动
git status --short

# 2) 敏感文件扫描（四项全空才可提交）
git diff --cached --name-only | grep -E 'config\.php$|\.env$|\.p8$|\.p12$|backup-password|ReleaseChecklist\.local'   # 应无输出
grep -rln "BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY" --include='*.php' --include='*.py' --include='*.json' .         # 应无输出

# 3) 精确暂存 + 复核
git add <你的文件路径>
git diff --cached --name-only    # 确认清单里只有你的文件
```

已知敏感路径（`.gitignore` 已拦截，新增同类文件须先补 `.gitignore`）：
`account-server/config.php`、`backend/.env`、`backend/.data/`、
`Configuration/ReleaseChecklist.local.plist`、`*.p8`/`*.p12`、备份密码、
`account-server/media/`、构建产物、`__pycache__`。

## 回滚语义

- 基线 tag：`v0.15.9-b139-baseline`（首次入库的 Build 139 原样快照）。
- 任意合入出问题：`git revert <merge-commit>`（不用 reset 改写已共享历史）。
- 需要整体回退到入库原状：`git checkout main && git reset --hard v0.15.9-b139-baseline`（仅限未推送远端前）。

## 提交与合并纪律

1. 任何改动先拉 `feature/*`，完成后合回 `develop`，合并信息注明任务编号；
2. 合并前必须过 `scripts/run-all-checks.sh`（全量回归）与 `scripts/check-release-ready.py`（发布门禁）；
   仅改文档/脚本且不动 Swift/PHP 时，至少执行 `python3 -m py_compile <改动脚本>`
   与门禁脚本本身，并在合并信息中注明"未触碰产品代码，全量回归未重跑"；
3. 发布：`develop` 验收通过 → 合入 `main` → 打 tag `v<版本>-b<构建号>`；
4. 提交信息模板：首行 `P0-x: 改了什么`，正文写"为什么 + 验证方式（命令与结果）"。

## 与 CI 的关系

`.github/workflows/ci.yml` 在 push 到 `main` 或 PR 时触发。远端托管接入（P0-3）
前该文件不生效；接入后：

1. `develop` 上的合入通过 PR 进 `main`（或按团队决定直接 push `develop`）；
2. CI 跑 `run-all-checks.sh` + PHP 任务，红灯不许合入；
3. 发布 tag 必须在 CI 全绿的提交上打。
