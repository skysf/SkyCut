#!/bin/bash
# 真客户端实测的母版（MCP 按需说明方案 6.3）：合成素材 + 经 MCP 在隔离的测试 App 里建的工程，和 2026-11-03 同一个形状
# （两段 2 秒 640×640 / 24fps 画面、0–4 秒旧旁白、两处 2 秒 / 40 号标题），外加任务 5、6 用的四段 5 秒素材、任务 8 要删的 old.mp4。
#
#   MEASURE_DIR=<环境> MEASURE_FIXTURE=<母版目录> make_fixture.sh <仓库>
# 先 smoke-env.sh assemble + start。工程建在 <母版>/SkyCut/Projects/Review.skycut；建它的会话之后不再碰它（run_*.py 每个任务前重启 App，
# 拷一份、改路径再用）。不用任何用户的工程或素材。
set -euo pipefail
REPO="${1:?repo}"
D="${MEASURE_DIR:?}"
F="${MEASURE_FIXTURE:?}"
BUNDLE="${MEASURE_BUNDLE:-com.srtflow.SrtFlow.measure.skystudiosmoke}"
APP="$D/SrtFlowMeasureSmoke.app"
FF="$D/ffmpeg"
rm -rf "$F"
mkdir -p "$F"
"$FF" -y -v error -f lavfi -i testsrc2=s=640x640:r=24 -t 2 -an -c:v libx264 -pix_fmt yuv420p "$F/shot-a.mp4"
"$FF" -y -v error -f lavfi -i smptebars=s=640x640:r=24 -t 2 -an -c:v libx264 -pix_fmt yuv420p "$F/shot-b.mp4"
cp "$D/work/reference.wav" "$F/old_voice.wav"   # 本机 Samantha 合成的那一句循环三遍，约 7.33 秒
cp "$D/assets/narration.wav" "$F/new_voice.wav" # 那一句本身，约 2.443 秒
"$FF" -y -v error -f lavfi -i testsrc2=s=1280x720:r=30 -t 5 -an -c:v libx264 -pix_fmt yuv420p "$F/broll-1.mp4"
"$FF" -y -v error -f lavfi -i mandelbrot=s=1280x720:r=30 -t 5 -an -c:v libx264 -pix_fmt yuv420p "$F/broll-2.mp4"
"$FF" -y -v error -f lavfi -i life=s=1280x720:r=30:mold=10:ratio=0.2 -t 5 -an -c:v libx264 -pix_fmt yuv420p "$F/broll-3.mp4"
"$FF" -y -v error -f lavfi -i rgbtestsrc=s=1280x720:r=30 -t 5 -an -c:v libx264 -pix_fmt yuv420p "$F/broll-4.mp4"
cp "$F/shot-b.mp4" "$F/old.mp4"
CALLS="$(mktemp -d)/fixture-calls.json"
cat > "$CALLS" <<EOF
[
 {"name": "get_status", "arguments": {}},
 {"name": "set_view", "arguments": {"mode": "background"}},
 {"name": "open_folder", "arguments": {"path": "$F"}},
 {"name": "new_project", "arguments": {"name": "Review"}},
 {"name": "add_clips", "arguments": {"clips": [
   {"file": "shot-a.mp4", "track": "V1", "start": 0},
   {"file": "shot-b.mp4", "track": "V1", "start": 2},
   {"file": "old_voice.wav", "track": "A1", "start": 0, "source_out": 4}]}},
 {"name": "set_text", "arguments": {"text": "Opening title", "start": 0, "duration": 2, "font_size": 40}},
 {"name": "set_text", "arguments": {"text": "Closing title", "start": 2, "duration": 2, "font_size": 40}},
 {"name": "save_project", "arguments": {}},
 {"name": "get_timeline", "arguments": {}}
]
EOF
SRTFLOW_MCP_HELPER="$APP/Contents/Helpers/skycut-mcp" SRTFLOW_MCP_APP="$APP" \
  SRTFLOW_MCP_SOCKET="$HOME/Library/Application Support/$BUNDLE/mcp.sock" SRTFLOW_MCP_NO_LAUNCH=1 \
  python3 "$REPO/scripts/gui-smoke/mcp-client/client.py" "$CALLS" "$(dirname "$CALLS")/out"
test -s "$F/SkyCut/Projects/Review.skycut"
echo "fixture ready: $F/SkyCut/Projects/Review.skycut"
