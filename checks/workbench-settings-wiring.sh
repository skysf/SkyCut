#!/usr/bin/env bash
# 扫描守卫：单排工作台、三个入口的同一设置窗口、MCP 设置复用原 Store。
# 行为和双向同步另由真实 App / 小程序冒烟验证；不把源码接线当作 GUI 已点通。
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "✗ workbench-settings：$1" >&2; exit 1; }
require() { grep -qF "$2" "$1" || fail "$1 缺少 $2"; }
APP=Sources/SrtFlow/SrtFlowApp.swift
VIEW=Sources/SrtFlow/VideoEditView.swift
BAR=Sources/SrtFlow/VideoEditWorkbenchToolbar.swift
MORE=Sources/SrtFlow/WorkbenchToolbar.swift
SETTINGS=Sources/SrtFlow/SettingsWindowView.swift
TOOLS=Sources/SrtFlow/AISettingsTools.swift
ROUTER=Sources/SrtFlow/AIToolRouter.swift
for file in "$APP" "$VIEW" "$BAR" "$MORE" "$SETTINGS" "$TOOLS" "$ROUTER"; do
  [ -f "$file" ] || fail "找不到 ${file}，移动文件时要同步守卫"
done
require "$APP" 'SettingsWindowView().appLanguage()'
require "$MORE" 'SettingsLink {'
require "$VIEW" 'VideoEditWorkbenchToolbar('
require Sources/SrtFlow/AIActivityBanner.swift 'AIActivityBadgeBackground(isWorking: round.phase == .working)'
require Sources/SrtFlow/AIActivityBadgeBackground.swift '.fill(Color(nsColor: .windowBackgroundColor))'
require "$BAR" 'VideoEditProjectMenu(project: project)'
require "$BAR" '.frame(width: projectMenuWidth)'
for component in 'RecordScreenButton(project: project)' 'AIActivityBanner(project: project)' 'WorkbenchSettingsLink()' 'WorkbenchMoreMenu()'; do
  require "$BAR" "$component"
done
if grep -qE 'NavigationSplitView|AppLanguageFlagMenu' Sources/SrtFlow/MainWindowView.swift; then
  fail '主工作台不再有永久工具侧栏或国旗入口'
fi
for component in GeneralSettingsSection AIConnectSection AIRecipesList KokoroVoiceSettingsRow OptimizedMediaSettingsSection SkyStudioSettingsSection; do
  require "$SETTINGS" "${component}()"
done
require "$MORE" 'Button("AI Projects") { showsProjects = true }'
require "$MORE" 'WorkbenchAIProjectsPopover().appLanguage()'
require "$MORE" 'AIProjectsSidebarSection(isCompact: false)'
require "$MORE" 'sharedBackgroundVisibility(.hidden)'
require "$TOOLS" 'AppLanguageStore.shared.language = language'
require "$TOOLS" 'OptimizedMediaCacheSettings.shared.setCapacity('
require "$TOOLS" 'OptimizedMediaCacheSettings.shared.clear()'
require "$TOOLS" 'SkyStudioSpendStore.shared.setDailyLimit(limit)'
require "$ROUTER" 'case .getSettings: return try await AISettingsTools.read(args)'
require "$ROUTER" 'case .setSettings: return try await AISettingsTools.update(args)'
if grep -qE 'UserDefaults|SkyStudioKey|KeychainSecret|\.removeAll\(' "$TOOLS"; then
  fail '设置工具不得旁路 Store、钥匙串或缓存清空模型'
fi
require Sources/SrtFlow/AIActivityBanner.swift 'if round.phase != .working {'
require Sources/SrtFlow/AIActivityBanner.swift 'Button { showsDetails.toggle() }'
require Sources/SrtFlow/AIActivityBanner.swift 'jobs.count == 1'
require Sources/SrtFlow/AIActivityBanner.swift 'progress.isFinite'
require Sources/SrtFlow/SkyStudio/SkyStudioSettingsSection.swift '.onChange(of: spend.dailyLimit)'
echo '✓ workbench-settings：同一工具栏与设置窗口，MCP 经原 Store，AI 状态与真实任务进度接线齐全'
