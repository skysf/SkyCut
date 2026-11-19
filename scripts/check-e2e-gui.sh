#!/usr/bin/env bash
# Mount the production editor controls and operate their own windows in-process.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
if [ ! -x "${FFMPEG}" ]; then
  echo "Editor GUI checks need an executable ffmpeg at ${FFMPEG}" >&2
  exit 1
fi

built="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${built}"; exit 1; }
swift build --arch arm64 --product skycut-web-motion
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
root="$(mktemp -d /tmp/skycut-e2e-gui.XXXXXX)"
app="${root}/SkyCutGUICheck.app"
test_app_cleanup_on_exit "${app}" "${root}"
mkdir -p "${app}/Contents/"{MacOS,Resources,Helpers}
resources="${BUILD_DIR}/SrtFlow_SrtFlow.bundle"
ditto "${resources}" "${app}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${resources}" "${app}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
cp "${BUILD_DIR}/skycut-web-motion" "${app}/Contents/Helpers/"
cp packaging/Info.plist "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.srtflow.e2egui$$" "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SkyCutGUICheck" "${app}/Contents/Info.plist"
xcrun swiftc -wmo -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/E2EGUI/*.swift @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${app}/Contents/MacOS/SkyCutGUICheck"
codesign --force --deep --sign - "${app}"

python3 -I -B scripts/gui-smoke/e2e/launch.py gui "${app}" "${FFMPEG}"
