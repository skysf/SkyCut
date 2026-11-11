#!/bin/bash
# 主题必须接进真实呈现根、设置、轨道与 MCP；不允许靠换视图身份刷新而丢失编辑器状态。
set -euo pipefail
cd "$(dirname "$0")/.."
require() { grep -qF "$2" "$1" || { echo "FAIL: app-theme: $1 is missing $2" >&2; exit 1; }; }
require Sources/SrtFlow/AppTheme.swift 'SrtFlow.ui.theme.v1'
require Sources/SrtFlow/AppTheme.swift '?? .forest'
require Sources/SrtFlow/AppThemeAppearance.swift 'PerfCounters.isEnabled ? nil : .standard'
require Sources/SrtFlow/AppLanguage.swift 'modifier(AppLanguageModifier()).appTheme()'
require Sources/SrtFlow/SettingsWindowView.swift 'AppThemePicker()'
require Sources/SrtFlow/AppThemeAppearance.swift 'Picker("Theme"'
# 呈现根交给 SwiftUI 的浅 / 深永远是明确的 .light / .dark：经典色换成系统此刻的那一个，不交 nil。交过 .light 再交 nil，
# SwiftUI 只把窗口的外观还给系统、不撤掉内容里的浅色（系统深色时森林色 → 经典色：窗框深、内容浅，sheet 整个停在浅色，
# docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md）。真窗口里的回归是 scripts/check-theme-switch.sh。
require Sources/SrtFlow/AppThemeAppearance.swift '.preferredColorScheme(palette.resolvedColorScheme(system: SystemColorScheme.shared.value))'
require Sources/SrtFlow/AppThemePalette.swift 'func resolvedColorScheme(system: @autoclosure () -> ColorScheme) -> ColorScheme {'
require Sources/SrtFlow/AppThemeAppearance.swift 'NSApplication.shared.observe(\.effectiveAppearance)'
# 全仓只有呈现根那一处 .preferredColorScheme（别处再交一个，就可能又交出 nil、或者和主题的规矩打架）。
SCHEMES="$(grep -rn --include='*.swift' '\.preferredColorScheme(' Sources/SrtFlow | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' || true)"
if [ "$(printf '%s\n' "${SCHEMES}" | grep -c 'preferredColorScheme' || true)" -ne 1 ]; then
  echo "FAIL: app-theme: only AppThemeModifier may call .preferredColorScheme (it must never get nil); found:" >&2
  printf '%s\n' "${SCHEMES}" >&2
  exit 1
fi
# 经典色跟的「系统」是 NSApp.effectiveAppearance：SkyCut 自己一设 NSApp.appearance，它就不再是系统的了。
if grep -rnE --include='*.swift' '(NSApp|NSApplication\.shared)\.appearance[[:space:]]*=' Sources/SrtFlow >/dev/null; then
  echo "FAIL: app-theme: Sources must not set NSApp.appearance (SystemColorScheme reads it as the system's light / dark)" >&2
  grep -rnE --include='*.swift' '(NSApp|NSApplication\.shared)\.appearance[[:space:]]*=' Sources/SrtFlow >&2
  exit 1
fi
# 自建窗口里宿主视图垫在别的视图下（addSubview）时，`.preferredColorScheme` 改不到那个窗口（它只改「宿主就是 contentView」的）：
# 窗口要自己按主题设外观，不然系统深色时森林色的深字落在深色材质上（docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md）。
for file in $(grep -rl --include='*.swift' 'NSHostingView(' Sources/SrtFlow); do
  if grep -q 'addSubview(' "${file}" && ! grep -qF '.appearance = AppThemePalette.current.windowAppearance' "${file}"; then
    echo "FAIL: app-theme: ${file} nests an NSHostingView in another view but never sets the window's .appearance = AppThemePalette.current.windowAppearance" >&2
    exit 1
  fi
done
require Sources/SrtFlow/VideoEditTimelineClipBlock.swift 'AppThemePalette.current.trackFill('
require Sources/SrtFlow/VideoEditTimelineHeaderColumn.swift 'AppThemePalette.current.trackAccent('
require Sources/SrtFlow/VideoEditTimelineWaveform.swift 'normalColor: waveformColor'
require Sources/SrtFlow/VideoEditView.swift '.background(AppThemePalette.current.previewSurround)'
require Sources/SrtFlow/VideoEditTimelineRuler.swift '.fill(AppThemePalette.current.playhead)'
require Sources/SrtFlow/VideoEditToolbarIcons.swift 'icon: TimelineThemeIcons.snapping'
require Sources/SrtFlow/VideoEditToolbarIcons.swift 'icon: TimelineThemeIcons.followPlayhead'
require Sources/SrtFlow/AISettingsTools.swift 'AppThemeStore.shared.setTheme(theme)'
require Sources/SrtFlowMCPKit/MCPSettingsTools.swift 'oneOf: ["forest", "classic"]'
if grep -E '\.id\(|scheduleRebuild|VideoEditProject|PlayerClock' Sources/SrtFlow/AppThemeAppearance.swift >/dev/null; then
  echo 'FAIL: changing a theme must not replace the editor or rebuild its media' >&2
  exit 1
fi
echo 'PASS: theme roots, hand-built panel appearance, native settings, palette, toolbar and MCP wiring.'
