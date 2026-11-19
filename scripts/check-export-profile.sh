#!/usr/bin/env bash
# 真实进程收尾/双管道/错误/取消，以及导出任务、阶段计时、编码与 PNG 解码计数；只用合成测试工程。
# Also the export panel's folder window and destination (fake panel / fake stuck drive / one slowed real delivery):
# nothing there waits on the main thread (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md); the same for
# export_video's folder (docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md). Parallel AI exports never
# share a name and never replace a file (docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md); the export
# panel writes the file it checked (docs/bugfixes/2026-11-19-export-panel-checks-one-folder-writes-another.md).
# Compress / Burn In never overwrite or delete a file that is not the job's own
# (docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
APP="${ROOT}/ExportProfileCheck.app"
test_app_cleanup_on_exit "${APP}" "${ROOT}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.exportprofilecheck</string>
<key>CFBundleExecutable</key><string>ExportProfileCheck</string>
<key>CFBundleName</key><string>ExportProfileCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
cp Sources/SrtFlow/Resources/watermark-logo.svg "${APP}/Contents/Resources/watermark-logo.svg"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/ExportProfile/Main.swift checks/ExportProfile/Runner.swift checks/ExportProfile/ProcessChecks.swift \
  checks/ExportProfile/FileChooserChecks.swift checks/ExportProfile/FileWindowsChecks.swift \
  checks/ExportProfile/DestinationChecks.swift \
  checks/ExportProfile/AIExportFolderChecks.swift checks/ExportProfile/ExportTargetChecks.swift \
  checks/ExportProfile/PanelTargetChecks.swift checks/ExportProfile/EncodeQueueChecks.swift \
  checks/ExportProfile/EncodeOffMainChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/ExportProfileCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/source.mp4"
SRTFLOW_EXPORT_PROFILE_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/ExportProfileCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=180, check=True)
PYTHON
