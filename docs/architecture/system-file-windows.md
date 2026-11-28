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
   export panel. In-process `NSAlert`s are not panels of that service and may stay modal, outside any Swift task (rule 10).
2. **`SystemFileChooser` watches the window**: not on screen with no answer for 3 s, or an empty answer within 1 s, is a
   failure (AppKit can give up without ever calling back); "Close It" cancels a window that stopped responding. Its completion
   gets the picked URLs, or nil when the person cancelled; a failure is a phase (`.failed`), not a completion.
3. **A record before AppKit is asked** (`SrtFlow.fileWindowInFlight`, shared by every window; cleared when the window
   answers or SkyCut quits normally). Still there at the next request = that run ended with a window open, most likely frozen
   inside AppKit: the typed path comes first and "Try Again" asks AppKit anyway. SkyCut cannot cut AppKit's own wait short;
   this is how it avoids walking into it twice.
4. **Everything except the export panel's folder row goes through `SystemFileWindows.shared`** (the views call `FilePicker`,
   which wraps it). Answers come in a closure (`open`) or awaited (`choose`).
   - **One system window at a time in the whole app**, the export panel's folder row included (it drives a chooser of its
     own). While one is up, a second request, from either, opens nothing and gets no answer, as with the modal panels
     before; the strip of rule 5 then offers to close the open one.
   - `SystemFileChooser.choose` builds no panel while any chooser's window is open (`SystemFileChooser.openWindow`):
     making a second panel waits on AppKit's main-thread handshake with the panel service, which held SkyCut for 60 s
     when the service hung (2026-11-18).
   - Since 2026-11-27 (review CXC2): until then, the export folder button built a second panel beside an open Open
     Project… window.
5. **The helper next to the system window** (`FileWindowHelper`, SkyCut's own small window, so it keeps working when the
   service hangs).
   - **Nothing appears next to the system window while the person chooses, however long they take** (since 2026-11-27,
     [case](../bugfixes/2026-11-27-close-it-strip-popped-up-next-to-every-file-window.md): a strip used to come after 5 s,
     next to every window a person took longer over, and nobody knew what it meant). Nothing pops up by itself.
   - **The strip comes only when the person asks for another file window while one is up** (from any entry, the export
     panel's folder button and its Try Again included), and only while that window is on screen. That is the one sign
     SkyCut gets that the window may be stuck: macOS says nothing when its panel service hangs, and the window just stops
     answering. The strip stands next to the open window, whichever chooser's it is, and goes away with it: "If the window for choosing a
     file is stuck or not responding, click here to close it." (「选文件的窗口卡住或没反应，点这里关闭。」, wording approved by the user
     on 2026-11-27) with **Close** (关闭), which cancels the file window, never SkyCut, even when its service hangs (rule 2),
     and offers the fallback below. ⌘Q quits as usual.
   - After a failure, a small window offers **the same job without the system window**: type or paste a path (quotes, `~`,
     `\ `, `file://` accepted), drag the files or a folder from Finder, or **Try Again**. `TypedPath` decides a typed or
     dropped answer without touching a drive (allowed types by extension; a folder for a folder request, or a dropped
     file's folder; for a save, a path ending in "/" or a dropped folder gets the suggested name and a name without an
     extension gets the type's); the caller checks the file as it would after the system window.
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
   **The Burn In subtitle editor writes only the subtitle Export As was pressed for** (since 2026-11-28,
   [case](../bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md)): `SubtitleEditorExport` takes the panel's
   place (its preview row, or the standalone file) and what it holds when Save or Export As is pressed. Before each write,
   when the save window answers and again when Replace is answered, that place must still hold exactly that subtitle,
   unedited; otherwise nothing is written and the person is told "Nothing was written: the subtitle changed. Export
   again." The retry never takes whatever the panel shows by then. "That place" is the row or the standalone file, not
   the panel: the preview moving to another video's row while the standalone file stays open, unedited, still exports
   that file. Its Replace question is asked from a run-loop turn (`FileReplaceQuestion.askFromRunLoop`, rule 10), and what
   a save has to say ("Could Not Save" with the reason) is an app-level alert from a run-loop turn, seen even after the
   person has left the Burn In page (review CXM1).
10. **An alert's modal loop runs from the run loop, never inside a Swift task** (since 2026-11-27,
    [case](../bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md)). While `runModal` runs, every event
    goes through AppKit's handlers, and AppKit swallows an Objective-C exception raised there. Raised under a modal loop
    that runs inside a task, the exception unwinds the task and the Swift runtime's `swift_job_run`, which then never puts
    the thread's executor tracking back. The next main-actor isolation check outside a task (`MainActor.assumeIsolated`,
    an event monitor) reads a dead stack frame and crashes. That is how Check for Updates… crashed 0.18.70.
    - Show a new alert from a run-loop turn: `RunLoop.main.perform { MainActor.assumeIsolated { … } }`, as the update
      check's answer does ([app updates](app-updates.md) §7). Not `Task { }`. Not `DispatchQueue.main.async` either: an
      exception escaping a dispatch block terminates the app.
    - A caller inside a task that awaits the answer uses `RunLoopAlert` (a run-loop timer, also in the modal-panel mode
      Quit's wait runs in, never inside another alert): the Burn In subtitle questions and the subtitle editor's Replace
      (`FileReplaceQuestion.askFromRunLoop`), since 2026-11-28.
    - Still inside tasks on 2026-11-28, because they await the answer: the untitled-project save question
      (`ProjectCloseQuestions`, from `prepareToClose`), the drive question at quit (`ProjectQuit.waitForDrive`) and
      `FileReplaceQuestion.ask` for the project's Save As. Moving one out of its task is a change of its own.

## Checks

| Check | What it holds |
| --- | --- |
| `scripts/check-export-profile.sh` (`FileChooserChecks`) | the chooser with fake windows: answers, a person cancels, empty at once, never appears (main thread free), appears then vanishes, stays stuck + Close It, closed when nobody waits any more, the force-quit record + Try Again |
| `scripts/check-export-profile.sh` (`FileWindowsChecks`) | the shared windows with a recording helper: an answer reaches the caller, a cancel is not a failure, a window that never comes offers the fallback and a typed answer there reaches the caller; nothing appears next to a window the person takes long over (a pick cancelled after 1.2 s, a window up 1.5 s); a second request while one is up opens nothing and gets Close It next to it only while it is on screen (rule 5), which cancels it and offers the fallback for the first request; Try Again, one window at a time, the record sends the next request to the fallback; `TypedPath` for files, saves and drops |
| `scripts/check-export-profile.sh` (`SaveAnswerChecks`) | an answer from macOS's own save window may replace a file that is there, never a free name (a file saved there after the answer keeps its bytes), nothing when the drive doesn't answer the look; a typed folder, a dropped folder and a typed path from the helper may not; a confirmation covers only its URL (rule 9) |
| `scripts/check-screen-recording-feedback.sh` (`RecordingCommitChecks`) | a recording's commit: a file that appears at a free name or at the sidecar's name after the intent was journaled keeps its bytes, the file takes the next name and the journal names it; a confirmed commit replaces (rule 9) |
| `scripts/check-project-saves.sh` (`ReplaceChecks`) | a file under the answered name keeps its bytes until the person answers Replace: the project's Save As for each helper answer, closing an untitled project, the AI's saves, the subtitle file write (rule 9) |
| `scripts/check-export-profile.sh` (`SubtitleExportChecks`) | rule 9's Burn In subtitle editor, through the panel's own `exportAs` / `save` with a save window answered late and the real "Replace?" and "Could Not Save" alerts' buttons pressed by title: another subtitle in its place, the subtitle edited, or its video gone by the time Replace is answered writes nothing and says so in an app-level alert; unchanged, Replace writes it; a window answered after another subtitle took its place writes nothing; the preview moving to another row still exports the standalone file; Save marks the subtitle saved; no alert, Replace included, inside a Swift task (rule 10) |
| `checks/file-io-off-main-wiring.sh` | panels only in `SystemFileChooser.swift`, `begin`, no `runModal` in the chooser / shared windows / helper / export panel, the record before AppKit, `FilePicker` through `SystemFileWindows`; the Close It strip only from `offerToCloseOpenWindow` (a second request) and no sleep or timer in `SystemFileWindows` (rule 5); rule 9's wiring (helper answers unconfirmed, the exclusive install, Save As and Export As asking, the recording's confirmation; the subtitle panel's buttons only through `SubtitleEditorExport`, whose writes check the subtitle pressed for first) |
| `checks/app-update-wiring.sh` (section 10) | rule 10 for the update check's answer window: shown with `RunLoop.main.perform`, never in a `Task` or `DispatchQueue.main.async`. The other alerts are not scanned (they run inside their tasks today, rule 10) |

## Manual regression (real windows, before a release)

The real panel service can't be driven from a check (it needs the window server, and its automation is unreliable,
[GUI smoke](../testing/gui-smoke-testing.md)).

1. Each window opens and answers as before: Add Media…, Open Project…, Save As… (and "Save…" when closing an untitled
   project with edits), relink a missing file, attach subtitles (editor and burn-in), compress / burn-in "Choose…" (files and
   output folder), batch convert (files and output folder), the subtitle editor's "Export As", the screen recording's save
   location, a new voice's sample file. Cancel changes nothing.
2. With a window open, the rest of SkyCut responds (timeline, playback), and nothing appears next to the window however long
   it stays open (leave it a minute). Ask for another file window (Add Media… again): the strip "If the window for choosing
   a file is stuck…" stands next to the open one, and Close closes it (the helper then offers the typed path and Try
   Again); SkyCut stays open. ⌘Q quits.
3. Freeze the panel service while a window is open (Activity Monitor: "Open and Save Panel Service (SkyCut)", or the
   `openAndSavePanelService` process that appeared, then `kill -STOP` it): SkyCut stays usable; ask for the same window
   again and the strip appears next to the frozen one; Close closes the window and the helper offers the typed path;
   typing a path or dropping a file from Finder answers the request. Then ask for another
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
   On the Burn In page, with no video, open subtitle A on its own and press Export As. With the save window still open:
   (a) type into A, or drag another subtitle B from Finder onto the page while A has no edits (B takes A's place: the
   editor's title becomes B; a double-click in Finder while the page is open only stages B), then choose a name: nothing is
   written, and an alert says "Nothing was written: the subtitle changed. Export again.", also when you went to another
   page before choosing; (b) instead add a video with subtitle B, so the preview and the editor move to B's row while A
   stays open on its own, unedited, then choose a name: A is exported and nothing is said. Answer a typed path to an
   existing file with Replace: the question is SkyCut's own, and the result follows (a) or (b) in the same way.
6. Chinese and Spanish UI: the strip, the helper and the replace question are translated (in-process windows with
   `.appLanguage()`; the question is an `NSAlert` with SkyCut's own strings).
7. Across choosers (review CXC2): leave Open Project…'s window open, then in Export click the folder button. No second
   window opens, and the strip stands next to Open Project…'s window; Close closes it, and the export row's button works
   again. The other way round: with the export folder window open, Add Media… opens nothing and the strip stands next to
   the export window; Close closes it, and the export row offers typing a path.
8. Still open (review CXC2, backlog): quit with an untitled project that has edits, choose "Save…", then freeze the panel
   service while the save window is up. During Quit, AppKit runs its terminate-later modal loop; ⌘Q again or closing the
   window again asks for no second file window. Does ⌘O there still bring the strip and rescue the stuck save window?
   Check this on a real Mac; the checks can't reach AppKit's terminate-later loop.
