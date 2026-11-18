#!/usr/bin/env bash
# 动效预设的离屏出图（docs/architecture/motion-presets.md）：加字的「动效预设」一栏、检查器「动画」区的「预设」（英 / 中 / 西 ×
# 森林色 / 经典色深色），三套预设各几帧的预览和成片（16:9、9:16），一张张 PNG 给合并前看。
# Usage: scripts/render-motion-presets.sh <output directory> [--web-only|--official-only]
# --web-only captures the real shared library and web inspector without running native export comparisons.
# --official-only captures official library cards/forms and decodes the bundled movie previews, without starting render helpers.
# 要图形会话（建真的 NSWindow，摆在屏幕外、不抢前台；screencapture 用起这个脚本的终端的录屏权限）和 ffmpeg（成片那一半：
# SRTFLOW_FFMPEG，默认 vendor/ffmpeg），**不在 check-all.sh 里**；不碰网络、钥匙串，不动用户的 SkyCut 和设置（独立的 bundle id）。
# 复用完整 App 的目标文件（同 scripts/render-voice-library.sh）。
set -euo pipefail
OUT_DIR="${1:?用法：scripts/render-motion-presets.sh <输出目录>}"
WEB_ONLY=0
OFFICIAL_ONLY=0
case "${2:-}" in
  "") ;;
  --web-only) WEB_ONLY=1 ;;
  --official-only) OFFICIAL_ONLY=1 ;;
  *) echo "Usage: scripts/render-motion-presets.sh <output directory> [--web-only|--official-only]" >&2; exit 2 ;;
esac
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ "${WEB_ONLY}" -eq 0 ] && [ "${OFFICIAL_ONLY}" -eq 0 ]; then
  [ -x "${FFMPEG}" ] || { echo "找不到 ffmpeg：${FFMPEG}（设 SRTFLOW_FFMPEG）" >&2; exit 1; }
fi
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
if [ "${WEB_ONLY}" -eq 1 ]; then
  BUILD_OUT="$(swift build --arch arm64 --product skycut-web-motion 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
fi
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/MotionPresetRender.app"
BUNDLE_ID="com.srtflow.SrtFlow.motionpresetrender.run$$"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Helpers" "${ROOT}/web-project"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>MotionPresetRender</string>
<key>CFBundleName</key><string>MotionPresetRender</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# 资源包两条定位都要命中（Bundle.module）；字符串表另外平铺进 Contents/Resources（同 build-app.sh）。
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
for table in "${BUILD_DIR}/SrtFlow_SrtFlow.bundle"/*.lproj; do
  ditto "${table}" "${APP}/Contents/Resources/$(basename "${table}")"
done
# Match the packaged-app lookup contract: AppResources finds flattened files in Contents/Resources.
RES_BUNDLE="${BUILD_DIR}/SrtFlow_SrtFlow.bundle"
if [ -d "${RES_BUNDLE}/Contents/Resources" ]; then
  ditto "${RES_BUNDLE}/Contents/Resources" "${APP}/Contents/Resources"
else
  ditto "${RES_BUNDLE}" "${APP}/Contents/Resources"
fi
rm -f "${APP}/Contents/Resources/Info.plist"
if [ "${WEB_ONLY}" -eq 1 ]; then
  cp "${BUILD_DIR}/skycut-web-motion" "${APP}/Contents/Helpers/skycut-web-motion"
fi
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -I "${BUILD_DIR}/Modules" \
  checks/MotionPresetUI/Render.swift checks/MotionPresetUI/RenderFrames.swift checks/MotionPresetUI/RenderWebMotion.swift \
  checks/MotionPresetUI/RenderOfficialMotion.swift \
  checks/OffscreenRender/Snapshot.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/MotionPresetRender"
SRTFLOW_MOTION_RENDER_OUT="${OUT_DIR}" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_MOTION_RENDER_WEB_ONLY="${WEB_ONLY}" SRTFLOW_MOTION_RENDER_WORK="${ROOT}/web-project" \
SRTFLOW_MOTION_RENDER_OFFICIAL_ONLY="${OFFICIAL_ONLY}" \
SRTFLOW_WEB_MOTION_HELPER="${APP}/Contents/Helpers/skycut-web-motion" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/MotionPresetRender" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=600, check=True)
PYTHON
