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
# - a save's answer replaces a file only when macOS's own window asked (2026-11-19,
#   docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md);
# - the subtitle editor's writes and the media records of saved versions (2026-11-19,
#   docs/bugfixes/2026-11-19-subtitle-and-version-saves-touch-drives-on-main.md);
# - a Compress / Burn In encode: ffmpeg writes only the job's own file, handed over and cleaned up off the main thread
#   (2026-11-19, docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md);
# - a new file never reserves its final name; it takes it in one exclusive step
#   (2026-11-19, docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md);
# - web-motion recovery's movie checks, Compress / Burn In's names and sizes, compress_videos / burn_subtitles' folder
#   (2026-11-19, docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md);
# - the files the AI encode tools name, burn_subtitles' subtitle reads, convert_subtitles' reads and writes
#   (2026-11-19, docs/bugfixes/2026-11-19-ai-encode-inputs-on-main-thread.md);
# - a Burn In subtitle's unsaved edits asked about before anything drops them, the question from a run-loop turn
#   (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md).
# Rules: docs/architecture/export-settings.md §8, §5 item 8 and §9, docs/architecture/video-edit-project-file.md §5,
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
# Nothing appears next to a system file window while the person chooses, however long they take (2026-11-27,
# docs/bugfixes/2026-11-27-close-it-strip-popped-up-next-to-every-file-window.md): the strip is offered only when the
# person asks for a file window while one is up (offerToCloseOpenWindow), never on a timer. And one system file window in
# the whole app (review CXC2): a chooser opens nothing while any chooser's window is open, and both the shared windows
# (start) and the export panel's folder row (its two buttons) offer the strip then.
WINDOWS_SWIFT=Sources/SrtFlow/SystemFileWindows.swift
STRIP_CALLS="$(grep -cE '^[^/]*\.showStrip\(' "${WINDOWS_SWIFT}" || true)"
OFFER_BODY="$(awk '/    func offerToCloseOpenWindow\(\) \{/,/^    \}/' "${WINDOWS_SWIFT}")"
START_BODY="$(awk '/    private func start\(_ request: FileWindowRequest/,/^    \}/' "${WINDOWS_SWIFT}")"
if [ "${STRIP_CALLS}" != 1 ] || ! grep -qF 'helper.showStrip(' <<<"${OFFER_BODY}" \
  || ! grep -qF 'guard SystemFileChooser.openWindow == nil else {' <<<"${START_BODY}" \
  || ! grep -qF 'offerToCloseOpenWindow()' <<<"${START_BODY}"; then
  echo "✗ 接线守卫：the strip is offered only from offerToCloseOpenWindow, and start asks for it whenever any file window is open (SystemFileChooser.openWindow); found ${STRIP_CALLS} showStrip lines" >&2
  WIRING_FAIL=1
fi
require "a chooser opens nothing while any chooser's window is open (one system file window in the whole app)" \
  Sources/SrtFlow/SystemFileChooser.swift 'guard phase != \.choosing, Self\.openWindow == nil else \{ return false \}'
ROW_OFFERS="$(grep -cF 'if !opened { SystemFileWindows.shared.offerToCloseOpenWindow() }' Sources/SrtFlow/ExportFolderRow.swift || true)"
if [ "${ROW_OFFERS}" != 2 ]; then
  echo "✗ 接线守卫：the export folder row's folder button and Try Again offer the strip when their chooser opens nothing (found ${ROW_OFFERS})" >&2
  WIRING_FAIL=1
fi
forbid "nothing next to a system file window comes on a timer (no sleep or timer in SystemFileWindows)" \
  "${WINDOWS_SWIFT}" '^[^/]*(Task\.sleep|asyncAfter|Timer\.|scheduledTimer)'
require "the folder window never starts on a drive the last check found not answering (windowStart)" \
  Sources/SrtFlow/ExportFolderRow.swift 'chooser\.choose\(\.exportFolder\(startingAt: destination\.windowStart\)\)'
for f in Sources/SrtFlow/VideoEditExportSheet.swift Sources/SrtFlow/ExportFolderRow.swift Sources/SrtFlow/ExportDestinationState.swift; do
  forbid "the export panel never asks the destination drive itself (only ExportDestinationProbe, off the main thread)" \
    "$f" '^[^/]*FileManager\.default'
done
forbid "the subtitle files' \"already there\" comes from the destination check, not from the drive during a redraw" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift '^[^/]*FileManager\.default\.fileExists'
# The panel's subtitle files (2026-11-19, docs/bugfixes/2026-11-19-subtitle-export-replaces-unlisted-file.md): Replace replaces
# only the files the question named, every other file is written as a new file; scripts/check-export-profile.sh
# (SubtitlePanelChecks) checks the behaviour through the button's work.
require "a subtitle file is replaced only when the question named it" \
  Sources/SrtFlow/SubtitleGen/SubtitleFilesWrite.swift 'if replacing\.contains\(file\.url\) \{'
require "every other subtitle file is written as a new file" \
  Sources/SrtFlow/SubtitleGen/SubtitleFilesWrite.swift 'try !SubtitleExportPlanner\.writeNew\(file\.document'
require "Replace replaces exactly the files the question named" \
  Sources/SrtFlow/SubtitleGen/SubtitleFilesWrite.swift 'await write\(replacing: Set\(question\)\)'
forbid "the panel's view never writes subtitle files itself (SubtitleFilesWrite does, off the main thread)" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift '^[^/]*writeValidated\('
forbid "the panel's subtitle writes never touch the drive on the main thread" \
  Sources/SrtFlow/SubtitleGen/SubtitleFilesWrite.swift '^[^/]*FileManager\.default'
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

# Replacing a file at a chosen place (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md): only
# macOS's own save window asks "Replace?", so only its answers may replace; a typed or dropped answer in the helper may not,
# and every save written from a window claims the name first (NewFileClaim) or asks (FileReplaceQuestion).
# scripts/check-project-saves.sh (ReplaceChecks) and scripts/check-export-profile.sh (FileWindowsChecks) check the behaviour.
require "a typed or dropped answer in the helper is not a confirmed replace" \
  Sources/SrtFlow/SystemFileWindows.swift 'finish\(urls, inSystemWindow: false\)'
require "macOS's own save window allows replacing only a file at the answered URL (the only case it asked about)" \
  Sources/SrtFlow/SystemFileWindows.swift 'then\(SaveLocation\(url: url, mayReplace: asked\)\)'
forbid "an answer from macOS's own window is not by itself consent to replace (a free name was never asked about)" \
  Sources/SrtFlow/SystemFileWindows.swift 'mayReplace: inSystemWindow'
require "a Save As that may not replace never writes at the name: it takes it in one step that fails when it is taken" \
  Sources/SrtFlow/ProjectFileWriter.swift 'guard let written = try ExclusivePlacement\.create\(url, writing: save\) else \{'
require "the project's Save As from a window asks before replacing" \
  Sources/SrtFlow/VideoEditProjectSaving.swift 'await saveAs\(chosen: location\)'
require "the subtitle editor's Save and Export As write with the answer's permission, off the main thread" \
  Sources/SrtFlow/SubtitleEditorExport.swift 'await SubtitleFileSave\.write\(data, to: location\.url, replacing: location\.mayReplace\)'
for f in Sources/SrtFlow/SubtitleEditPanel.swift Sources/SrtFlow/SubtitleEditorExport.swift; do
  forbid "the subtitle editor writes files only through SubtitleFileSave (a plain Data.write replaces what is there, on the main thread)" \
    "$f" '^[^/]*\.write\(to:'
done
# The editor's Export As writes only the subtitle it was pressed for, unedited (2026-11-28,
# docs/bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md): the panel's buttons only call SubtitleEditorExport,
# whose every write (the window's answer, the Replace retry) first checks that subtitle is still there, unedited.
# scripts/check-export-profile.sh (SubtitleExportChecks) checks the behaviour.
forbid "the subtitle panel opens no save window and writes nothing itself (SubtitleEditorExport does)" \
  Sources/SrtFlow/SubtitleEditPanel.swift '^[^/]*(FilePicker\.|SubtitleFileSave\.(write|data)\(|FileReplaceQuestion\.)'
require "the panel's Save goes through SubtitleEditorExport" \
  Sources/SrtFlow/SubtitleEditPanel.swift 'export\.save\(boundTo: itemID\)'
require "the panel's Export As goes through SubtitleEditorExport" \
  Sources/SrtFlow/SubtitleEditPanel.swift 'export\.exportAs\(format, boundTo: itemID\)'
require "every subtitle editor write first checks the subtitle pressed for is still there, unedited" \
  Sources/SrtFlow/SubtitleEditorExport.swift 'guard pressed\.held\.sameText\(as: subtitles\.held\(pressed\.place\)\) else \{'
require "the Replace retry writes the subtitle pressed for (checked again), never what the panel shows then" \
  Sources/SrtFlow/SubtitleEditorExport.swift 'write\(pressed, format, to: SaveLocation\(url: location\.url, mayReplace: true\)\)'
# Review CXM1 (2026-11-28): the export's Replace question runs its modal loop from a run-loop turn, never inside the save's
# task (system-file-windows.md rule 10), and what a save has to say is an app-level alert, seen off the Burn In page too.
require "the export's Replace question is asked from a run-loop turn" \
  Sources/SrtFlow/SubtitleEditorExport.swift 'if await FileReplaceQuestion\.askFromRunLoop\(location\.url\) \{'
forbid "the export never asks Replace inside its task" Sources/SrtFlow/SubtitleEditorExport.swift 'FileReplaceQuestion\.ask\('
require "what a subtitle save has to say is an app-level alert from a run-loop turn" \
  Sources/SrtFlow/SubtitleEditorExport.swift 'RunLoopAlert\.tell \{'
forbid "the subtitle panel shows no save alert of its own (it is off screen once the person leaves the page)" \
  Sources/SrtFlow/SubtitleEditPanel.swift '\.alert\("Could Not Save"'
require "a manual screen recording replaces a file only when macOS's own window confirmed it" \
  Sources/SrtFlow/ScreenRecordingCoordinator.swift 'session\.replacesExistingOutput = session\.replacesExistingOutput && options\.replacesExistingOutput'
require "the recording setup carries the save window's confirmation" \
  Sources/SrtFlow/ScreenRecordingSetupView.swift 'replacesOutput = location\.mayReplace'

# The subtitle editor's writes and saved versions (2026-11-19,
# docs/bugfixes/2026-11-19-subtitle-and-version-saves-touch-drives-on-main.md): subtitle files are written on
# SubtitleFileSave's queue with a deadline; a saved version takes the media records the project already has and asks no
# media file anything on the main thread. scripts/check-project-saves.sh (OffMainWriteChecks) checks the behaviour.
require "subtitle files are written on their own queue, never on the caller's" \
  Sources/SrtFlow/SubtitleFileSave.swift '^            queue\.async \{'
require "a saved version takes the project's media records without asking the media files" \
  Sources/SrtFlow/ProjectVersionStore.swift 'motionCaches: \.reference, mediaRecords: \.known\)'
forbid "a saved version never makes a fresh media record (that stats the media file, maybe on a sleeping drive)" \
  Sources/SrtFlow/ProjectVersionStore.swift '^[^/]*MediaRecord\(url:'

# A Burn In subtitle's unsaved edits (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md): a
# row's ✕, Clear Finished and another subtitle file for a video go through BurnInSubtitleEdits, which asks first; Quit asks
# on ProjectQuit's path; the question comes from a run-loop timer, never from a Swift task (system-file-windows.md rule 10).
# scripts/check-export-profile.sh (SubtitleEditsChecks) and scripts/check-project-saves.sh (SubtitleQuitChecks) check the
# behaviour.
forbid "the Burn In page never drops a row or replaces its subtitle itself (BurnInSubtitleEdits asks first)" \
  Sources/SrtFlow/BurnInView.swift '^[^/]*queue\.(remove\(id:|clearFinished\(|removeAll\(|updateBurnIn\()'
require "a row's ✕ asks about its subtitle's unsaved edits first" \
  Sources/SrtFlow/BurnInView.swift 'BurnInSubtitleEdits\.shared\.remove\(item\.id\)'
require "Clear Finished asks about each finished row's unsaved edits first" \
  Sources/SrtFlow/BurnInView.swift 'subtitleEdits\.clearFinished\(\)'
require "Quit asks about the Burn In subtitles on the projects' path, a Save waiting at most Quit's grace" \
  Sources/SrtFlow/ProjectQuit.swift 'await BurnInSubtitleEdits\.shared\.settleForQuit\(into: &subtitles, deadline: grace\)'
require "the alerts' timer also runs while Quit waits for its answer (the modal-panel run-loop mode)" \
  Sources/SrtFlow/RunLoopAlert.swift 'RunLoop\.main\.add\(timer, forMode: \.modalPanel\)'
for f in Sources/SrtFlow/RunLoopAlert.swift Sources/SrtFlow/SubtitleEditsQuestion.swift; do
  forbid "the subtitle alerts are never shown from a Swift task or a dispatch block" \
    "$f" '^[^/]*(Task \{|Task\.detached|DispatchQueue\.main\.async)'
done
require "the question comes through RunLoopAlert" Sources/SrtFlow/SubtitleEditsQuestion.swift 'await RunLoopAlert\.ask\('

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

# Drive checks that ran on the main thread (2026-11-19, docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md): web-motion
# recovery asks which movies are there on the cache folder's queue (it ran on every preview rebuild); Compress / Burn In name
# an item without the drive and again once the folder's names are back off the main thread, and read the finished file's
# size there too; compress_videos / burn_subtitles make, check and list their folder through the probe before queueing.
# scripts/check-motion-placement.sh (RecoveryOffMain) and scripts/check-export-profile.sh (EncodeOffMainChecks) check the
# behaviour.
forbid "web-motion recovery never asks the drive on the main thread (only on WebMotionCacheFiles.queue)" \
  Sources/SrtFlow/WebMotion/WebMotionRecovery.swift '^[^/]*(FileManager\.default|refreshWebMotionCaches\()'
require "web-motion recovery asks which movies are there on the cache folder's queue" \
  Sources/SrtFlow/WebMotion/WebMotionRecovery.swift 'await MediaReadQueue\.run\(on: WebMotionCacheFiles\.queue\)'
forbid "the Compress / Burn In queue never asks the drive itself (only through EncodeOutputFolder, off the main thread)" \
  Sources/SrtFlow/EncodeQueue.swift '^[^/]*(\.fileExists\(|MediaProbe\.byteSize\(|contentsOfDirectory\(|attributesOfItem\()'
require "the queue names items again once the folder's names are back from off the main thread" \
  Sources/SrtFlow/EncodeQueue.swift 'await EncodeOutputFolder\.names\(in: folder, probe: probe\)'
require "the finished file's size is read off the main thread" \
  Sources/SrtFlow/EncodeQueue.swift 'await EncodeOutputFolder\.size\(of: output, probe: probe\)'
forbid "EncodeOutputFolder asks the drive only through the probe" Sources/SrtFlow/EncodeOutputFolder.swift '^[^/]*FileManager\.default'
forbid "compress_videos / burn_subtitles' folder is never made or checked on the main thread" \
  Sources/SrtFlow/AIEncodeFolder.swift '^[^/]*FileManager\.default'
require "the AI encode folder is made, checked and listed through the probe" \
  Sources/SrtFlow/AIEncodeFolder.swift 'await probe\.run\(on: near, deadline: deadline'
require "compress_videos / burn_subtitles queue only into a folder prepared off the main thread" \
  Sources/SrtFlow/AIEncodeTools.swift 'try await AIEncodeFolder\.prepare\(args, project: project'

# The files the AI encode tools name (2026-11-19, docs/bugfixes/2026-11-19-ai-encode-inputs-on-main-thread.md): which file a
# path is, whether it is there and a video, burn_subtitles' subtitle reads and convert_subtitles' reads and writes go through
# the probe (AIEncodeInputs), never on the main thread; AIEncodeInputs reads and writes only through the probe's file system.
# scripts/check-export-profile.sh (EncodeInputsOffMainChecks) checks the behaviour.
forbid "the AI encode tools never ask the drive on the main thread (only AIEncodeInputs and AIEncodeFolder, through the probe)" \
  Sources/SrtFlow/AIEncodeTools.swift \
  '^[^/]*(FileManager\.default|AIWorkspace\.shared\.resolve\(|MediaFileTypes\.isVideo\(|SubtitleLoader\.load\(|convertedContents\(|\.write\(to:|Data\(contentsOf:)'
require "the files the AI names are found and checked off the main thread" \
  Sources/SrtFlow/AIEncodeTools.swift 'try await AIEncodeInputs\.find\('
require "burn_subtitles reads its subtitle files off the main thread" \
  Sources/SrtFlow/AIEncodeTools.swift 'try await AIEncodeInputs\.subtitles\('
require "convert_subtitles reads and writes its files off the main thread" \
  Sources/SrtFlow/AIEncodeTools.swift 'try await AIEncodeInputs\.convert\('
forbid "AIEncodeInputs reads and writes only through the probe's file system (the seam the checks replace)" \
  Sources/SrtFlow/AIEncodeInputs.swift \
  '^[^/]*(FileManager\.default|AIWorkspace\.shared\.resolve\(|Data\(contentsOf:|\.write\(to:|SubtitleLoader\.load\(|convertedContents\(of: [a-z]+, to)'
require "AIEncodeInputs asks the drive only inside the probe's work" \
  Sources/SrtFlow/AIEncodeInputs.swift 'await probe\.run\(on: near, deadline: deadline'

# A new file never reserves its final name (2026-11-19, docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md):
# its bytes are written under a private name, then it takes the name in one step that fails when the name is taken
# (ExclusiveInstall); no plain rename onto a final name, and writes nobody agreed may replace go through ExclusivePlacement.
# SrtFlowCoreChecks (ExclusivePlacementChecks) checks the behaviour, also on a real exFAT volume.
for placement in Sources/SrtFlowCore/ExclusiveInstall.swift Sources/SrtFlowCore/ExclusivePlacement.swift; do
  forbid "a file takes its name only in a step that fails when the name is taken (rename / moveItem / replaceItemAt replace)" \
    "${placement}" '^[^/]*((^|[^A-Za-z_])rename\(|\.moveItem\(|\.replaceItemAt\()'
done
require "the install's first step is the exclusive rename" \
  Sources/SrtFlowCore/ExclusiveInstall.swift 'renamex_np\(own\.url\.path, url\.path, UInt32\(RENAME_EXCL\)\)'
forbid "nothing reserves a chosen name empty before the write" Sources/SrtFlow/NewFileClaim.swift 'O_EXCL'
require "a write nobody agreed may replace goes through ExclusivePlacement.create" \
  Sources/SrtFlow/NewFileClaim.swift 'try ExclusivePlacement\.create\(url, writing:'

if [ "$WIRING_FAIL" -ne 0 ]; then
  echo "file-io-off-main-wiring 失败" >&2
  exit 1
fi
echo "✓ file-io-off-main-wiring：导出文件夹、AI 导出、工程存盘、系统的打开 / 存储窗口都不在主线程上等盘或面板服务; Compress / Burn In write only their own file; motion recovery, encode names and folders, and the AI encode tools' files are asked off the main thread"
