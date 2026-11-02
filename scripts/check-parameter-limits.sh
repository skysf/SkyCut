#!/usr/bin/env bash
# 完整 App 的参数边界 / 原子编辑 / 素材加载恢复。独立 bundle 与临时工程，不启动用户 App。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/ParameterLimitCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.parameterlimitscheck</string>
<key>CFBundleExecutable</key><string>ParameterLimitCheck</string>
<key>CFBundleName</key><string>ParameterLimitCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/ParameterLimits/Fixture.swift checks/ParameterLimits/Main.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/ParameterLimitCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=160x90:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/source.mp4"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=red:s=160x90 \
  -frames:v 1 "${ROOT}/work/image.png"
SRTFLOW_PARAMETER_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/ParameterLimitCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
