#!/usr/bin/env bash
# 真实导出任务、阶段计时、排队/取消、编码参数与静态 PNG 解码计数；只用合成测试工程。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/ExportProfileCheck.app"
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
  checks/ExportProfile/Main.swift checks/ExportProfile/Runner.swift \
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
