#!/usr/bin/env bash
# Mount the production editor controls and operate their own windows in-process.
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
if [ ! -x "${FFMPEG}" ]; then
  echo "Editor GUI checks need an executable ffmpeg at ${FFMPEG}" >&2
  exit 1
fi

built="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${built}"; exit 1; }
swift build --arch arm64 --product skycut-web-motion
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
root="$(mktemp -d /tmp/skycut-e2e-gui.XXXXXX)"
trap 'rm -rf "${root}"' EXIT
app="${root}/SkyCutGUICheck.app"
mkdir -p "${app}/Contents/"{MacOS,Resources,Helpers} "${root}/"{home,work,tmp}
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

CFFIXED_USER_HOME="${root}/home" TMPDIR="${root}/tmp" SRTFLOW_VERSIONS_ROOT="${root}/versions" \
  SRTFLOW_SMOKE_MUTE=1 SRTFLOW_FFMPEG="${FFMPEG}" PYTHONDONTWRITEBYTECODE=1 \
  python3 - "${app}/Contents/MacOS/SkyCutGUICheck" "${root}/work" "${PWD}/scripts/gui-smoke/e2e/ink-plate.html" <<'PYTHON'
import subprocess
import sys
subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, check=True, timeout=100)
PYTHON
