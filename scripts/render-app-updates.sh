#!/usr/bin/env bash
# Off-screen renders of SkyCut's update UI (the toolbar pill's looks, every popover, the answers to a check started from
# the menu, the menu item, Settings › General › Software Update) in en / zh-Hans / es, for PR images and a look before a
# release. Usage: scripts/render-app-updates.sh <output folder>
# Needs a graphical session (real NSWindows, placed behind everything, never activated) and Screen Recording for the terminal
# (screencapture; SRTFLOW_RENDER_DRAW_FALLBACK=1 draws without it); **not in check-all.sh**. Isolated bundle id; checks
# nothing, downloads nothing, touches nothing of the user's. Links the full App's object files (like
# scripts/render-move-to-applications.sh). docs/architecture/app-updates.md.
set -euo pipefail
OUT_DIR="${1:?usage: scripts/render-app-updates.sh <output folder>}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
APP="${ROOT}/AppUpdateRender.app"
test_app_cleanup_on_exit "${APP}" "${ROOT}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.appupdaterender</string>
<key>CFBundleExecutable</key><string>AppUpdateRender</string>
<key>CFBundleName</key><string>AppUpdateRender</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# The resource bundle at both places Bundle.module looks, and the string tables flat in Contents/Resources (as build-app.sh
# does): with only the .bundle, Bundle.main has no localizations and every language renders in English.
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
for table in "${BUILD_DIR}/SrtFlow_SrtFlow.bundle"/*.lproj; do
  ditto "${table}" "${APP}/Contents/Resources/$(basename "${table}")"
done
# The menu answers show the app's icon: the same one build-app.sh makes.
swift scripts/make-icon.swift "${ROOT}/icon.iconset" >/dev/null
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/AppUpdateUI/Render.swift checks/OffscreenRender/Snapshot.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/AppUpdateRender"
SRTFLOW_UPDATE_RENDER_OUT="${OUT_DIR}" SRTFLOW_UPDATE_RENDER_ICON="${ROOT}/icon.iconset/icon_512x512.png" \
python3 - "${APP}/Contents/MacOS/AppUpdateRender" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=300, check=True)
PYTHON
