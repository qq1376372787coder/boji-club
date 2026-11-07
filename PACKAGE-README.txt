当前交付：0.15.6 (Build130)。请先阅读 BUILD130_升级说明.md。旧文档及旧 manifest 仅供追溯。此次未上传 TestFlight。

最新交付：0.15.1 / Build 113，见 docs/experience-upgrade-20261021/README.md。以下内容保留为历史材料。

BOJI CLUB V2.0 · Latest Source Package
=====================================
Date: 2026-10-21
Git commit: aadaa13 (local repository)
Version: 0.15.0 / Build 112 + V2 quality changes

WHAT IS INCLUDED
----------------
- BojiClub/               iOS SwiftUI app, assets, Widget, UI tests
- BojiClub.xcodeproj/     Xcode project (TestFlight scheme included)
- account-server/         PHP account/admin server
  - Includes admin-media static reward images
  - Includes migrate-v2-quality.php and migrations/
- backend/                Python AI worker source
- exercise-server/        Exercise catalog service source
- legal/                  Legal drafts (NOT legal-reviewed)
- Configuration/          Example release checklist only
- tests/                  Python/PHP/Swift/UI test source
- docs/audits/boji-v2-quality/
                          Current audit reports, evidence and deployment record
- scripts/               Project helper scripts

EXCLUDED FROM THIS PACKAGE
--------------------------
- .git history
- account-server/config.php (server secrets — never distribute)
- account-server/media/ (uploaded user media)
- runtime/private-cache/private keys/private data
- backend/.env and backend/.data
- old delivery/repair/audit evidence archives
- build caches, xcuserdata, __pycache__

TEST STATUS (reported in docs/audits/boji-v2-quality/04_TEST_REPORT.md)
-----------------------------------------------------------------------
- Python offline: 639/639 passed
- PHP isolated MySQL: 38/38 passed
- Swift generated harnesses: 51/51 passed
- XCUITest (iPhone 17 Pro Max / iOS 26.5): 14/14 passed
- TestFlight configuration simulator build: BUILD SUCCEEDED
- Live test server deployment/verification: see 13_DEPLOYMENT_20261021.md

LIVE TEST SERVER
----------------
A selective server deployment was completed on 2026-10-21 at
https://117.50.119.49 (test API/admin). A fresh test member was created:
club number NO. 980105. The 30-day server-test login code is NOT in this
package; it was delivered separately and works only in DEBUG builds.
The server's existing config.php and uploaded media are intentionally not
included; do not overwrite them during deployment.

BEFORE DEPLOYING
----------------
1. Back up DB/config/media/nginx, as done in 13_DEPLOYMENT_20261021.md.
2. Copy the target server's config.php separately; never commit or package it.
3. Run migrate-v2-quality.php --check, then apply, then --check again.
4. Preserve config.php, media/, admin-media/, private/, private-keys/.
5. The bundled deploy.sh is Debian-oriented and is NOT suitable for the
   current Rocky Linux host; deploy selectively or adapt it.

KNOWN RELEASE BLOCKERS
----------------------
- iOS APNs entitlement/Push capability is absent; remote push is not usable.
- Release API domain api.gongxiang.cloud does not resolve.
- Legal documents are drafts; LegalReviewed=false.
- Physical reward eligibility still relies on client-synced data.

SECURITY
--------
The server root password was shared during deployment and should be rotated.
Use SSH keys and a non-root sudo deployment user. No passwords, tokens, or
config.php are included in this archive.

Checksums are in SOURCE-MANIFEST.sha256 next to this file.
