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
  checks/MotionPlacement/Versions.swift checks/MotionPlacement/Editor.swift checks/MotionPlacement/DurationBounds.swift \
  checks/MotionPlacement/CacheCommit.swift checks/MotionPlacement/RecoveryOffMain.swift \
  checks/MotionPlacement/Official.swift checks/MotionPlacement/OfficialPreviews.swift checks/MotionPlacement/ClipNames.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${CHECK_APP}/Contents/MacOS/MotionPlacementCheck"
SRTFLOW_WEB_MOTION_HELPER="${CHECK_APP}/Contents/Helpers/skycut-web-motion" \
SRTFLOW_SMOKE_SCRIPT="${CHECK_ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${CHECK_APP}/Contents/MacOS/MotionPlacementCheck" "${CHECK_ROOT}/work" <<'PYTHON'
import os
import subprocess
import sys
# Always attempt both complete groups, each in a fresh process with its own finite watchdog and project root.
failures = []
for group in ("core", "official"):
    env = os.environ.copy()
    env["SRTFLOW_MOTION_PLACEMENT_DIR"] = os.path.join(sys.argv[2], group)
    print(f"motion checks: starting {group} (240 s cap)", flush=True)
    try:
        os.makedirs(env["SRTFLOW_MOTION_PLACEMENT_DIR"], exist_ok=True)
        with subprocess.Popen([sys.argv[1], group], stdin=subprocess.DEVNULL, env=env) as check:
            try:
                code = check.wait(timeout=240)
            except subprocess.TimeoutExpired:
                check.kill()
                check.wait()
                failures.append(f"{group}: timed out after 240 s")
                print("FAIL: " + failures[-1], flush=True)
                continue
    except OSError as error:
        failures.append(f"{group}: could not start: {error}")
        print("FAIL: " + failures[-1], flush=True)
        continue
    if code:
        failures.append(f"{group}: exit {code}")
        print("FAIL: " + failures[-1], flush=True)
if failures:
    print("FAIL: motion placement groups: " + "; ".join(failures), flush=True)
    sys.exit(1)
print("PASS: both motion placement groups completed", flush=True)
PYTHON
