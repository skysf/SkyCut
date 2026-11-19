# 2026-11-19 Picking a free name in macOS's save window counted as consent to replace a file that appeared there later

## Symptom

Not reported by a user: review CXR3, finding R2 (P1).

- Save As a project (or Export As a subtitle file) to a **free** name such as `Cut.skycut` in macOS's own save window. If
  another app, or an independent save, created that name before SkyCut's write got to it, the write replaced that file. The
  window never asked "Replace?": nothing was there when the person picked the name.
- A manual screen recording has a much longer gap between picking its name (in the setup sheet) and saving the file (when
  it stops). A file that appeared under the name during the recording was replaced.
- The recording's commit had a second route even when replacing was not allowed (a typed answer, the AI's sessions): it
  picked a free numbered name, persisted the intent, and then chose between `replaceItemAt` and `moveItem` by asking
  whether a file was at the name *now*. A file that arrived in between was replaced.

## Root cause

`SystemFileWindows.openSave` derived `SaveLocation.mayReplace` only from *which window* answered: every answer from macOS's
own window counted as a confirmed replace, because that window asks "Replace?" before returning an existing file. But it
asks only when a file is there; a free name it returns carries no decision at all. The recording's commit made the same
mistake from the other side: it chose the replacing operation by the state of the folder, not by the person's decision.

The earlier fix ([typed or dropped answers](2026-11-19-save-window-fallback-replaces-a-file.md)) made the helper's answers
unconfirmed and tested that a confirmed answer replaces. No check answered with a free name and then put a file there.

## Fix

- `SystemFileWindows.openSave`: an answer from macOS's own window allows replacing only when a file is at the answered URL
  at that moment, which is the case in which the window asked. The look runs off the main thread through
  `ExportDestinationProbe`, within 5 s (`replaceLookDeadline`). A drive that doesn't answer allows nothing, so the write
  then refuses a file that is there and the caller asks `FileReplaceQuestion`. All callers read the same `SaveLocation`
  (the project's Save As and the close of an untitled project, the subtitle editor's Export As, the recording's setup
  sheet), so none of them changed.
- `ScreenRecordingFileCommit.commit`: `replaceItemAt` only in the branch the person confirmed (`replacesExistingOutput`).
  Every other target goes through `commitNew`: the main file, each numbered name and the microphone sidecar. `commitNew`
  writes each name into the journal first, then makes one rename that fails when the name is taken
  (`ExclusiveInstall.renameIfFree`, `renamex_np(RENAME_EXCL)`). A name taken meanwhile moves on to the next one, journaled
  again. The crash recovery's two commits (`commitRecovered`) use the same `commitNew`.
- On a drive without the exclusive rename (exFAT), `commitNew` looks and then calls `moveItem`, which refuses a taken name
  too. A file appearing in the instant between the two could still be replaced. A copy can't stand in for the rename:
  after a crash mid-copy, the journal could not tell the half-written file at the name from a finished one
  ([recording lifecycle](../architecture/screen-recording-lifecycle.md) "文件覆盖与命名" item 5).
- Rules: [system file windows](../architecture/system-file-windows.md) rule 9, [recording lifecycle](../architecture/screen-recording-lifecycle.md).

## Verification

- `scripts/check-export-profile.sh`, new `SaveAnswerChecks`, with fake windows and real files:
  - an answer naming a file that is there may replace;
  - **a free name may not, and a file saved there after the window answered keeps its bytes** through `NewFileClaim.write`;
  - a drive that never answers the look allows nothing, and the answer still comes at the deadline;
  - the helper's three answers may not replace;
  - a confirmation covers only its URL.

  182 assertions green.
- `scripts/check-screen-recording-feedback.sh`, new `RecordingCommitChecks`, with real files and the real journal store:
  - **a file that appears at a free name right after the commit's intent was persisted** keeps its bytes, the recording
    becomes `Late 2.mov`, and the journal names it;
  - the same for the microphone sidecar (`Talk-Mic 2.m4a`);
  - a confirmed commit replaces the file that is there.

  85 checks green.
- Reverse verification (each red, then green after restoring):
  - A: `mayReplace` back to "answered by macOS's own window" → 3 red: the free name, the late file replaced, the stuck
    drive;
  - B: the old commit body → 3 red: the late file replaced with the recording, the journal naming the old name, the sidecar
    commit failing.
- Scan guards:
  - `checks/file-io-off-main-wiring.sh` requires the observed decision and forbids `mayReplace: inSystemWindow`.
  - `checks/screen-recording-ai-wiring.sh` section 3 requires `replaceItemAt` only in the confirmed branch, the sidecar
    through `commitNew`, the journal before the exclusive rename, and the recovery's two commits through `commitNew` with no
    `moveItem`. It went red with commit body B.
- Not verified: the real panel service (a person picking names in it), a real exFAT recording.

## Lessons

- "Who answered" is not "what was decided". A confirmation exists only for the file it was about, so record that the
  question was asked (a file was there), not just which window answered.
- Choose a replacing write by the decision, never by looking at the folder just before the write. The look and the
  decision drift apart exactly when another writer is active.
- Test the gap between the answer and the write. Most bugs in this family live there, and it is longest for a recording.
