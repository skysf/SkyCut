#!/usr/bin/env bash
# **主题切换的真实回归**：开着的主窗口（SwiftUI 场景）、工程窗口、录屏控制条、sheet、popover、提示面板，
# 切主题、系统切深浅色之后，窗框、SwiftUI 读到的浅 / 深、画出来的底色都要和新主题一致
# （森林色永远浅；经典色跟系统，系统再切也跟着）。
#
# 由来（docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md）：经典色交给 SwiftUI 的是
# `.preferredColorScheme(nil)`，交过 `.light` 再交 nil 时 SwiftUI 不撤掉之前的浅色 —— 系统深色时森林色 → 经典色，
# 窗框深、内容浅，sheet 整个停在浅色。
#
# 用法：
#   scripts/check-theme-switch.sh
#
# 要图形会话（真建窗口、真弹 sheet / popover），**不在 check-all.sh 里**，改主题的浅 / 深、呈现根、
# 自建窗口的外观时手动跑。窗口都放在屏幕外，只有 SwiftUI 的场景窗口启动时可能在左下角闪一下；
# 用 .accessory 策略，不抢焦点、不进 Dock。系统的深浅色只在这个进程里模拟，不碰用户的系统设置。
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp/}srtflow-theme-switch.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "==> 编译自检二进制"
# 诊断走 stdout：失败要倾倒完整输出，不许 >/dev/null 吞掉（docs/bugfixes/ 2026-08-08 CI 首跑案例）。
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -o "${WORK}/check-theme-switch" \
  Sources/SrtFlow/InstantTooltip.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AppTheme.swift \
  Sources/SrtFlow/AppThemePalette.swift \
  Sources/SrtFlow/AppThemeAppearance.swift \
  checks/ThemeSwitch/ThemeSwitchChecks.swift

echo "==> 运行"
# 要切主题：开着 PerfCounters 时主题 Store 不读写偏好（AppThemeAppearance.swift），不会在
# ~/Library/Preferences 里留下这个自检的文件，也读不到上一次留下的主题。
SRTFLOW_SMOKE_SCRIPT=check-theme-switch "${WORK}/check-theme-switch"
