#!/usr/bin/env bash
# A project's own file is written off the main thread with a deadline, and closing / switching / Quit never wait on a drive
# on the main thread (docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md), on real App objects: a fake drive that
# is slow, stuck (held until the check lets it go) or failing stands in for the disk; the moved-file and Save As cases write
# real files. Isolated bundle id (its own preferences) and a temporary folder: never touches the user's SkyCut or projects.
# Links the full App's object files (shard 1 of scripts/check-all.sh). No ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
APP="${ROOT}/ProjectSavesCheck.app"
test_app_cleanup_on_exit "${APP}" "${ROOT}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.projectsavescheck</string>
<key>CFBundleExecutable</key><string>ProjectSavesCheck</string>
<key>CFBundleName</key><string>ProjectSavesCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/ProjectSaves/Main.swift checks/ProjectSaves/SaveChecks.swift checks/ProjectSaves/CloseQuitChecks.swift \
  checks/ProjectSaves/EditWhileClosingChecks.swift checks/ProjectSaves/ReplaceChecks.swift \
  checks/ProjectSaves/OffMainWriteChecks.swift checks/ProjectSaves/UntitledMarkersChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/ProjectSavesCheck"
SRTFLOW_PROJECT_SAVES_CHECK_DIR="${ROOT}/work" SRTFLOW_VERSIONS_ROOT="${ROOT}/versions" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/ProjectSavesCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=180, check=True)
PYTHON
