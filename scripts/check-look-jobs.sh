#!/usr/bin/env bash
# A look never leaves the AI waiting for minutes (docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md), with real App objects:
# the router's lines (AICallLines), a look call that becomes a job (AILookCall), real looks (AILookTool) on real background projects,
# get_job / cancel_job (AIExportTools). Isolated bundle id per run, synthetic clips; never starts the user's App or touches the keychain.
# The router's own wiring (look goes through AILookCall, the lines replace the old queue tails) is scanned in checks/MCP/router-wiring.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
# A bundle id of its own per run (its own UserDefaults), like check-voice-recovery: several sessions on this Mac may run it at once.
BUNDLE_ID="com.srtflow.SrtFlow.lookjobscheck.run$$"
find "${HOME}/Library/Preferences" -maxdepth 1 -name 'com.srtflow.SrtFlow.lookjobscheck.run*.plist' -mmin +5 -delete 2>/dev/null || true
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/LookJobCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>LookJobCheck</string>
<key>CFBundleName</key><string>LookJobCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/LookJobs/Main.swift checks/LookJobs/LineChecks.swift checks/LookJobs/LookCallChecks.swift checks/LookJobs/Fixture.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/LookJobCheck"
# Footage shaped like generated clips: one keyframe per clip, so every frame a look asks for is decoded from the clip's start.
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
for source in testsrc2 smptehdbars rgbtestsrc; do
  "${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i "${source}=size=640x360:rate=24" -t 6 -c:v libx264 -preset ultrafast \
    -g 1000 -keyint_min 1000 -sc_threshold 0 -pix_fmt yuv420p "${ROOT}/work/${source}.mp4"
done
SRTFLOW_LOOK_JOBS_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/LookJobCheck" <<'PYTHON'
import subprocess
import sys
# The watchdog is a plain process timeout (not in Swift's thread pool): a look that never answers turns this check red.
with subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL) as check:
    try:
        code = check.wait(timeout=240)
    except subprocess.TimeoutExpired:
        print("Look job checks timed out; sampling the isolated check before stopping it", flush=True)
        try:
            subprocess.run(["/usr/bin/sample", str(check.pid), "1", "1", "-file", "/dev/stdout"], timeout=15, check=False)
        finally:
            check.kill()
            check.wait()
        raise
    if code:
        raise subprocess.CalledProcessError(code, [sys.argv[1]])
PYTHON
