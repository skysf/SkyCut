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
  checks/VideoInspection/*.swift @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/InspectionCheck"
FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 8 -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/source.mp4"
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=blue:s=320x180:r=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 8 \
  -vf "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable='between(t,3,4)'" \
  -af "volume=0:enable='between(t,3,4)'" -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac "${ROOT}/work/rendered.mp4"
# 夹帧（checks/VideoInspection/StrayFrameChecks.swift）：素材自己在第 129 帧（5.375 秒）从会动的测试图切到彩条。
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i testsrc2=s=320x180:r=24 -f lavfi -i smptehdbars=s=320x180:r=24 \
  -filter_complex "[0:v]trim=end_frame=129,setpts=PTS-STARTPTS,format=yuv420p[a];[1:v]trim=end_frame=63,setpts=PTS-STARTPTS,format=yuv420p[b];[a][b]concat=n=2:v=1:a=0[v]" \
  -map "[v]" -c:v libx264 -g 12 -bf 0 -pix_fmt yuv420p "${ROOT}/work/cuts-source.mp4"
# 成片逐帧扫：测试图 72 帧 | 彩条 2 帧 | 测试图 46 帧 | 白 9 帧 | 测试图 24 帧 | 不动的彩条 168 帧 | 黑 24 帧 | 测试图 48 帧，带正弦音。
"${FFMPEG}" -hide_banner -loglevel error -nostdin -f lavfi -i testsrc2=s=320x180:r=24 -f lavfi -i smptehdbars=s=320x180:r=24 \
  -f lavfi -i color=c=white:s=320x180:r=24 -f lavfi -i color=c=black:s=320x180:r=24 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -filter_complex "[0:v]split=4[t1][t2][t3][t4];[1:v]split=2[s1][s2];\
[t1]trim=start_frame=0:end_frame=72,setpts=PTS-STARTPTS,format=yuv420p[a];[s1]trim=end_frame=2,setpts=PTS-STARTPTS,format=yuv420p[x];\
[t2]trim=start_frame=100:end_frame=146,setpts=PTS-STARTPTS,format=yuv420p[b];[2:v]trim=end_frame=9,setpts=PTS-STARTPTS,format=yuv420p[w];\
[t3]trim=start_frame=200:end_frame=224,setpts=PTS-STARTPTS,format=yuv420p[c];[s2]trim=end_frame=168,setpts=PTS-STARTPTS,format=yuv420p[f];\
[3:v]trim=end_frame=24,setpts=PTS-STARTPTS,format=yuv420p[k];[t4]trim=start_frame=300:end_frame=348,setpts=PTS-STARTPTS,format=yuv420p[e];\
[a][x][b][w][c][f][k][e]concat=n=8:v=1:a=0[v]" \
  -map "[v]" -map 4:a -t 16.375 -c:v libx264 -g 48 -bf 0 -pix_fmt yuv420p -c:a aac "${ROOT}/work/scan-film.mp4"
SRTFLOW_INSPECTION_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${FFMPEG}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/InspectionCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=240, check=True)
PYTHON
