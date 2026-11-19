#!/usr/bin/env bash
# 完整 App 的参数边界 / 原子编辑 / 素材加载恢复。独立 bundle 与临时工程，不启动用户 App。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
APP="${ROOT}/ParameterLimitCheck.app"
test_app_cleanup_on_exit "${APP}" "${ROOT}"
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
  checks/ParameterLimits/Fixture.swift checks/ParameterLimits/BlackBarChecks.swift \
  checks/ParameterLimits/EditingFeedbackChecks.swift checks/ParameterLimits/Main.swift \
  checks/ParameterLimits/AddClipsChecks.swift checks/ParameterLimits/CanvasLinkageChecks.swift \
  checks/ParameterLimits/ListenGainChecks.swift checks/ParameterLimits/SpeechDuckAppChecks.swift \
  checks/ParameterLimits/VoiceBandAppChecks.swift \
  checks/ParameterLimits/MusicPlacementChecks.swift \
  checks/ParameterLimits/TimeBoundChecks.swift checks/ParameterLimits/TimeBoundCatalog.swift \
  checks/ParameterLimits/TimeBoundEdgeChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/ParameterLimitCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=160x90:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/source.mp4"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=red:s=160x90 \
  -frames:v 1 "${ROOT}/work/image.png"
# Thin unequal bars expose resampling errors; a second full-frame shot exposes probes of the old source window.
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'color=c=white:s=1890x1080:r=24,drawbox=x=0:y=0:w=iw:h=23:color=black:t=fill,drawbox=x=0:y=ih-31:w=iw:h=31:color=black:t=fill' \
  -t 0.5 -an -c:v libx264 -g 1 -crf 10 -pix_fmt yuv420p "${ROOT}/work/thin-bars.mp4"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'color=c=white:s=480x270:r=24,drawbox=x=0:y=0:w=iw:h=28:color=black:t=fill:enable=lt(t\,0.5),drawbox=x=0:y=ih-28:w=iw:h=28:color=black:t=fill:enable=lt(t\,0.5)' \
  -t 1 -an -c:v libx264 -g 1 -crf 10 -pix_fmt yuv420p "${ROOT}/work/changing-bars.mp4"
# A plain tone for the audio-track scenarios of add_clips (AddClipsChecks.swift).
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i sine=frequency=220:sample_rate=48000 -t 20 \
  -c:a aac "${ROOT}/work/tone.m4a"
SRTFLOW_PARAMETER_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/ParameterLimitCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
