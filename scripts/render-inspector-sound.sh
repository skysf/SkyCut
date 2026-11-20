#!/usr/bin/env bash
# Off-screen renders of the clip inspector's sound section (Volume, the voice band, the sound scene; voice band off and at
# −10 dB) in the narrowest column and of the whole clip inspector at its default width, in en / zh-Hans / es, forest and
# classic on dark, for PR images and a look before a release. Usage: scripts/render-inspector-sound.sh <output folder>
# Needs a graphical session (real NSWindows, placed behind everything, never activated) and Screen Recording for the terminal
# (screencapture; without it set SRTFLOW_RENDER_DRAW_FALLBACK=1); **not in check-all.sh**. Isolated bundle id, a temporary
# placeholder media file; touches nothing of the user's. Links the full App's object files (like scripts/render-project-versions.sh).
# docs/architecture/sound-scenes.md section 5.
set -euo pipefail
OUT_DIR="${1:?usage: scripts/render-inspector-sound.sh <output folder>}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
APP="${ROOT}/InspectorSoundRender.app"
test_app_cleanup_on_exit "${APP}" "${ROOT}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.inspectorsoundrender</string>
<key>CFBundleExecutable</key><string>InspectorSoundRender</string>
<key>CFBundleName</key><string>InspectorSoundRender</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# The resource bundle at both places Bundle.module looks, and the string tables flat in Contents/Resources (as build-app.sh does):
# with only the .bundle, Bundle.main has no localizations and every language renders in English.
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
for table in "${BUILD_DIR}/SrtFlow_SrtFlow.bundle"/*.lproj; do
  ditto "${table}" "${APP}/Contents/Resources/$(basename "${table}")"
done
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/InspectorSoundUI/Render.swift checks/OffscreenRender/Snapshot.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/InspectorSoundRender"
SRTFLOW_INSPECTOR_SOUND_RENDER_OUT="${OUT_DIR}" SRTFLOW_INSPECTOR_SOUND_RENDER_WORK="${ROOT}/work" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/InspectorSoundRender" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
