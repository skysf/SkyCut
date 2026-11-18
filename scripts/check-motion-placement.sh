#!/usr/bin/env bash
# Real App + real renderer integration, using an isolated bundle id and synthetic pages; no user app, media, keychain or cloud.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build --arch arm64 --product skycut-web-motion 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
CHECK_ROOT="$(mktemp -d)"
trap 'CHECK_EXIT=$?; if [ "${CHECK_EXIT}" -eq 0 ]; then rm -rf "${CHECK_ROOT}"; else printf "Motion check fixture retained at %s\n" "${CHECK_ROOT}"; fi' EXIT
BUNDLE_ID="com.srtflow.SrtFlow.motionplacementcheck.run$$"
CHECK_APP="${CHECK_ROOT}/MotionPlacementCheck.app"
mkdir -p "${CHECK_APP}/Contents/MacOS" "${CHECK_APP}/Contents/Helpers" "${CHECK_APP}/Contents/Resources" "${CHECK_ROOT}/work"
cat > "${CHECK_APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>MotionPlacementCheck</string>
<key>CFBundleName</key><string>MotionPlacementCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${CHECK_APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${CHECK_APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
# Match the installed app's flat resource layout, including the official motion pages, previews and their receipts.
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${CHECK_APP}/Contents/Resources"
cp "${BUILD_DIR}/skycut-web-motion" "${CHECK_APP}/Contents/Helpers/skycut-web-motion"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/MotionPlacement/Main.swift checks/MotionPlacement/Fixture.swift checks/MotionPlacement/Fingerprints.swift \
  checks/MotionPlacement/Actions.swift checks/MotionPlacement/Approval.swift checks/MotionPlacement/FailureRecovery.swift \
  checks/MotionPlacement/Versions.swift checks/MotionPlacement/Editor.swift \
  checks/MotionPlacement/Official.swift checks/MotionPlacement/OfficialPreviews.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${CHECK_APP}/Contents/MacOS/MotionPlacementCheck"
SRTFLOW_WEB_MOTION_HELPER="${CHECK_APP}/Contents/Helpers/skycut-web-motion" \
SRTFLOW_MOTION_PLACEMENT_DIR="${CHECK_ROOT}/work" SRTFLOW_SMOKE_SCRIPT="${CHECK_ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${CHECK_APP}/Contents/MacOS/MotionPlacementCheck" <<'PYTHON'
import subprocess
import sys
# A hung helper or missing recovery must fail the check even if Swift's executor cannot make progress.
with subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL) as check:
    try:
        code = check.wait(timeout=240)
    except subprocess.TimeoutExpired:
        print("Motion placement checks timed out", flush=True)
        check.kill()
        check.wait()
        raise
    if code:
        raise subprocess.CalledProcessError(code, [sys.argv[1]])
PYTHON
