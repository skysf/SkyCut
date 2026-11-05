#!/bin/bash
# 主题的偏好与生产色表；不启动 App，不依赖图形会话，也不写用户的正式设置。
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp/}srtflow-theme.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -wmo \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/AppTheme.swift \
  Sources/SrtFlow/AppThemePalette.swift \
  Sources/SrtFlow/AppThemeAppearance.swift \
  Sources/SrtFlow/TimelineMagnetSymbol.swift \
  checks/AppTheme/main.swift \
  -o "${WORK}/check-app-theme"
"${WORK}/check-app-theme"
