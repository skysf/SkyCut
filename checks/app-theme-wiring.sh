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
require Sources/SrtFlow/AppThemeAppearance.swift '.preferredColorScheme(palette.isForest ? .light : nil)'
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
echo 'PASS: theme roots, native settings, palette, toolbar and MCP wiring.'
