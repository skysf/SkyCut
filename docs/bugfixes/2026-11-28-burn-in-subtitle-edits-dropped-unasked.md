# 2026-11-28 A Burn In subtitle's unsaved edits were dropped without asking

## Symptom

On the Burn In page, edits typed into a subtitle (a video's row, or a subtitle file opened on its own) stay in memory until
Save. Ordinary actions threw them away without a word:

- choosing a subtitle file for a video whose subtitle had unsaved edits, another file or the same one again (a row's
  Choose…, which shows once every line is deleted, and the page's drop with its pairing by name): the subtitle was replaced
  by the file as it is on the drive;
- removing the video (✕), or Clear Finished;
- Quit, and Restart and Update, which quits the same way: only projects were asked about;
- opening the open standalone subtitle file again (a double-click in Finder, a drop): it was read from the drive again over
  its edits; only another file was refused.

Found in the CXC1 review (B79) and listed as L2–L5 in the LOSS2 design note. The first fix's review (CXM1) found three more
ways in: Don't Save after a Save that had timed out reloaded the original, then the late write emptied the file (44 → 0
bytes) while the editor showed it saved; a time typed into a cell and not entered yet was not asked about at ⌘Q; and a Save
from the page still being written made Quit wait for the page and ask twice. The second review (CXM2) found three more: two
Saves with the text put back to the first read as saved when the first landed, so ✕ and Quit let it go and the drive kept
the second; a time typed while ✕'s Save was written was dropped with the row; a write that failed after Cancel lost its
reason.

## Root cause

- Each place keeps its own copy of the text (`BurnInRequest.document`, `StandaloneSubtitleStore.document`) with a
  `hasUnsavedEdits` flag, and nothing that removed or replaced a copy looked at the flag: `EncodeQueue.remove` and
  `clearFinished` dropped rows, `BurnInView.attach` replaced the row's request, `ProjectQuit.begin` asked only the open
  projects.
- `StandaloneSubtitleStore.open` guarded only "another file while there are unsaved edits" (`hasUnsavedEdits, url !=
  fileURL`); the same URL fell through to the reload.
- CXM1's cases: a write that answered "not responding" goes on and lands later, but the question that came back offered Don't
  Save as if nothing were on its way, and the reload read the old file before that write replaced it; the start / end cell
  keeps the typed time in view state and writes it only on Return or focus loss, after SwiftUI's next update, so a check made
  at once never saw it; Quit waited for the page's whole flow (its 15 s deadline) and then asked again itself.
- An earlier attempt (the parked branch `fix/untitled-markers-and-subtitle-replace`, six review rounds) tried to close these
  together with copies, per-copy tokens and file identity; each review found new races. This fix takes only the questions,
  the smallest change with the largest benefit (the user's call, 2026-11-28).

## Fix

- `BurnInSubtitleEdits` (new) is the one way a Burn In subtitle with unsaved edits can go away: `attach` (a row's Choose…,
  the drop and its pairing), `remove` (✕), `clearFinished`, `settleForQuit`. It asks `SubtitleEditsQuestion` ("Save the
  changes to “X”?" with Save, Don't Save, Cancel, as for a project). Save writes the subtitle to its own file first (the
  editor's Save, `SubtitleFileSave`), Don't Save goes on, Cancel changes nothing, and a failed Save asks again with the
  reason. The action touches a subtitle only while it is saved, or exactly as it was when Don't Save was answered. Page
  actions run one after another, each after the questions and saves of the ones before it.
- While a Save of the file is still on its way (`SubtitleFileSave.isWriting`), Don't Save is never offered: "“X” is still
  being saved" with Keep Waiting / Cancel. A file is never read into a video while a write to it is on its way. When a write
  lands, the subtitle's mark follows the drive (`BurnInSubtitles.follow`). Quit takes over from the page's actions under way:
  they stand down, and Quit asks once.
- A time typed into a cell and not entered yet is a draft (`PendingTimecode`, `TimecodeField`) that every check that asks
  writes first, as the edit page ends a project's pending typing before it closes.
- Review CXM2: a landing marks a subtitle saved only when no newer Save of its file is still being written, and a subtitle
  with any Save still being written counts as unsaved for ✕, Clear Finished and Quit; before a page action runs, the
  subtitles are looked at again (a time still being typed written first) and anything changed is asked about again; the
  last write failure of its file is kept and shown the next time it is asked about, until a later save of it lands, the
  editor panel's included (review CXM3). Don't Save covers only the subtitle's
  unsaved edits: an Export As the person already confirmed for it is a separate action and still writes its file.
- The alerts come from `RunLoopAlert`: a run-loop timer, never inside a Swift task
  ([system file windows](../architecture/system-file-windows.md) rule 10), never inside another alert, in the default and the
  modal-panel modes: measured with a probe app, while Quit waits for its answer (`terminateLater`) AppKit runs the run loop
  only in the modal-panel mode, and a default-mode timer never fired.
- `ProjectQuit`: `.terminateNow` only when no project and no Burn In subtitle needs asking (`quitsAtOnce`); `prepareEach`
  keeps its project loop as it was and settles the subtitles after it (a Save there waits at most Quit's grace), then looks at
  the projects again; the last look before the reply covers both.
- `BurnInView`: the row's ✕, Clear Finished and every attach call `BurnInSubtitleEdits` (597 → 570 lines); a video just paired
  by name is not offered a leftover subtitle while its question is pending. `StandaloneSubtitleStore.open`: the open file
  opened again keeps its unsaved edits.
- Rules: [export settings](../architecture/export-settings.md) §9; [project file](../architecture/video-edit-project-file.md)
  §5 item 6 for Quit.

## Verification

- `scripts/check-export-profile.sh` (`SubtitleEditsChecks`, 29 assertions): the page's own calls on a real queue and real
  files, the production alerts' buttons pressed by title. ✕, Clear Finished and another file (or the same one again) ask;
  Cancel keeps, Don't Save lets go, Save writes first, a failed Save asks again with the reason; nothing is asked without
  edits; an edit typed while a Save is written is asked about again; a finished row edited after its Don't Save, while
  another row is saved, stays; a later choice for the same video wins; the open standalone file opened again keeps its edits;
  CXM1's sequence (every line deleted, the same file chosen again, Save held past its deadline) asks Keep Waiting / Cancel
  only, reads nothing over the edits and marks the row by the drive when the write lands; Keep Waiting goes on once it
  landed; a file being written is read into a video only after its write landed; a time still being typed, the only edit,
  is asked about at ✕; CXM2's orderings: two Saves with the text put back stay unsaved and ✕ asks while the second is
  written, an unedited subtitle still being written makes ✕ ask, a time typed while ✕'s Save is written is asked about, a
  failure after Cancel is shown next time and cleared by a later Save from the panel; a row edited after its Don't Save is asked about again; no alert inside a Swift
  task.
- `scripts/check-project-saves.sh` (`SubtitleQuitChecks`, 11 assertions): a row and the standalone file with unsaved edits
  keep Quit from quitting at once; Cancel stays and tells Restart and Update; Don't Save goes on with nothing written; a Save
  whose drive does not answer within Quit's grace asks Keep Waiting / Cancel, and its late landing still marks it saved; Save
  writes first; a page ✕ whose Save is still being written when Quit comes gets one question and one Cancel, and the page's
  action stands down; a time still being typed is written first by `quitsAtOnce` and by `prepareAll` alone.
- `checks/file-io-off-main-wiring.sh`: the page drops rows and replaces subtitles only through `BurnInSubtitleEdits`, Quit
  settles the subtitles, the alerts' timer runs in the modal-panel mode and never from a task, Keep Waiting while writing,
  Quit taking over, the cell's draft and the places that write it first.
- Each part undone on its own, run, and restored byte for byte:

  | Part undone | Red |
  | --- | --- |
  | ✕ without asking | 2 |
  | Clear Finished without asking | 2 |
  | Clear Finished not re-checking each row | 1 |
  | attach without asking | 6 |
  | a failed Save asked about again without the reason | 1 |
  | page actions not waiting for the ones before | 1 |
  | the question asked inside the caller's task | 1 |
  | Don't Save and Cancel swapped in the alert | 7 |
  | Don't Save offered while a Save is still being written | 3 |
  | a file read into a video while a write to it is on its way | 1 |
  | the mark only ever set to saved (never following the drive) | 1 (export-profile) |
  | ✕ not writing a time still being typed | 1 |
  | Quit settling projects only | 5 (project-saves) |
  | `quitsAtOnce` ignoring subtitles | 1 (project-saves) |
  | a Save at Quit waiting the editor's 15 s instead of Quit's grace | 1 (project-saves) |
  | Quit waiting for the page's actions | 2 (project-saves) |
  | the page's actions not standing down at Quit | 1 (project-saves) |
  | `quitsAtOnce` / `prepareAll` not writing a time still being typed | 1 each (project-saves) |
  | the row's ✕ calling the queue directly; the alerts' timer without the modal-panel mode; the cell keeping its draft | wiring scan |
  | the old `open` (same file read again) | 2 |
  | a landing marking saved with a newer Save still being written | 1 |
  | a subtitle still being written not counted as unsaved | 1 |
  | no second look before the action | 2 |
  | the kept failure not shown in the question | 2 |
  | a later landing keeping the old failure | 1 |

- Not verified in a real window: the alerts themselves, Escape and Return, a real sleeping drive, Quit and Restart and
  Update with a real alert ([export settings](../architecture/export-settings.md) manual item 23).

## Lessons

- Anything that can hold unsaved work needs one gate before it goes away, as projects have `prepareToClose`. List every path
  that drops it (remove, clear, replace, reopen, quit) and send them all through that gate.
- An answer covers only what it was asked about. After any wait (a question, a write), look again before acting.
- A write that answered "not responding" is still on its way. Until it lands, never offer to give up what it writes, and
  never read the file into an editor.
- Text a field holds and the model does not (a cell being typed into) must be written before any check that asks.
- A saved mark waits for the newest requested save of the file; until it lands, the subtitle is unsaved.
- An alert shown from a timer or a run-loop block during Quit must be scheduled in the modal-panel mode too: `terminateLater`
  runs the run loop only in that mode.
- Still open, on purpose (the larger change): one subtitle file given to two places is two copies; files are told apart by
  path; subtitle files are read on the main thread ([export settings](../architecture/export-settings.md) §9 item 7).
