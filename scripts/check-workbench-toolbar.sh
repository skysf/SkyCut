#!/usr/bin/env bash
# 原生 SwiftUI 徽章像素检查；随 GUI 冒烟手动跑，不在无图形会话的 check-all 里启动 AppKit。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp/}skycut-workbench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/AIActivityBadgeBackground.swift \
  checks/Workbench/ToolbarChecks.swift \
  -o "$WORK/check-workbench"
"$WORK/check-workbench"
