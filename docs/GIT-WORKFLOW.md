# Git 分支模型与发布流程（P0-1 版本控制）

自 2026-11-07 起本仓库纳入版本控制（此前为 zip 交付、无 `.git`，改坏无法回滚）。

## 分支模型

| 分支 | 作用 | 保护 |
|---|---|---|
| `main` | 发布基线。每个可发布版本在此打 tag | 直接提交禁止；只接受 `develop` 合入 |
| `develop` | 集成分支，日常开发的默认目标 | 只接受 feature 分支合入 |
| `feature/<编号>-<描述>` | 功能/修复，从 `develop` 拉出，完成后合回 `develop` | 例：`feature/p0-release-gate` |

命名规范：`feature/<P0/P1/P2或任务号>-<kebab描述>`；修复类也可用 `fix/` 前缀，规则相同。

## 回滚语义

- 基线 tag：`v0.15.9-b139-baseline`（首次入库的 Build 139 原样快照）。
- 任意合入出问题：`git revert <merge-commit>`（不用 reset 改写已共享历史）。
- 需要整体回退到入库原状：`git checkout main && git reset --hard v0.15.9-b139-baseline`（仅限未推送远端前）。

## 首次入库已核实的安全边界

提交 `132f605` 前做过扫描，以下**不在**版本库内（`.gitignore` 拦截或交付包本身不含）：

- `account-server/config.php`（服务端密钥）
- `backend/.env`、`backend/.data/`
- `Configuration/ReleaseChecklist.local.plist`（私有发布清单）
- `*.p8` / `*.p12` / 私钥 / 备份密码文件
- 用户媒体 `account-server/media/`、构建产物、`__pycache__`

新增敏感文件时先确认被 `.gitignore` 覆盖；`git add` 后用
`git diff --cached --name-only` 复核，禁止密钥入库。

## 提交与合并纪律

1. 任何改动先拉 `feature/*`，完成后合回 `develop`，合并信息注明任务编号；
2. 合并前必须过 `scripts/run-all-checks.sh`（全量回归）与 `scripts/check-release-ready.py`（发布门禁）；
3. 发布：`develop` 验收通过 → 合入 `main` → 打 tag `v<版本>-b<构建号>`；
4. 提交信息用中文或英文均可，但必须说明"改了什么 + 为什么"。

## 与 CI 的关系

`.github/workflows/ci.yml` 在 push 到 `main` 或 PR 时触发；接入远端托管前该文件不生效（见 P0-3）。
