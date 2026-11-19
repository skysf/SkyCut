# macOS open and save windows: never a modal session

Since 2026-11-19 ([case](../bugfixes/2026-11-19-modal-file-windows-can-wedge-app.md); the export folder window since
2026-11-18, [case](../bugfixes/2026-11-18-export-folder-chooser-freezes-app.md)). Long-term rules for every place SkyCut asks
the person for a file or a folder through the system's open / save window. The export panel's own rules (destination checks,
its inline fallback) are in [export settings](export-settings.md) §8.

## Why

A non-sandboxed app's `NSOpenPanel` / `NSSavePanel` is drawn by the out-of-process `com.apple.appkit.xpc.openAndSavePanelService`.
Measured on macOS 26.5 with a probe app (details in the 2026-11-18 case): when that service hangs, a `runModal` panel never
returns and its buttons are dead; creating the next panel blocks the main thread for up to 60 s and then nothing appears;
with `begin` (non-modal) the app stays responsive and `cancel()` closes the stuck window at once. On Tahoe the service hangs
and fails to connect in the field. A modal panel turns that into a frozen SkyCut that only Force Quit ends.

## Rules

1. **Panels are made only in `SystemFileChooser.swift`** (`SystemFilePanel`, from a `FileWindowRequest`: files to open,
   a folder, a new file to save) **and opened with `begin`, never `runModal`**. `checks/file-io-off-main-wiring.sh` fails on an
   `NSOpenPanel(` / `NSSavePanel(` anywhere else and on `runModal` in the chooser, the shared windows, the helper and the
   export panel. In-process `NSAlert`s are not panels of that service and may stay modal.
2. **`SystemFileChooser` watches the window**: not on screen with no answer for 3 s, or an empty answer within 1 s, is a
   failure (AppKit can give up without ever calling back); "Close It" cancels a window that stopped responding. Its completion
   gets the picked URLs, or nil when the person cancelled; a failure is a phase (`.failed`), not a completion.
3. **A record before AppKit is asked** (`SrtFlow.fileWindowInFlight`, shared by every window; cleared when the window
   answers or SkyCut quits normally). Still there at the next request = that run ended with a window open, most likely frozen
   inside AppKit: the typed path comes first and "Try Again" asks AppKit anyway. SkyCut cannot cut AppKit's own wait short;
   this is how it avoids walking into it twice.
4. **Everything except the export panel's folder row goes through `SystemFileWindows.shared`** (the views call `FilePicker`,
   which wraps it): **one system window at a time** — while one is up, a second request opens nothing and gets no answer, as
   with the modal panels before. Answers come in a closure (`open`) or awaited (`choose`).
5. **The helper next to the system window** (`FileWindowHelper`, SkyCut's own small window, so it keeps working when the
   service hangs): once the system window has been on screen for 5 s without an answer, a strip next to it says "If the macOS
   window stops responding, close it here" with **Close It**; after a failure, a small window offers **the same job without
   the system window** — type or paste a path (quotes, `~`, `\ `, `file://` accepted), drag the files or a folder from Finder,
   or **Try Again**. `TypedPath` decides a typed or dropped answer without touching a drive (allowed types by extension; a
   folder for a folder request, or a dropped file's folder; for a save, a path ending in "/" or a dropped folder gets the
   suggested name and a name without an extension gets the type's); the caller checks the file as it would after the
   system window.
6. **The window is not modal, so the rest of SkyCut keeps working while it is open**: a caller whose answer goes into a
   project checks that the project is still the same document (`isCurrentGeneration`) — adding media, attaching subtitles,
   relinking (and only while that file is still missing), Save As. A queue item that went away is skipped (burn-in's
   subtitle for a video).
7. Save As is awaited (`chooseSaveLocation() async`), so closing an untitled project (`prepareToClose`) can ask "Save…" and
   wait for the window. The blocking `prepareToCloseDocument` (checks only, [project file](video-edit-project-file.md) §5)
   cannot wait for a non-modal window and refuses "Save…". The close uses the window's answer only while the project is
   still the document it was asked for, checked before anything is written: a New / Open meanwhile would otherwise get
   written to the place chosen for the untitled one ([case](../bugfixes/2026-11-19-close-trusts-a-stale-save.md)).
8. Diagnostics: the chooser leaves `注：file window: …` notes in the stall log (opening, how long macOS took to make it,
   came back empty, never on screen, closed from SkyCut), [main-thread stalls](../testing/main-thread-stalls.md).
9. **A save replaces a file only when that was confirmed for exactly its URL** (since
   [a typed or dropped answer replaced a file](../bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md)). macOS's own
   save window asks "Replace?" before it answers; the helper's typed and dropped answers never do. So a save's answer is a
   `SaveLocation` (`SaveLocation.swift`): the URL and `mayReplace`, true only from macOS's own window, only for that URL, and
   only when a file is at that URL when the window answers — the window asks only about a file that is there, so a free name
   it answers is no decision ([case](../bugfixes/2026-11-19-free-save-name-treated-as-replace-consent.md)); the look runs off
   the main thread within 5 s, and a drive that doesn't answer allows nothing. A caller that changes the URL (the project's
   Save As adding `.skycut`) uses `at(_:)`, which drops the confirmation. Every save
   written from a window writes through `NewFileClaim` (the bytes under a private name, then the name taken in one step that
   fails when it is taken: [export settings](export-settings.md) §5 item 9) unless replacing was confirmed; when a file is
   there, or appears during the write, the caller asks `FileReplaceQuestion` (Cancel by default) and writes
   again only on Replace — the project's Save As (`saveAs(chosen:)`, also from closing an untitled project) and the subtitle
   editor's Export As (`SubtitleFileSave`) — or, for a screen recording, the commit avoids the name ("Name 2"): it replaces only
   in the branch the person confirmed and commits every other name with one rename that fails when the name is taken,
   journaled first ([recording lifecycle](screen-recording-lifecycle.md) "文件覆盖与命名"). The AI's saves pick unused names
   and never replace a file (only `save_project` back to the project's own file).

## Checks

| Check | What it holds |
| --- | --- |
| `scripts/check-export-profile.sh` (`FileChooserChecks`) | the chooser with fake windows: answers, a person cancels, empty at once, never appears (main thread free), appears then vanishes, stays stuck + Close It, closed when nobody waits any more, the force-quit record + Try Again |
| `scripts/check-export-profile.sh` (`FileWindowsChecks`) | the shared windows with a recording helper: an answer reaches the caller, a cancel is not a failure, a window that never comes offers the fallback and a typed answer there reaches the caller, Close It appears next to a window on screen and offers the fallback, Try Again, one window at a time, the record sends the next request to the fallback; `TypedPath` for files, saves and drops |
| `scripts/check-export-profile.sh` (`SaveAnswerChecks`) | an answer from macOS's own save window may replace a file that is there, never a free name (a file saved there after the answer keeps its bytes), nothing when the drive doesn't answer the look; a typed folder, a dropped folder and a typed path from the helper may not; a confirmation covers only its URL (rule 9) |
| `scripts/check-screen-recording-feedback.sh` (`RecordingCommitChecks`) | a recording's commit: a file that appears at a free name or at the sidecar's name after the intent was journaled keeps its bytes, the file takes the next name and the journal names it; a confirmed commit replaces (rule 9) |
| `scripts/check-project-saves.sh` (`ReplaceChecks`) | a file under the answered name keeps its bytes until the person answers Replace: the project's Save As for each helper answer, closing an untitled project, the AI's saves, the subtitle file write (rule 9) |
| `checks/file-io-off-main-wiring.sh` | panels only in `SystemFileChooser.swift`, `begin`, no `runModal` in the chooser / shared windows / helper / export panel, the record before AppKit, `FilePicker` through `SystemFileWindows`; rule 9's wiring (helper answers unconfirmed, the exclusive install, Save As and Export As asking, the recording's confirmation) |

## Manual regression (real windows, before a release)

The real panel service can't be driven from a check (it needs the window server, and its automation is unreliable,
[GUI smoke](../testing/gui-smoke-testing.md)).

1. Each window opens and answers as before: Add Media…, Open Project…, Save As… (and "Save…" when closing an untitled
   project with edits), relink a missing file, attach subtitles (editor and burn-in), compress / burn-in "Choose…" (files and
   output folder), batch convert (files and output folder), the subtitle editor's "Export As", the screen recording's save
   location, a new voice's sample file. Cancel changes nothing.
2. With a window open, the rest of SkyCut responds (timeline, playback); after 5 s the "Close It" strip stands next to it;
   ⌘Q quits.
3. Freeze the panel service while a window is open (Activity Monitor: "Open and Save Panel Service (SkyCut)", or the
   `openAndSavePanelService` process that appeared, then `kill -STOP` it): SkyCut stays usable; Close It closes the window and
   the helper offers the typed path; typing a path or dropping a file from Finder answers the request. Then ask for another
   window with the service still stopped: SkyCut may hang up to about a minute inside AppKit (not fixable), then shows the
   helper; force quit during that wait → reopen SkyCut → the next window request goes straight to the helper. Kill the
   stopped service afterwards.
4. While Add Media… is open, start a new project (File ▸ New Project): picking a file afterwards adds nothing to the new
   project.
5. With the panel service stopped (item 3), Save As… a project by dropping a folder that already holds a project of the
   suggested name: SkyCut asks "Replace “Name.skycut”?"; Cancel leaves that file as it was, Replace saves there. The same for
   the subtitle editor's Export As; a screen recording saved to a typed path that already exists lands as "Name 2". With the
   service running: start a manual recording to a free name, make a file of that name in Finder while it records, stop — the
   recording lands as "Name 2" and the Finder file is untouched.
   The subtitle editor's Export As onto a USB hard drive that has gone to sleep: SkyCut stays responsive while it spins
   up, and says the drive is not responding if it takes over 15 s.
6. Chinese and Spanish UI: the strip, the helper and the replace question are translated (in-process windows with
   `.appLanguage()`; the question is an `NSAlert` with SkyCut's own strings).
