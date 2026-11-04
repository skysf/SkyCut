#!/usr/bin/env bash
# 引擎定位的真实子进程生命周期；仅合成脚本，不读媒体、不访问云端、不启动 App。
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT="$(mktemp -d)"
cleanup() {
  local result=$?
  if [ "${result}" -eq 0 ]; then
    rm -rf "${CHECK_ROOT}"
  else
    printf 'Probe diagnostics retained at %s\n' "${CHECK_ROOT}" >&2
  fi
}
trap cleanup EXIT
xcrun swiftc -target arm64-apple-macosx15.0 -wmo -o "${CHECK_ROOT}/engine-probe-check" \
  Sources/SrtFlow/FFmpegRuntime.swift \
  Sources/SrtFlow/FFmpegRuntimeProbe.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/Quarantine.swift \
  checks/EngineProbe/Main.swift \
  checks/EngineProbe/RuntimeChecks.swift \
  checks/EngineProbe/ReapChecks.swift
python3 checks/EngineProbe/Watchdog.py "${CHECK_ROOT}/engine-probe-check"
