#!/usr/bin/env bash
# Saved project versions around AI rounds (docs/architecture/project-versions.md), on real App objects: a round of 20 edits and one
# step back to the version from before it (the project equals the start field by field, media references included; Command-Z
# returns), nothing saved when nothing changed, a never-saved project, pruning and the age sweep, undo version='s errors,
# get_status, two projects keeping their own versions, a moved media file followed.
# Isolated bundle id (its own preferences), temporary projects, media and versions root (SRTFLOW_VERSIONS_ROOT): never touches the
# user's SkyCut, keychain or Application Support. Links the full App's object files (shard 1 of scripts/check-all.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/ProjectVersionsCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work" "${ROOT}/versions"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.projectversionscheck</string>
<key>CFBundleExecutable</key><string>ProjectVersionsCheck</string>
<key>CFBundleName</key><string>ProjectVersionsCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/ProjectVersions/Main.swift checks/ProjectVersions/FileChecks.swift checks/ProjectVersions/RoundChecks.swift \
  checks/ProjectVersions/TwoProjectChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/ProjectVersionsCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
for name in a b c; do
  "${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=160x90:r=24 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/${name}.mp4"
done
SRTFLOW_PROJECT_VERSIONS_CHECK_DIR="${ROOT}/work" SRTFLOW_VERSIONS_ROOT="${ROOT}/versions" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/ProjectVersionsCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=180, check=True)
PYTHON
