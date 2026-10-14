#!/usr/bin/env bash
# 主线程心跳看门狗的自检：主线程没卡不许误报；卡过阈值记一次（时长、context、栈里有卡住的函数）；
# 日志文件里有同样的内容；stop 之后不再记；挂起主线程期间抓栈线程不许分配 / 释放内存（第 6 组）、主线程不停
# 分配内存时连续抓栈不许卡死（第 7 组）—— 约束见 docs/architecture/main-thread-stack-capture.md。
# 合同见 docs/testing/main-thread-stalls.md。
#
# 用法：
#   scripts/check-main-thread-watchdog.sh
#
# 与 check-timeline-zoom.sh 同一套编法：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个
# target 共用源文件，所以单独编成自检二进制来跑。这两个文件只 import Foundation / Darwin / os，
# 不拖工程和界面。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/watchdogcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo -g \
  -o "$OUT" \
  Sources/SrtFlow/MainThreadStackCapture.swift \
  Sources/SrtFlow/MainThreadWatchdog.swift \
  checks/MainThreadWatchdog/main.swift \
  checks/MainThreadWatchdog/NoAllocationWhileSuspended.swift \
  checks/MainThreadWatchdog/CaptureUnderMallocChurn.swift \
  checks/MainThreadWatchdog/CrashProbe.swift

# 第 7 组卡死时，自检进程里判卡死的线程会自己报红退出；这里再兜一道：2 分钟还没跑完就杀掉、判红，
# 免得 CI 一直挂到作业超时。
echo "==> 运行（排查偶发 Bus error：连跑多遍，崩了就打出崩溃报告）"
sw_vers || true
ulimit -a || true
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
touch "$(dirname "$OUT")/stamp"
for i in $(seq 1 120); do
  STATUS=0
  "$OUT" > "$(dirname "$OUT")/run.log" 2>&1 || STATUS=$?
  echo "run $i status $STATUS: $(tail -1 "$(dirname "$OUT")/run.log")"
  if [ "$STATUS" -ne 0 ]; then
    cat "$(dirname "$OUT")/run.log"
    sleep 20
    for report in $(find "$REPORTS" /Library/Logs/DiagnosticReports -newer "$(dirname "$OUT")/stamp" -name 'watchdogcheck*' 2>/dev/null); do
      echo "==== $report"
      cat "$report"
    done
    exit 1
  fi
done
exit 0
