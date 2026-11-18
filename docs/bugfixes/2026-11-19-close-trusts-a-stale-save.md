# 2026-11-19 Closing a project counted a write of an older snapshot as "saved", and a late save window wrote the wrong project

## Symptom

Found by code review CXR2 (R1, P1), not reported by a user. Three ways to lose work while closing or switching projects:

- A saved project with unsaved edits; New Project (or the project window's close button, the AI's `close_project`, Quit).
  The write takes a moment (an external drive, a slow disk) and during it the person types into a subtitle, or an AI tool
  call edits the project. The project then went away — replaced by the new one, its window destroyed, SkyCut quit — and the
  file held the state from before that last edit.
- Quit with two projects: the first is written and let through; while the second one's drive is asked about (the alert),
  the first one changes (an AI tool call runs inside the alert's modal loop). Quit said yes without looking at the first one
  again.
- An untitled project with content: New Project → "Save…" → the macOS save window opens (it is not modal). Meanwhile
  Open Recent opens project B in the same window, and the second question about the untitled project is answered
  "Discard". When the first save window was answered after that, SkyCut wrote **B's** state to the place chosen for the
  untitled project, and B's document moved to that new file.

## Root cause

1. `prepareToClose` turned `flushToFile`'s `.saved` straight into `.ready`. `.saved` says "the write that was asked for
   landed", and that write carried the snapshot taken when it was asked. Since the off-main-thread writer
   ([case](2026-11-19-project-save-blocks-on-slow-drive.md)) `adoptWritten` correctly keeps the project dirty when the change
   counter moved during the write — but nothing looked at the dirty mark again before answering, and every caller acts on
   `.ready` at once (`replaceWithNewProject`, the window's `close()`, `OpenProjects.finishClose`, Quit's reply). That
   case's own lesson ("the write finished" is not "the project is saved") was applied to the dirty mark, not to the decision
   that read it.
2. `ProjectQuit.prepareEach` walked the open projects once: a project let through was never looked at again, and the reply
   was given after awaiting a separate Task, which leaves a gap where another main-actor job can run.
3. The untitled branch awaited the save window and then called `saveAs(url)`, which takes a snapshot of whatever the project
   holds *now*. The menu's Save As checks the document generation after its window; the close path did not, and the outer
   `openRequestToken` check in `startNewProject` only ran after the write had happened.

## Fix

- **`ProjectClosing.swift`** (new; the gate moved out of `VideoEditProjectDocument.swift`, which was at 499 lines):
  `prepareToClose` remembers the document generation it started with. A named project is written by `writeForClosing`:
  after each write that lands, the answer is `.ready` only if it is still the same document, nothing is unsaved and nothing
  is being written; if it changed meanwhile the newer state is written too, in what is left of the same deadline (past it:
  `.waitingForDrive`). The untitled branch drops the save window's answer — and a "Discard" — when another document
  replaced the project during the wait, before anything is written. A screen recording that started during the wait
  refuses, as it does at the start.
- **`ProjectCloseQuestions`**: the untitled alert and the save window, as seams the checks answer.
- **`ProjectQuit`**: settles projects until one look finds each with nothing to write, let through and unchanged since, or
  given up ("Quit Anyway"); projects opened meanwhile are included. Both replies — `applicationShouldTerminate`'s and the
  screen recording's (`ScreenRecordingCoordinator.settleTerminationIfPossible`) — are closures called in the same
  main-thread turn as that last look (`prepareAll(reply:)`), not after an awaited Task.
- Rules: [project file](../architecture/video-edit-project-file.md) §5 "Writing the project file off the main thread"
  items 4 and 6 and "切工程必须是事务性的" item 5; [open and save windows](../architecture/system-file-windows.md) rule 7.

## Verification

- `scripts/check-project-saves.sh`, new `EditWhileClosingChecks` (the drive holds each first write until the check has
  edited, so "ready after the write it asked for" shows as an edit missing from the file):
  - New Project: the edit typed during its write is in the file, then the new project appears;
  - `OpenProjects.closeProject` (the AI's close; the window's close button asks the same `prepareToClose`): closed, edit in
    the file;
  - Quit: the edit made during its write is in the file before it says yes, nobody asked;
  - Quit with two projects: the first one edited while the second one's drive is asked about is written again before Quit
    says yes;
  - a save window answered after Open Recent replaced the untitled project: nothing at the chosen place, the opened project
    keeps its own file and content.
  The check now has 43 assertions (13 new), all green.
- Reverse verification (each went red, then green after restoring):
  - `.saved` taken as `.ready` again and the save window's answer used without the generation check → exactly 5 red: the
    New Project, close and Quit edits missing from the file, and the stale save window writing at the chosen place and
    moving the opened project there;
  - Quit back to one pass over the projects → exactly 1 red: the first project's edit made while the second was asked
    about;
  - the screen recording's quit back to awaiting `ProjectQuit.prepareAll()` in a Task → `checks/open-projects-wiring.sh` red.
- Guards moved with the code: `checks/open-projects-wiring.sh` (Quit's loop looks again at a project let through; both
  replies in the turn of the last look), `checks/file-io-off-main-wiring.sh` (the checks-only `prepareToCloseDocument`
  lives in `ProjectClosing.swift`).
- Not verified: the real close button, the real Quit alert and a real slow drive (manual items in video-edit-project-file.md
  §7, item 3).

## Lessons

- Whether a destructive step may go ahead is decided from the state at the moment of answering, not from what an earlier
  await returned: after every wait, check that it is still the same document and that nothing is left to write, then act
  without another await.
- A non-modal window's answer belongs to the document it was opened for: check the generation before using the answer,
  not after the write it causes.
- An await before a reply is a gap other jobs can use; when the reply says "nothing changed", give it in the same turn as
  the look.
