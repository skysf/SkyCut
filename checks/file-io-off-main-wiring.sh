#!/usr/bin/env bash
# 扫描守卫：nothing waits on a user-chosen drive or on the system's open / save panel service on the main thread.
#
# What it pins (the production wiring; the behaviour runs in scripts/check-export-profile.sh and
# scripts/check-project-saves.sh):
# - the export panel's folder window and destination (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md);
# - the AI's export_video / export_subtitles folders (2026-11-19, docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md);
# - a project's own file written off the main thread, and only the async saves in production code
#   (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md);
# - every macOS open / save window: made only in SystemFileChooser.swift, never modal
#   (2026-11-19, docs/bugfixes/2026-11-19-modal-file-windows-can-wedge-app.md);
# - a Compress / Burn In encode: ffmpeg writes only the job's own file, handed over and cleaned up off the main thread
#   (2026-11-19, docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md).
# Rules: docs/architecture/export-settings.md §8 and §5 item 8, docs/architecture/video-edit-project-file.md §5,
# docs/architecture/system-file-windows.md, docs/architecture/blocking-media-reads.md "Destination drives".
# Moved out of checks/project-file-wiring.sh on 2026-11-19 (that file reached the 600-line limit).
#
# 用法：checks/file-io-off-main-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WIRING_FAIL=0
require() { # require <描述> <文件> <正则>
  if ! grep -Eq "$3" "$2"; then
    echo "✗ 接线守卫：$1（在 $2 里找不到 /$3/）" >&2
    WIRING_FAIL=1
  fi
}
forbid() { # forbid <描述> <文件> <正则>
  if grep -Eq "$3" "$2"; then
    echo "✗ 接线守卫：$1（$2 里仍有 /$3/）" >&2
    WIRING_FAIL=1
  fi
}

# Export folder window and destination (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md):
# the macOS folder window is opened without a modal session, and nothing in the export panel or the exporter waits on
# the destination drive on the main thread. The behaviour is checked by scripts/check-export-profile.sh; this pins
# the production wiring it relies on.
for f in Sources/SrtFlow/VideoEditExportSheet.swift Sources/SrtFlow/ExportFolderRow.swift; do
  forbid "the export folder row drives its own chooser (its inline fallback), not the shared FilePicker" "$f" '^[^/]*FilePicker\.'
done
# Every macOS open / save window (2026-11-19, docs/bugfixes/2026-11-19-modal-file-windows-can-wedge-app.md): panels are
# made only in SystemFileChooser.swift, which opens them with begin and never runs one modally; the shared ones go through
# SystemFileWindows (the views' FilePicker). scripts/check-export-profile.sh (FileChooserChecks, FileWindowsChecks) checks
# the behaviour.
for f in Sources/SrtFlow/SystemFileChooser.swift Sources/SrtFlow/SystemFileWindows.swift Sources/SrtFlow/FileWindowHelper.swift \
  Sources/SrtFlow/VideoEditExportSheet.swift Sources/SrtFlow/ExportFolderRow.swift; do
  forbid "a macOS open / save window is never a modal session (a hung panel service then wedges the app)" "$f" '^[^/]*runModal'
done
PANEL_MAKERS="$(grep -rlE '^[^/]*(NSOpenPanel|NSSavePanel)\(' Sources --include='*.swift' | grep -v '^Sources/SrtFlow/SystemFileChooser\.swift$' || true)"
if [ -n "${PANEL_MAKERS}" ]; then
  echo "✗ 接线守卫：macOS open / save panels are made only in SystemFileChooser.swift (non-modal, watched): ${PANEL_MAKERS}" >&2
  WIRING_FAIL=1
fi
require "the system window opens with begin (no modal session)" Sources/SrtFlow/SystemFileChooser.swift 'panel\.begin \{'
require "the chooser leaves its in-flight record before asking AppKit for the window" \
  Sources/SrtFlow/SystemFileChooser.swift 'record\.markStarted\(\)'
require "the views' FilePicker goes through the shared non-modal windows" \
  Sources/SrtFlow/SystemFileWindows.swift 'SystemFileWindows\.shared\.open\(request'
require "the folder window never starts on a drive the last check found not answering (windowStart)" \
  Sources/SrtFlow/ExportFolderRow.swift 'chooser\.choose\(\.exportFolder\(startingAt: destination\.windowStart\)\)'
for f in Sources/SrtFlow/VideoEditExportSheet.swift Sources/SrtFlow/ExportFolderRow.swift Sources/SrtFlow/ExportDestinationState.swift; do
  forbid "the export panel never asks the destination drive itself (only ExportDestinationProbe, off the main thread)" \
    "$f" '^[^/]*FileManager\.default'
done
forbid "the subtitle files' \"already there\" comes from the destination check, not from the drive during a redraw" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift '^[^/]*FileManager\.default\.fileExists'
forbid "the exporter never moves the finished video on the main thread (ExportDelivery does, on its own queue)" \
  Sources/SrtFlow/VideoEditExporter.swift '^[^/]*\.(moveItem|replaceItemAt|fileExists)\('
require "the exporter hands the finished video over through ExportDelivery" \
  Sources/SrtFlow/VideoEditExporter.swift 'try await ExportDelivery\.deliver\('
require "the export starts only after the look-and-write check of the folder" \
  Sources/SrtFlow/VideoEditExportSheet.swift 'await destination\.exportDecision\('
# The file checked, named in the replace question and written is one URL (2026-11-19,
# docs/bugfixes/2026-11-19-export-panel-checks-one-folder-writes-another.md): the decision comes from the check before
# writing, and the sheet never exports to the folder shown at that moment.
require "pressing Export is decided from the check before writing" \
  Sources/SrtFlow/ExportDestinationState.swift 'let checked = await checkBeforeWriting\(\)'
forbid "the export writes the file the check was about, never the panel's current outputURL" \
  Sources/SrtFlow/VideoEditExportSheet.swift 'to: (\.replacing\()?outputURL'
# The AI's export_video folder (2026-11-19, docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md): made,
# checked and listed through the same probe, off the main thread; scripts/check-export-profile.sh checks the behaviour.
for f in Sources/SrtFlow/AIExportTools.swift Sources/SrtFlow/AIExportDestination.swift; do
  forbid "export_video never touches its folder on the main thread (only through ExportDestinationProbe)" \
    "$f" '^[^/]*FileManager\.default'
done
require "export_video picks its file and checks its folder through AIExportDestination" \
  Sources/SrtFlow/AIExportTools.swift 'try await AIExportDestination\.output\('
require "AIExportDestination asks the drive only through the probe (off the main thread, with a deadline)" \
  Sources/SrtFlow/AIExportDestination.swift 'await probe\.run\(on: request\.near, deadline: deadline'

# A project's own file is written off the main thread (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md):
# production code saves through saveToFile / flushToFile / saveAs / prepareToClose / startNewProject / closeProject /
# createProject (ProjectFileWriter's queue, with a deadline). The blocking ones that write on the caller's thread are for the
# checks and dev hooks only; outside their own definitions nothing in Sources/ may call them. scripts/check-project-saves.sh
# checks the behaviour.
BLOCKING='(\b(saveNow|flushAutosave|prepareToCloseDocument)\(\)|\.saveDocument\(as:|\.newProject\(\)|OpenProjects\.shared\.(close|newProject)\(|\bwriteBlocking\()'
BLOCKING_HITS="$(grep -rnE "${BLOCKING}" Sources --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*///?' \
  | grep -vE '^Sources/SrtFlow/(VideoEditProjectSaving|VideoEditProjectDocument|ProjectClosing|OpenProjects|ProjectFileWriter)\.swift:' || true)"
if [ -n "${BLOCKING_HITS}" ]; then
  echo "✗ 接线守卫：production code calls a blocking project save (it waits on the drive on the main thread; use the async one):" >&2
  echo "${BLOCKING_HITS}" >&2
  WIRING_FAIL=1
fi
for pair in 'ProjectClosing|func prepareToCloseDocument() -> Bool {' 'VideoEditProjectDocument|func newProject() {'; do
  file="Sources/SrtFlow/${pair%%|*}.swift"
  entry="${pair#*|}"
  BODY="$(awk -v start="$entry" 'index($0, start) { on = 1; next } on && /^    \}$/ { exit } on { print }' "$file")"
  [ -n "${BODY}" ] || { echo "✗ 接线守卫：${file} 里找不到 ${entry}（改了名就把这条守卫跟过去）" >&2; WIRING_FAIL=1; }
done
require "the project file is written on the writer's queue, never on the caller's (ProjectFileWriter.startNext)" \
  Sources/SrtFlow/ProjectFileWriter.swift 'queue\.async \{ \[weak self\] in'
require "the write itself is nonisolated (it never runs on the main actor)" \
  Sources/SrtFlow/ProjectFileWriter.swift 'nonisolated static func write\(_ request: ProjectFileWriteRequest\) -> ProjectFileWriteResult'
require "a save waits for the drive at most a deadline" \
  Sources/SrtFlow/VideoEditProjectSaving.swift 'await connectedWriter\(\)\.write\(request, deadline: deadline\)'
require "the dirty mark is cleared only when nothing changed since the snapshot was taken" \
  Sources/SrtFlow/VideoEditProjectSaving.swift 'if fileWriter\.revision == request\.revision \{ hasUnsavedChanges = false \}'

# Compress / Burn In (2026-11-19, docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md): ffmpeg writes only the
# job's own claimed file, which is handed over through ExportDelivery as a new file (never replacing); a failed or
# cancelled job removes only that file, and quitting stops ffmpeg and removes it. scripts/check-export-profile.sh
# (EncodeQueueChecks) checks the behaviour.
require "the encode's ffmpeg writes the job's own claimed file, never the planned name" \
  Sources/SrtFlow/EncodeJob.swift 'command: command\(claim\.url\.path\)'
require "the finished encode is handed over through ExportDelivery as a new file (off the main thread, never replacing)" \
  Sources/SrtFlow/EncodeJob.swift 'try await ExportDelivery\.deliver\(claim\.url, to: target\)'
require "a failed or cancelled encode removes only its own file (off the main thread)" \
  Sources/SrtFlow/EncodeJob.swift 'try\? await Self\.offMain \{ ExclusivePlacement\.discard\(claim\) \}'
forbid "the encode job never touches the destination through FileManager (only its own claim, off the main thread)" \
  Sources/SrtFlow/EncodeJob.swift '^[^/]*FileManager\.default'
forbid "the queue never gives ffmpeg the planned name as its output path (EncodeJob gives its own file)" \
  Sources/SrtFlow/EncodeQueue.swift '^[^/]*outputPath: item\.'
QUEUE_REMOVALS="$(grep -nE '^[^/]*removeItem\(' Sources/SrtFlow/EncodeQueue.swift | grep -vF 'removeItem(at: jobDirectory)' || true)"
if [ -n "${QUEUE_REMOVALS}" ]; then
  echo "✗ 接线守卫：the queue removes nothing but the burn-in workspace; an encode's own file is removed only by EncodeJob: ${QUEUE_REMOVALS}" >&2
  WIRING_FAIL=1
fi
require "quitting stops a running encode and removes its own file" \
  Sources/SrtFlow/SrtFlowApp.swift 'EncodeJob\.stopAllForQuit\(\)'

if [ "$WIRING_FAIL" -ne 0 ]; then
  echo "file-io-off-main-wiring 失败" >&2
  exit 1
fi
echo "✓ file-io-off-main-wiring：导出文件夹、AI 导出、工程存盘、系统的打开 / 存储窗口都不在主线程上等盘或面板服务; Compress / Burn In write only their own file"
