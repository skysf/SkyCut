# 2026-11-19 Every other open / save window was still a modal panel that a hung panel service could wedge

## Symptom

Not reported by a user: found while fixing the export folder freeze on a friend's Mac
([case](2026-11-18-export-folder-chooser-freezes-app.md), follow-up 1 there), and Master decided to fix every other window
the same way.

The friend's freeze came from the export panel's folder window; the same system window, run the same modal way, is behind
Add Media… (the friend adds DJI footage from a USB hard drive), Open Project…, Save As… (and "Save…" when closing an untitled
project), relinking a missing file, attaching subtitles, the compress / burn-in "Choose…" buttons and their file pickers, batch
convert, the subtitle editor's "Export As", a screen recording's save location and a new voice's sample file. When the macOS
panel service hangs while one of them is up, SkyCut freezes until Force Quit.

## Root cause

Proved by reading the code (before the fix):

1. `FilePicker.chooseFiles` / `chooseDirectory` (the views' file pickers) ran `NSOpenPanel.runModal()`.
2. `promptOpenProject`, `promptRelink`, `saveDocumentAs` (VideoEditProjectDocument), `promptAddMedia` (the project bar),
   `exportAs` (SubtitleEditPanel) and `chooseOutput` (the screen recording setup) built their own panels and ran them with
   `runModal()`.
3. Batch convert used `begin`, but without the watcher, the record or any other way to answer.

The service's behaviour (measured in the 2026-11-18 case on macOS 26.5): a hung service under `runModal` never returns and the
panel's buttons are dead; with `begin` the app stays responsive and `cancel()` closes the stuck window at once.

## Fix

- **One chooser for every window** (`SystemFileChooser`, #478's `ExportFolderChooser` generalized and renamed): a
  `FileWindowRequest` says files / a folder / a new file to save; `SystemFilePanel` builds the NSOpenPanel or NSSavePanel and
  opens it with `begin`. The watcher (not on screen 3 s, empty within 1 s), Close It and the force-quit record
  (`SrtFlow.fileWindowInFlight`, now shared by every window) are #478's, unchanged.
- **`SystemFileWindows`** (shared by everything except the export panel's folder row, which keeps its inline UI): one system
  window at a time, answered in a closure or awaited. **`FileWindowHelper`**, SkyCut's own small window: "Close It" next to a
  system window that has been on screen 5 s, and after a failure the same job without it — a typed or pasted path, files or a
  folder dragged from Finder (`TypedPath`, no drive access), or Try Again.
- **Every call site** moved onto it (the views through `FilePicker`, now non-modal with a closure). Because the window is not
  modal any more, the project-related callers drop an answer that comes back after the project was switched (add media,
  subtitles, relink — only while that file is still missing — and Save As), and burn-in skips a video that left the queue.
- Save As is awaited (`chooseSaveLocation() async`), so "Save…" in the untitled-project close prompt waits for the window
  (`prepareToClose`); the checks-only blocking `prepareToCloseDocument` refuses "Save…".
- Rules: [system file windows](../architecture/system-file-windows.md); [export settings](../architecture/export-settings.md) §8
  updated.

## Verification

- `scripts/check-export-profile.sh`, 122 assertions green: #478's chooser checks on the generalized API (`FileChooserChecks`)
  and the new `FileWindowsChecks` — a picked file reaches the caller; a cancel answers nothing and is not a failure; a window
  that never comes offers the fallback for that request with the main thread free, and an answer typed or dropped there
  reaches the caller; Close It appears next to a window on screen, cancels it and offers the fallback; Try Again opens the
  window again and its answer arrives; one window at a time; the record sends the next request to the fallback first;
  `TypedPath` for typed movies (quotes, other kinds refused unless allowed, not a full path refused), saves (a folder gets the
  suggested name, a name gets the type's extension) and drops (a file means its folder; one vs several; a folder dropped on a
  save).
- Reverse verification (each went red, then green after restoring): no fallback on failure, no Close It strip and the record
  ignored → 8 red; a modal `NSOpenPanel` put back into the compress view → `checks/project-file-wiring.sh` red.
- `scripts/check-local.sh` scan guards and localization coverage green (the strip and the helper are in all three tables).
- Not verified: the real panels with a frozen panel service, and the helper's placement next to them (manual regression in
  system-file-windows.md); the friend's macOS 26.6.2.

## Lessons

- A fix for one call site of a hazard is half a fix: look for every other place that does the same thing (here, every
  `runModal` of a panel), and put the rule where a guard can see all of them (panels are made in one file).
- A non-modal window changes what can happen while it is open: whatever the answer goes into may have changed meanwhile.
