#!/usr/bin/env bash
# 录屏收尾的真实 App 对象回归：后台工程、晚到 Stop、会话附言、失败文件与本地化；不启动用户 App，不录真实屏幕。
# 独立 bundle 隔离偏好 / 账本，只使用临时媒体；复用完整 App 的目标文件。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/RecordingFeedbackCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.recordingfeedbackcheck</string>
<key>CFBundleExecutable</key><string>RecordingFeedbackCheck</string>
<key>CFBundleName</key><string>RecordingFeedbackCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
# L10n 从主 bundle 取语言表，和正式打包一样平铺；Bundle.module 仍保留上面的两条相对位置。
if [ -d "${BUILD_DIR}/SrtFlow_SrtFlow.bundle/Contents/Resources" ]; then
  ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle/Contents/Resources" "${APP}/Contents/Resources"
else
  ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources"
fi
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/ScreenRecordingFeedback/Main.swift checks/ScreenRecordingFeedback/Checks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/RecordingFeedbackCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=24 \
  -t 1 -c:v libx264 -pix_fmt yuv420p "${ROOT}/work/recorded.mov"
SRTFLOW_RECORDING_FEEDBACK_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/RecordingFeedbackCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=120, check=True)
PYTHON
