# Boji Club · 薄肌俱乐部

Native iOS fitness app (SwiftUI) with an AI-assisted coaching layer and a
self-hosted account/automation backend.

> **This repository is proprietary.** Source code is published for version
> control and CI purposes only. See [LICENSE](LICENSE). No rights are granted
> to use, modify, or redistribute the contents.

---

## What's in here

| Directory | Contents |
|---|---|
| `BojiClub/` | iOS app target — SwiftUI client (96 Swift sources) |
| `BojiClubWidget/` | Widget + Live Activity extension |
| `BojiClubTests/` / `BojiClubUITests/` | XCTest unit + UI suites |
| `account-server/` | PHP account/admin server (FastCGI behind nginx) |
| `backend/` | Python AI worker (job queue, routing, nutrition, coach cores) |
| `exercise-server/` | Exercise catalog service (catalog + media serving) |
| `legal-site/` | Static privacy policy / terms publishing site |
| `legal/` | Third-party media rights checklist |
| `brand-assets/` | Brand artwork and logo sources |
| `Configuration/` | Release checklist template |
| `shared/` | Cross-target shared sources |
| `tests/` | Python + PHP regression suites, Swift rule harnesses |
| `scripts/` | Build, check and deploy helper scripts |
| `docs/` | Delivery notes, audits, historical manifests |

## Current release

**0.15.9 · Build 135** — see [BUILD135_NATURAL_EXPERIENCE.md](BUILD135_NATURAL_EXPERIENCE.md)
for the change summary and verification boundaries.
`README_先读我.md` is the Chinese entry point.

## Requirements

- **Xcode 26+**, iOS 17.0 deployment target
- **iPhone 17 simulator** (CI resolves it via `-destination`)
- Python 3.10+ (backend + offline test suite) — the code uses PEP 604
  unions (`str | None`) throughout, which need 3.10 or newer
- PHP 8.3 with `pdo_mysql`, `mbstring` (account server + PHP suites)
- MariaDB 10.11 (production) / MySQL 8.4 (isolated CI)

## Local verification

The full suite runs on macOS and takes ~10–15 minutes:

```bash
bash scripts/run-all-checks.sh
```

Stages: offline Python regression → Swift rule harnesses → simulator build →
unit tests → UI tests (accessibility audit + launch performance).

Isolated pieces:

```bash
python3 -I tests/run_offline.py          # offline Python regression only
bash tests/run_action_checks.sh           # domain commands, action recovery, migrations
python3 tests/test_audit129_runtime.py    # concurrent transaction + Admin HTTP integration
```

## Continuous integration

`.github/workflows/ci.yml` runs the iOS checks on `macos-latest`, the PHP/MySQL
suites on `ubuntu-latest`, and the admin runtime integration as a separate job.
Triggers on push and pull request to `main`.

## Integrity

`SOURCE-MANIFEST.sha256` and `SOURCE-MANIFEST.json` record a SHA-256 for every
tracked file. Superseded manifests are kept under `docs/historical-manifests/`.

Verify locally:

```bash
shasum -a 256 -c SOURCE-MANIFEST.sha256
```

## Deployment notes

Deployment targets Debian-family hosts with nginx + php-fpm and systemd units.
`account-server/deploy.sh` is Debian-oriented; production hosts run MariaDB.
Migration scripts are individually idempotent and support `--check` for release
gates — always run `--check` before `--apply`.
