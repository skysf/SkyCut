#!/usr/bin/env bash
# Drive a built SkyCut and its real MCP helper with synthetic media in CI's graphical session.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh

FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
if [ ! -x "${FFMPEG}" ]; then
  echo "End-to-end checks need an executable ffmpeg at ${FFMPEG}" >&2
  exit 1
fi

# These products are already built in CI. Build here too for check-local runs.
built="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${built}"; exit 1; }
swift build --arch arm64 --product skycut-mcp
swift build --arch arm64 --product skycut-web-motion
python3 -I -B checks/E2E/Harness.py
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
root="$(mktemp -d /tmp/skycut-e2e.XXXXXX)"

app="${root}/SkyCutE2E.app"
test_app_cleanup_on_exit "${app}" "${root}"
mkdir -p "${app}/Contents/"{MacOS,Resources,Helpers}
cp "${BUILD_DIR}/SrtFlow" "${app}/Contents/MacOS/"
cp "${BUILD_DIR}/skycut-mcp" "${app}/Contents/Helpers/"
cp "${BUILD_DIR}/skycut-web-motion" "${app}/Contents/Helpers/"
resources="${BUILD_DIR}/SrtFlow_SrtFlow.bundle"
if [ -d "${resources}/Contents/Resources" ]; then
  ditto "${resources}/Contents/Resources" "${app}/Contents/Resources"
else
  ditto "${resources}" "${app}/Contents/Resources"
fi
ditto "${resources}" "${app}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${resources}" "${app}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
cp packaging/Info.plist "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.srtflow.e2e$$.skystudiosmoke" "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SrtFlow" "${app}/Contents/Info.plist"
codesign --force --deep --sign - "${app}"

python3 -I -B scripts/gui-smoke/e2e/launch.py mcp "${app}" "${FFMPEG}" "$@"
