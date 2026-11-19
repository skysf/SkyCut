#!/bin/bash
# 起落点路由探针，打印每一格的中心点（全局屏幕坐标、左上原点）。
#
# 用法：
#   scripts/gui-smoke/drop-routing-probe/probe.sh
# 然后：
#   外部拖入 —— scripts/gui-smoke/external-file-drag/replay.sh <任意文件> <x> <y>
#               （op=1 被接受、op=0 没人要），再看探针日志里是哪一格收到了回调；
#   App 内拖动 —— 人手把顶上的 A / B 卡片拖到各格上（合成事件驱动不了 `.onDrag`）。
#
# 各格是什么组合、2026-09-23 测出来的结果，见
# docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md。
# 需要「辅助功能」权限才能跑 replay.sh，同 GUI 冒烟的其余部分。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../test-app-cleanup.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/srtflow-drop-probe.XXXXXX")"
APP="$OUT/DropProbe.app"
LOG="$OUT/probe.log"
cleanup() {
  pkill -f "$APP/Contents/MacOS/DropProbe" 2>/dev/null || true
  remove_test_app "$APP"
}
trap cleanup EXIT
test_app_exit_signals
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DropProbe</string>
<key>CFBundleIdentifier</key><string>com.srtflow.dropprobe</string>
<key>CFBundleName</key><string>DropProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key>
<array>
  <dict><key>UTTypeIdentifier</key><string>com.probe.alpha</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array></dict>
  <dict><key>UTTypeIdentifier</key><string>com.probe.beta</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array></dict>
</array>
</dict></plist>
PLIST
# 测试类型必须声明：没声明的类型系统认不出，拖放会被静默拒绝，实验结论就会被带偏
#（2026-09-23 踩过，docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md）。

# Rosetta 终端下显式编 arm64（见 docs/build/）。
xcrun swiftc -target arm64-apple-macosx15.0 -O -o "$APP/Contents/MacOS/DropProbe" "$HERE/Probe.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1

open -n -a "$APP" --args "$LOG"
sleep 3

echo "探针日志：${LOG}"
grep 'REGION' "$LOG" | sed 's/^[0-9.]* REGION /  /' | sort
echo "Leave this command running while probing. Quit the probe or press Ctrl-C to clean up."
while pgrep -f "$APP/Contents/MacOS/DropProbe" >/dev/null; do sleep 1; done
