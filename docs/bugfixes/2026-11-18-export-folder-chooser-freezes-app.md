# 2026-11-18 Choosing the export folder froze SkyCut on a friend's MacBook Air

## Symptom

Reported by the owner for a friend: "整个软件就卡住了，也无法关闭，必须要强制关闭 skycut 才行", never seen on the owner's Mac.

- The friend's Mac: MacBook Air 13" (M4, 2025), 16 GB, macOS Tahoe 26.6.2; a public build (most likely the 0.18.66 DMG:
  self-signed, not notarized). The owner's Mac runs an older 26.x.
- Export panel: a 1:30:30 timeline, "Export to" `/Volumes/My Passport/芹` (a Western Digital external drive), 1920×1080
  60 fps, H.264 CRF 23 slow, AAC 192 kbps.
- The friend clicked the folder button next to the destination. The macOS open panel showed the drive (folder 芹 with DJI
  MP4 files), then an alert on top of it: 「打开文件操作失败。打开文件操作未能连接打开和保存面板服务。」 ("The open file
  operation failed. / The open file operation failed to connect to the open and save panel service."). After OK, the whole
  app froze and could not be quit; only Force Quit worked.

## Root cause

There is more than one cause: the system's panel service failed, and SkyCut was built so that this (and a slow or
read-only drive) could freeze it.

### What SkyCut did (proved by the code)

1. **The folder button ran the system panel as a nested modal session.** `FilePicker.chooseDirectory` →
   `NSOpenPanel.runModal()`, called synchronously inside the SwiftUI sheet's button action. Nothing in SkyCut could time it
   out, close it or offer another way to pick a folder.
2. **Every redraw of the export panel asked the destination drive on the main thread**: the `folder` property went through
   `usableExportFolder` (`fileExists` + is-directory), the replace hint did `fileExists` on the output, the subtitle-files
   section did `fileExists` per file, and the Export button did it once more.
3. **The finished video was moved onto the destination on the main thread.** ffmpeg writes into the export workspace in the
   internal temporary folder; the move to the destination ran inside the exporter's main-actor task. Onto another drive that
   is a full copy: a 90-minute 1080p60 export is several GB, so tens of seconds to minutes of spinning beachball on a USB
   hard drive.
4. **An unwritable destination was found out only at the end**, by that move: an NTFS drive (read-only on macOS without
   extra software) or a folder without permission failed after the whole encode.

### What macOS does (measured on this Mac, macOS 26.5, with a throwaway non-sandboxed probe app)

The probe used the same AppKit calls as SkyCut, kept its windows invisible and off-screen, and froze or killed only its own
panel-service instance (found by diffing the service processes; each app gets its own instance).

- **A non-sandboxed app's `NSOpenPanel` is the out-of-process panel** served by
  `com.apple.appkit.xpc.openAndSavePanelService`: `NSOpenPanel()` is not the in-process `NSLocalSavePanel` unless the
  private default `NSUseRemoteSavePanel` is NO. The friend's alert text is AppKit's own (`SavePanel.loctable`: "The open
  file operation failed." / "…failed to connect to the open and save panel service.").
- **Creating the panel waits for the service on the main thread**: 1–3 s on this (heavily loaded) Mac; 6.7 s after the
  service had died; **60.1 s with the run loop not turning at all** when the service hangs (`SIGSTOP`) — a beachball, no
  clicks, no Quit — after which AppKit gives up silently: no window, `runModal` returns Cancel at once, and `begin` never
  calls its completion.
- **The service hangs while the panel is up under `runModal()`**: `runModal()` did not return in the 45 s observed, no alert;
  the panel's own buttons are drawn by the hung service, so it cannot be cancelled. It ended only when the service died.
- **The service crashes** (`SIGSEGV` / `SIGKILL`) while the panel is up: `runModal()` returns Cancel within 0.5 s and the
  panel disappears — what this repo saw on 2026-10-18 with the Chinese input method
  ([report](../reports/2026-10-18-ai-multi-project-ui-smoke.md)).
- **With `begin` (non-modal) and a hung service**, the app stays responsive and `cancel()` closes the stuck panel in 0.09 s
  (its completion is called).
- A Dock-style Quit still quit the delegate-less probe while a modal panel was up (healthy or hung service): "could not
  quit" needs a hard main-thread block, like the 60 s wait.
- Elsewhere: cmux recorded 73 field hangs of 2–60 s in `-[NSSavePanel _initBridgeAndStuff]` → `HIRunLoopSemaphore wait:`
  ("no deadline"); VMark issue #73 (macOS 26.3) reports the panel service hanging, freezing or failing to connect on Tahoe,
  with the workaround of deleting `~/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist`.

### Inferred for the friend's Mac (not proved: no logs yet)

The panel service on the friend's Mac failed while it browsed the external drive, AppKit showed its alert, and SkyCut's main
thread then stayed inside AppKit waiting for the service (the 60 s handshake, possibly more than once, or a modal session
that never ended): frozen, Quit refused, Force Quit. Possible triggers, none proved: a slow or sleeping USB hard drive with
many large DJI files, iCloud Drive, a crash like the input-method one. The exact alert path did not reproduce on 26.5 with
`SIGSTOP` / `SIGKILL` / `SIGSEGV` of the service; 26.6.2 may behave differently. If the drive itself stalled, items 2 and 3
above would have frozen SkyCut on their own. Why only the friend: the owner exports to the internal disk.

## Fix

- **Folder window** (`ExportFolderChooser`, `SystemFolderPanel`): opened with `begin`, never `runModal`. Not on screen with
  no answer for 3 s → failed (the window is cancelled); an empty answer within 1 s → failed; while it is up the panel offers
  "Close It" (cancels a stuck window). Before AppKit is asked, a record (`SrtFlow.export.folderChooserInFlight`) is written
  and it is cleared when the window answers or SkyCut quits normally: still there at the next attempt = the last run ended
  with the window open, so the typed path comes first. The window never starts on a drive the last check found gone or
  not answering (the home folder instead).
- **Another way to pick** (`ExportFolderRow`): after a failure, type or paste a path (quotes, `~`, `\ `, `file://`
  accepted) or drag a folder — or a file, meaning its folder — from Finder onto the "Export to" row (always works).
- **Destination checks** (`ExportDestinationProbe`, `ExportDestinationState`): off the main thread on GCD with a deadline
  (5 s to look, 15 s with a write test), at most three checks left waiting on one drive. The replace hint and the subtitle
  files' "already there" come from the folder listing. Missing, a file, a read-only drive, not writable, not responding:
  said under "Export to" before anything is encoded; a chosen / typed / dropped folder is only taken after a write test.
- **Delivery** (`ExportDelivery`): the move onto the destination on its own queue; the panel says "Saving the video into
  the export folder…" while it copies. Subtitle files are written off the main thread after a fresh check.
- **Diagnostics** (`MainThreadWatchdog`): a stall still going on after 5 s is written to the stall log with a stack taken
  then, and every 30 s while it lasts. Before, a hang that ended in Force Quit never landed and left nothing.

What SkyCut cannot fix: AppKit's own wait inside `NSOpenPanel()` (up to 60 s measured) when the service is already hung.
After it SkyCut recovers and offers the typed path; after a force quit during it, the next attempt starts with the typed
path. Rules: [export settings](../architecture/export-settings.md) §8, [blocking reads](../architecture/blocking-media-reads.md)
"Destination drives".

## Verification

- `scripts/check-export-profile.sh` (`FolderChooserChecks`, `DestinationChecks`): a fake window that answers, is cancelled
  by a person, comes back empty at once, never appears, appears then vanishes, or stays stuck (+ Close It), the panel closed
  while choosing, a record from another process (+ Try Again); the main thread free while waiting. Destination: a writable
  folder (names, case-folded, no leftover test file), missing, a file, a `chmod 555` folder (refused only by the write test),
  a fake drive that never answers (answer at the 0.5 s deadline, main thread free), a read-only drive, the per-drive cap
  (the fourth check answers at once, another drive unaffected), the panel state (gone → start folder; asleep → kept and "not
  responding", and the folder window starts in the home folder; dropped file → its folder; read-only refused), typed paths;
  one real export with the delivery held 1.2 s → off the main thread, main-thread gap under 0.5 s, "saving" shown and
  cleared. 87 assertions green.
- `scripts/check-main-thread-watchdog.sh` group 5b: a 1.8 s stall is in the log as "still stuck" with the stack 1.3 s in,
  before it lands; one entry; the usual entry after it lands. 31 assertions green.
- `checks/project-file-wiring.sh`: no `runModal` / `FilePicker` in the panel's files; `begin`; the record before AppKit; the
  window starts at `windowStart`; no `FileManager.default` in the panel's files; no move / replace / `fileExists` in the
  exporter; `ExportDelivery.deliver`; `checkBeforeWriting` before an export.
- Reverse verification (each went red, then green after restoring): no window watcher → 3 chooser failures; no record →
  "written before AppKit" red; no per-drive cap → "calls 4"; delivery back on the main thread → off-main and the 1.2 s gap
  red; the probe's work on a pool thread without a deadline → deadline and not-responding red (the main-thread gap stays green
  there: a nonisolated `async` call is already off the main actor, which is why the scan guard is the defence against
  synchronous drive calls in the panel); the probe pinned to the main actor → gap 8.0 s red; the watchdog's ongoing write
  removed → group 5b 3 red; the modal `FilePicker` back in the row → scan guard red; `windowStart` always the destination →
  its assertion red; the button back on `destination.folder` → scan guard red.
- Not verified: the real `NSOpenPanel` inside SkyCut with a failing service (needs the window server and a failing service:
  manual regression list in export-settings.md); the friend's 26.6.2.

## Lessons

- A system panel is another process. Never run it as a nested modal session, never wait for it without a way out, and always
  offer a way to do the same job without it.
- Nothing on the main thread may touch a user-chosen destination: it can be a sleeping USB disk, a read-only NTFS volume or
  an unplugged drive. Check it (with a write test) before a long job, not at the end.
- The watchdog must write down stalls that never end; otherwise the one hang worth reading leaves no log.
