#!/usr/bin/env bash
# 独立测试 App + 本机假 Sky Studio。只装假 Key，不碰生产钱包；stop 清理测试身份。
set -euo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"
D="${SKYSTUDIO_SMOKE_DIR:-/private/tmp/srtflow-skystudio-smoke}"
APP="$D/SrtFlowSkyStudioSmoke.app"
BUNDLE=com.srtflow.SrtFlow.skystudiosmoke
SUPPORT="$HOME/Library/Application Support/$BUNDLE"
PORT=18766
stop() {
  pkill -f "$APP/Contents/MacOS/SrtFlowSkyStudioSmoke" 2>/dev/null || true
  # PID 会被系统复用；App 只按完整路径停，服务器还要核对命令和本轮素材目录。
  if [ -f "$D/server.pid" ]; then
    local server_pid server_command
    server_pid="$(cat "$D/server.pid")"
    case "$server_pid" in
      ''|*[!0-9]*) ;;
      *)
        server_command="$(ps -p "$server_pid" -o command= 2>/dev/null || true)"
        case "$server_command" in
          *"scripts/gui-smoke/sky-studio/server.py $PORT $D/assets "*) kill "$server_pid" 2>/dev/null || true ;;
        esac
        ;;
    esac
  fi
  rm -f "$D/app.pid" "$D/server.pid"
  security delete-generic-password -a api-key -s "$BUNDLE.skystudio" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE" >/dev/null 2>&1 || true
  rm -f "$SUPPORT/mcp-providers.json" "$SUPPORT/mcp.sock"
}
if [ "${1:-}" = stop ]; then stop; exit 0; fi
stop
mkdir -p "$D/assets" "$D/work" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
BUILD="$(swift build --arch arm64 --show-bin-path)"
cp "$BUILD/SrtFlow" "$APP/Contents/MacOS/SrtFlowSkyStudioSmoke"
RES="$BUILD/SrtFlow_SrtFlow.bundle"
if [ -d "$RES/Contents/Resources" ]; then ditto "$RES/Contents/Resources" "$APP/Contents/Resources"; else ditto "$RES" "$APP/Contents/Resources"; fi
ditto "$RES" "$APP/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "$RES" "$APP/Contents/MacOS/SrtFlow_SrtFlow.bundle"
cp packaging/Info.plist "$APP/Contents/Info.plist"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SrtFlowSkyStudioSmoke' "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$P"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName SrtFlowSkyStudioSmoke' "$P"
cp "$BUILD/skycut-mcp" "$APP/Contents/Helpers/skycut-mcp"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
FF="${SRTFLOW_FFMPEG:-$REPO/vendor/ffmpeg}"
# 一份原生语音夹具反复使用；进程超时必须红，不能挂住后面的真 App 验证。
if [ ! -s "$D/assets/narration.wav" ]; then
  python3 - "$D/assets/narration.aiff" <<'SPEECH'
import subprocess
import sys
subprocess.run(["say", "-v", "Samantha", "-r", "145", "-o", sys.argv[1], "Hello world, this is the first line."], check=True, timeout=30)
SPEECH
  "$FF" -y -v error -i "$D/assets/narration.aiff" -ac 1 -ar 44100 "$D/assets/narration.wav"
fi
"$FF" -y -v error -stream_loop 2 -i "$D/assets/narration.wav" "$D/work/reference.wav"
"$FF" -y -v error -f lavfi -i color=c=steelblue:s=640x640:r=24 -t 2 -an -c:v libx264 -pix_fmt yuv420p "$D/assets/video.mp4"
"$FF" -y -v error -f lavfi -i color=c=steelblue:s=640x640 -frames:v 1 -update 1 "$D/assets/picture.png"
cp "$D/assets/video.mp4" "$D/work/motion.mp4"
cp "$D/assets/picture.png" "$D/work/subject.png"
python3 - "$PORT" "$D" "$FF" <<'SERVER'
from pathlib import Path
import subprocess
import sys
port, root, ffmpeg = sys.argv[1:]
with open(root + "/server.log", "w") as log:
    server = subprocess.Popen(["python3", "scripts/gui-smoke/sky-studio/server.py", port, root + "/assets", ffmpeg], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
Path(root + "/server.pid").write_text(str(server.pid))
SERVER
python3 - "$PORT" <<'READY'
import sys
import time
import urllib.request
for attempt in range(60):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/__log", timeout=1):
            break
    except OSError:
        time.sleep(0.5)
else:
    raise SystemExit("Loopback fixture server did not become ready")
READY
defaults write "$BUNDLE" appLanguage "${SRTFLOW_SMOKE_LANGUAGE:-en}"
if [ -n "${1:-}" ]; then defaults write "$BUNDLE" SrtFlow.skystudio.dailyCreditLimit -float "$1"; fi
open -g -n --env "SRTFLOW_SKYSTUDIO_API_BASE=http://127.0.0.1:$PORT/api/skycut/v1" \
  --env "SRTFLOW_SMOKE_CACHE_DIR=$D/optimized-media" \
  --env "SRTFLOW_SMOKE_SKYSTUDIO_KEY=sk-SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS" \
  --env "SRTFLOW_FFMPEG=$FF" --env SRTFLOW_SMOKE_MUTE=1 "$APP"
for _ in $(seq 1 60); do
  if [ -S "$SUPPORT/mcp.sock" ]; then echo "Local Sky Studio smoke ready: $D"; exit 0; fi
  sleep 0.5
done
echo 'Test App did not start' >&2
exit 1
