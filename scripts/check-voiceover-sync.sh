#!/usr/bin/env bash
# 真实 App 对象的旁白段落同步；合成 WAV / 视频、仅 ASR 注入，不访问云端、不启动用户 App。
# 复用完整 App 的目标文件，避免另编一份业务流程；独立 bundle 隔离设置和积分账。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/VoiceoverSyncCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.voiceoversynccheck</string>
<key>CFBundleExecutable</key><string>VoiceoverSyncCheck</string>
<key>CFBundleName</key><string>VoiceoverSyncCheck</string>
</dict></plist>
PLIST
# Bundle.module 的两条相对定位都能命中，纯对象测试不运行 SrtFlowApp.main。
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -I "${BUILD_DIR}/Modules" \
  checks/VoiceoverSync/Fixture.swift checks/VoiceoverSync/Main.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/VoiceoverSyncCheck"
# 合成真视频供原生末帧抽取 / 静帧转码；缺依赖或失败必须红，不能跳过验收。
"${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" -hide_banner -loglevel error -nostdin \
  -f lavfi -i color=c=blue:s=160x90:r=24:d=30 -an -c:v libx264 -g 1 -preset ultrafast \
  -pix_fmt yuv420p "${ROOT}/work/source.mp4"
# 外层看门狗不能放在 Swift 协作线程池里；脚本超时明确红。
SRTFLOW_VOICE_SYNC_CHECK_DIR="${ROOT}/work" \
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/VoiceoverSyncCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=180, check=True)
PYTHON
