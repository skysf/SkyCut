# 2026-11-19 A typed or dropped answer to a save window silently replaced a file of the same name

## Symptom

Found by code review CXR2 (R2, P1), not reported by a user. When macOS's save window fails (its panel service hangs), SkyCut's
helper offers the same job without it: type a path, or drop a folder from Finder
([open and save windows](../architecture/system-file-windows.md) rule 5). A folder dropped there — or a typed path ending in
"/" — got the suggested file name and was answered at once; when a project of that name was already in the folder, Save As
wrote over it without asking. A typed full path naming an existing file did the same. The subtitle editor's Export As and the
screen recording's save location go through the same helper: Export As wrote over a subtitle file of the same name, and a
manual recording replaced a movie of the same name when it was committed.

## Root cause

1. macOS's own `NSSavePanel` asks "“X” already exists. Do you want to replace it?" before it answers. The helper's answers
   (`TypedPath`) are decided without touching a drive and never ask. Both reached the caller as the same plain URL.
2. Every writer replaced whatever was there: the project file is written with `Data.write(.atomic)` (`VideoEditProjectIO.save`)
   — atomic, but not exclusive; the subtitle editor used a plain `Data.write`; a manual recording's commit replaces its output
   (`ScreenRecordingSession.replacesExistingOutput` was true for every manual session: written for the save panel's
   confirmation, so it also covered the pre-filled name nobody confirmed).
3. The project's Save As adds `.skycut` when the chosen name has no project extension: a confirmation for the name without it
   would not have been one for the name with it.

## Fix

- **`SaveLocation`** (new, `SaveLocation.swift`): a save window's answer is the URL plus whether replacing a file there was
  confirmed — true only from macOS's own window, false from the helper. `at(_:)` drops the confirmation when a caller changes
  the URL. `SystemFileWindows.chooseSave` / `openSave` and `FilePicker.chooseSaveLocation` hand it over.
- **`NewFileClaim`** (new): a write that may not replace claims the name first (`O_EXCL`: an empty file, only if nothing is
  there) and then writes atomically over that claim; a file already there gives `.occupied` and is not touched.
- **`FileReplaceQuestion`** (new, same file as `SaveLocation`): "Replace “X”?", Cancel by default, asked when a file is there
  and nobody asked yet — by the project's Save As (`saveAs(chosen:)`, also when closing an untitled project) and the subtitle
  editor's Export As (`SubtitleFileSave`, new). The answer counts only for the document it was asked about.
- **Project writer**: a Save As that may not replace claims the name before anything is written — not even web-motion movies
  are carried next to the old file (`ProjectFileWriteResult.occupied`). The AI's saves (`new_project`, `save_project`, the
  first save of a never-saved project) and `OpenProjects.createProject` already pick unused names; now a file that appears
  under the picked name meanwhile is not replaced either, and nobody is asked. `save_project` back to the project's own file
  still replaces it. `saveAs` takes `replacing:` explicitly.
- **Screen recording**: the setup sheet carries the window's confirmation (`ScreenRecordingOptions.replacesExistingOutput`);
  a manual session replaces its output only when that was confirmed, otherwise the commit avoids the name ("Name 2"), as the
  AI's recordings always did. To keep `ScreenRecordingCoordinator.swift` under its size baseline the starting manifest's
  construction moved into `ScreenRecordingFileCommit.startingManifest` (769 → 764 lines).
- Rules: [open and save windows](../architecture/system-file-windows.md) rule 9;
  [project file](../architecture/video-edit-project-file.md) §5 item 5.

## Verification

- `scripts/check-project-saves.sh`, new `ReplaceChecks` (11 assertions; 54 in all, green): a file with known bytes under the
  name each helper answer leads to — a dropped folder, a typed folder, a typed path: asked once, Cancel keeps its bytes and the
  project where it was; Replace writes the project there; an answer macOS's own window confirmed replaces without asking;
  closing an untitled project with a typed name that is taken, then Cancel, keeps both; the AI's Save As leaves a file that is
  there, asks nobody and says why; saving back to the project's own file replaces it; subtitles: kept when nobody agreed,
  replaced when confirmed, a new name written (the claim filled, not left empty).
- `scripts/check-export-profile.sh`, `FileWindowsChecks` (4 new assertions; 127 in all, green): an answer from macOS's own
  window may replace; a typed folder, a dropped folder and a typed path from the helper may not; a confirmation covers only its
  own URL.
- Reverse verification (each went red, then green after restoring):
  - the project writer without the claim and subtitles always replacing → exactly 6 red (the three helper answers, closing
    the untitled project, the AI's Save As, the subtitle file);
  - helper answers treated as confirmed and `at(_:)` keeping the confirmation → exactly 4 red;
  - the setup sheet dropping the window's confirmation → `checks/file-io-off-main-wiring.sh` red.
- Not verified: the real helper with a hung panel service, the real alert, a real recording (manual items in
  system-file-windows.md).

## Lessons

- Two ways to answer the same question must hand over the same facts: when one of them skips a step (the "Replace?"
  confirmation), the answer has to say so, and the writer has to default to the safe side.
- An atomic write is not an exclusive one: write to a place the person chose with "create, don't replace" unless replacing
  was confirmed for exactly that URL.
- A confirmation is about one URL: a caller that changes the URL (adds an extension) needs a new one.
