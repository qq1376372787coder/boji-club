#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p build-check/screenshot-brand
SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -typecheck \
  -sdk "$SIMULATOR_SDK" -target arm64-apple-ios17.0-simulator \
  -module-name BojiScreenshotBrand BojiClub/ScreenshotBranding.swift \
  2>&1 | tee build-check/screenshot-brand/uikit-typecheck.log
HARNESS="build-check/screenshot-brand/main.swift"
printf 'import Foundation\n' > "$HARNESS"
sed -n '/^\/\/ BEGIN SCREENSHOT BRAND LAYOUT/,/^\/\/ END SCREENSHOT BRAND LAYOUT/p' BojiClub/ScreenshotBranding.swift >> "$HARNESS"
cat >> "$HARNESS" <<'SWIFT'
func frame(_ width: CGFloat = 390, _ height: CGFloat = 844,
           top: CGFloat = 47, status: CGFloat = 47,
           phone: Bool = true, portrait: Bool = true, visible: Bool = true) -> CGRect? {
    ScreenshotBrandLayout.frame(bounds: CGRect(x: 0, y: 0, width: width, height: height),
        safeTop: top, statusHeight: status, isPhone: phone,
        isPortrait: portrait, statusVisible: visible)
}
let portraitCases: [(CGFloat, CGFloat, CGFloat)] = [
    (375, 812, 44), (390, 844, 47), (428, 926, 47),
    (393, 852, 59), (430, 932, 59), (402, 874, 62), (440, 956, 62)
]
for (width, height, top) in portraitCases {
    let result = frame(width, height, top: top, status: top)!
    precondition(result.midX == width / 2)
    precondition(result.minY >= 0 && result.maxY < top)
    // Keep the clock and signal columns outside the badge, including compact phones.
    precondition(result.minX > 100 && result.maxX < width - 100)
}
precondition(frame(375, 667, top: 20, status: 20) == nil) // SE / no cutout
precondition(frame(844, 390, portrait: false) == nil) // landscape
precondition(frame(portrait: false) == nil) // upside-down / transition
precondition(frame(430, 932, top: 0, status: 0, visible: false) == nil) // camera
precondition(frame(phone: false) == nil) // iPad / other device family
precondition(frame(top: 0) == nil) // not yet attached
precondition(frame(top: 80, status: 80) == nil) // unfamiliar system layout
precondition(frame(status: 0) == nil) // hidden status bar
print("Screenshot brand: 7 portrait layouts and 8 exclusion cases passed.")
SWIFT
xcrun swiftc "$HARNESS" -o build-check/screenshot-brand/check
build-check/screenshot-brand/check | tee build-check/screenshot-brand/layout-check.log
