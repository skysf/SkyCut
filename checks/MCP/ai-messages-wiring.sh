#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, never run alone): what the AI is told when SkyCut cannot do the obvious thing —
# a language that was not recognized, and SkyCut having been relaunched by the helper. Moved out of scripts/check-mcp.sh unchanged
# on 2026-11-17 when that script went over the 600-line limit (docs/architecture/coding-standards.md).

echo "==> 认不出语言时，AI 拿到的是它能照做的话"
# 自动检测没认出语言，界面那句「去面板里选」AI 做不到（docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md）。
# 检测处抛 LanguageUndetectedError，transcribe、generate_subtitles 的任务失败都经 AIHarvestFailure 换成「带上 language 再调」。
if [ "$(grep -c 'throw LanguageUndetectedError()' Sources/SrtFlow/SubtitleGen/TranscriptHarvester.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIHarvestFailure.message(' Sources/SrtFlow/AITranscribeTool.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIHarvestFailure.message(' Sources/SrtFlow/AISubtitleTools.swift || true)" -ne 1 ]; then
  echo "✗ 认不出语言没抛成 LanguageUndetectedError，或 transcribe / generate_subtitles 的失败没经 AIHarvestFailure：AI 会被叫去面板里选" >&2
  exit 1
fi
echo "   ✓ 检测处抛 LanguageUndetectedError，两个任务的失败都经 AIHarvestFailure"

echo "==> 关掉主窗口不退出；小程序把 App 拉起来的那次，结果里告诉 AI"
# 2026-10-02 南极工程：SwiftUI 单 Window 场景关窗就退出，AI 下一次调用拉起来的是空的 Untitled、打开的文件夹也没了，
# 它只看到「文件不存在」（docs/bugfixes/2026-10-03-closing-window-quits-app.md）。
if [ "$(grep -c 'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }' Sources/SrtFlow/SrtFlowApp.swift || true)" -ne 1 ]; then
  echo "✗ 关掉主窗口会退出 App（SwiftUI 单 Window 场景的默认）：工程、AI 打开的文件夹全没了" >&2
  exit 1
fi
if [ "$(grep -c 'return launched ? MCPBridge.addingNote(MCPBridge.relaunchNote, to: result) : result' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'return (fd, true)' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ]; then
  echo "✗ 小程序把 App 拉起来之后没在结果里告诉 AI（之前打开的工程、文件夹都不在了）" >&2
  exit 1
fi
echo "   ✓ 关窗口不退出；拉起 App 的那一次结果带 relaunchNote"
