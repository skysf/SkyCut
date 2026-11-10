#!/usr/bin/env bash
# 声音库界面的离屏渲染：生产的视图 + 假 Sky Studio，英 / 中 / 西三种界面语言各出一套 PNG（给 PR 附图、发版前看排版）。
# 用法：scripts/render-voice-library.sh <输出目录>
# 要图形会话（建真的 NSWindow，摆在屏幕外、不抢前台），**不在 check-all.sh 里**；不碰网络、钥匙串、麦克风，不花钱，不动用户的 SkyCut。
# 复用完整 App 的目标文件（同 scripts/check-voice-recovery.sh），独立的 bundle id 隔离设置。
set -euo pipefail
OUT_DIR="${1:?用法：scripts/render-voice-library.sh <输出目录>}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/VoiceLibraryRender.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.voicelibraryrender</string>
<key>CFBundleExecutable</key><string>VoiceLibraryRender</string>
<key>CFBundleName</key><string>VoiceLibraryRender</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# 资源包两条定位都要命中（Bundle.module）；字符串表另外平铺进 Contents/Resources（同 build-app.sh）：
# 只拷 .bundle 的话 Bundle.main 里没有本地化目录，选什么语言都是英文。
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
for table in "${BUILD_DIR}/SrtFlow_SrtFlow.bundle"/*.lproj; do
  ditto "${table}" "${APP}/Contents/Resources/$(basename "${table}")"
done
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -I "${BUILD_DIR}/Modules" \
  checks/VoiceRecovery/Fixture.swift checks/VoiceRecovery/LibraryFixture.swift checks/VoiceRecovery/VoiceChangeFixture.swift \
  checks/VoiceLibraryUI/Render.swift checks/VoiceLibraryUI/RenderVoiceChange.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/VoiceLibraryRender"
SRTFLOW_VOICE_RENDER_OUT="${OUT_DIR}" SRTFLOW_VOICE_RENDER_WORK="${ROOT}/work" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/VoiceLibraryRender" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
