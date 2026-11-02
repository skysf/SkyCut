#!/usr/bin/env bash
# 完整 App 的成片检查：合成缺陷、真实混音/取帧/试听/任务，不启动或触碰用户 App。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/InspectionCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.inspectioncheck</string>
<key>CFBundleExecutable</key><string>InspectionCheck</string>
<key>CFBundleName</key><string>InspectionCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/VideoInspection/Main.swift @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/InspectionCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 8 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/source.mp4"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 8 \
  -vf "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable='between(t,3,4)'" \
  -af "volume=0:enable='between(t,3,4)'" -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/rendered.mp4"
SRTFLOW_INSPECTION_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/InspectionCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
