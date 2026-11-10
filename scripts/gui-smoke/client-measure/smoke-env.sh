#!/bin/bash
# 真客户端实测用的隔离环境（MCP 按需说明方案第六节）：独立测试 App 身份 + 自己的回环端口上的假 Sky Studio + 假 Key。
# 和 scripts/gui-smoke/sky-studio/run.sh 同一套做法，只是身份、端口、目录都能换（并行的会话互不相撞），并且 assemble 和 start 分开：
# assemble 从给定仓库的 .build 里拷出 App 和小程序（拷完就和仓库无关，仓库可以换提交），start / stop 只管进程。
#
#   MEASURE_DIR=<目录> smoke-env.sh assemble <仓库>   # 组装 App、拷 ffmpeg 和假服务、造假服务的素材
#   MEASURE_DIR=<目录> smoke-env.sh start              # 起假服务和 App，等 socket
#   MEASURE_DIR=<目录> smoke-env.sh stop               # 停 App 和假服务，删测试身份的钥匙串项、设置、支持目录
# 可选：MEASURE_BUNDLE（默认 com.srtflow.SrtFlow.measure.skystudiosmoke，必须以 .skystudiosmoke 结尾：假 Key 只认这种身份）、
#      MEASURE_PORT（默认 18797）。不碰正式版、测试版、用户的工程和钥匙串里别的项；不发任何收费请求。
set -euo pipefail
D="${MEASURE_DIR:?set MEASURE_DIR}"
BUNDLE="${MEASURE_BUNDLE:-com.srtflow.SrtFlow.measure.skystudiosmoke}"
PORT="${MEASURE_PORT:-18797}"
NAME=SrtFlowMeasureSmoke
APP="$D/$NAME.app"
SUPPORT="$HOME/Library/Application Support/$BUNDLE"
KEY="sk-SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS"
case "$BUNDLE" in *.skystudiosmoke) ;; *) echo "MEASURE_BUNDLE must end with .skystudiosmoke" >&2; exit 2 ;; esac

stop() {
  pkill -f "$APP/Contents/MacOS/$NAME" 2>/dev/null || true
  if [ -f "$D/server.pid" ]; then
    local pid command
    pid="$(cat "$D/server.pid")"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in *"$D/fixture-repo/scripts/gui-smoke/sky-studio/server.py $PORT $D/assets "*) kill "$pid" 2>/dev/null || true ;; esac ;;
    esac
  fi
  rm -f "$D/server.pid"
  security delete-generic-password -a api-key -s "$BUNDLE.skystudio" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE" >/dev/null 2>&1 || true
  # 只删这个测试身份自己的目录（名字里一定带 .skystudiosmoke，上面已核对）。
  rm -rf "$SUPPORT" "$HOME/Library/Caches/$BUNDLE" "$HOME/Library/Saved Application State/$BUNDLE.savedState"
}

assemble() {
  local repo="$1" build res plist
  build="$(cd "$repo" && swift build --arch arm64 --show-bin-path)"
  rm -rf "$APP"
  mkdir -p "$D/assets" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
  cp "$build/SrtFlow" "$APP/Contents/MacOS/$NAME"
  res="$build/SrtFlow_SrtFlow.bundle"
  if [ -d "$res/Contents/Resources" ]; then ditto "$res/Contents/Resources" "$APP/Contents/Resources"; else ditto "$res" "$APP/Contents/Resources"; fi
  ditto "$res" "$APP/Contents/Resources/SrtFlow_SrtFlow.bundle"
  ditto "$res" "$APP/Contents/MacOS/SrtFlow_SrtFlow.bundle"
  cp "$repo/packaging/Info.plist" "$APP/Contents/Info.plist"
  plist="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NAME" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$plist"
  cp "$build/skycut-mcp" "$APP/Contents/Helpers/skycut-mcp"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  # 引擎拷一份到本轮目录、显式指过去（2026-11-03：测试包不带引擎、覆盖路径又指向 Downloads 时只得到 not ready）。
  cp "$repo/vendor/ffmpeg" "$D/ffmpeg"
  # 假服务按仓库的布局找夹具（parents[3]/checks/SkyStudio/Fixtures），所以拷一份最小的仓库布局。
  rm -rf "$D/fixture-repo"
  mkdir -p "$D/fixture-repo/scripts/gui-smoke" "$D/fixture-repo/checks/SkyStudio"
  ditto "$repo/scripts/gui-smoke/sky-studio" "$D/fixture-repo/scripts/gui-smoke/sky-studio"
  cp "$repo/scripts/gui-smoke/mcpclient.py" "$D/fixture-repo/scripts/gui-smoke/mcpclient.py"
  ditto "$repo/checks/SkyStudio/Fixtures" "$D/fixture-repo/checks/SkyStudio/Fixtures"
  rm -rf "$D/fixture-repo/scripts/gui-smoke/sky-studio/__pycache__"
  ( cd "$repo" && git rev-parse HEAD ) > "$D/app-commit.txt"
  if [ ! -s "$D/assets/narration.wav" ]; then
    say -v Samantha -r 145 -o "$D/assets/narration.aiff" "Hello world, this is the first line."
    "$D/ffmpeg" -y -v error -i "$D/assets/narration.aiff" -ac 1 -ar 44100 "$D/assets/narration.wav"
  fi
  # 假服务的成品素材和 work/ 下的几样（同 run.sh）。
  mkdir -p "$D/work"
  "$D/ffmpeg" -y -v error -stream_loop 2 -i "$D/assets/narration.wav" "$D/work/reference.wav"
  "$D/ffmpeg" -y -v error -f lavfi -i color=c=steelblue:s=640x640:r=24 -t 2 -an -c:v libx264 -pix_fmt yuv420p "$D/assets/video.mp4"
  "$D/ffmpeg" -y -v error -f lavfi -i color=c=steelblue:s=640x640 -frames:v 1 -update 1 "$D/assets/picture.png"
  cp "$D/assets/video.mp4" "$D/work/motion.mp4"
  cp "$D/assets/picture.png" "$D/work/subject.png"
  echo "assembled $APP from $(cat "$D/app-commit.txt")"
}

start() {
  stop
  mkdir -p "$D/optimized-media"
  python3 - "$PORT" "$D" <<'SERVER'
import subprocess, sys
from pathlib import Path
port, root = sys.argv[1:]
with open(root + "/server.log", "w") as log:
    server = subprocess.Popen(["python3", root + "/fixture-repo/scripts/gui-smoke/sky-studio/server.py", port, root + "/assets", root + "/ffmpeg"],
                              stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
Path(root + "/server.pid").write_text(str(server.pid))
SERVER
  python3 - "$PORT" <<'READY'
import sys, time, urllib.request
for _ in range(60):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/__log", timeout=1):
            break
    except OSError:
        time.sleep(0.5)
else:
    raise SystemExit("loopback fixture server did not become ready")
READY
  defaults write "$BUNDLE" appLanguage en
  open -g -n --env "SRTFLOW_SKYSTUDIO_API_BASE=http://127.0.0.1:$PORT/api/skycut/v1" \
    --env "SRTFLOW_SMOKE_CACHE_DIR=$D/optimized-media" --env "SRTFLOW_SMOKE_SKYSTUDIO_KEY=$KEY" \
    --env "SRTFLOW_FFMPEG=$D/ffmpeg" --env SRTFLOW_SMOKE_MUTE=1 "$APP"
  for _ in $(seq 1 90); do
    if [ -S "$SUPPORT/mcp.sock" ]; then echo "ready: $APP (socket $SUPPORT/mcp.sock, port $PORT)"; return 0; fi
    sleep 0.5
  done
  echo "test App did not start" >&2
  return 1
}

case "${1:-}" in
  assemble) assemble "${2:?repo}" ;;
  start) start ;;
  stop) stop ;;
  *) echo "usage: MEASURE_DIR=… $0 assemble <repo> | start | stop" >&2; exit 2 ;;
esac
