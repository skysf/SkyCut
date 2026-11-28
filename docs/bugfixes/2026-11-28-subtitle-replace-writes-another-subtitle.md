# 2026-11-28 The subtitle editor's Replace wrote another subtitle into the chosen file

## Symptom

On the Burn In page: Export As for subtitle A, answered with a name that already holds a file but that nobody had asked about
(a typed or dropped answer in the file-window helper, or a free name that got a file before the write), so SkyCut asks
"Replace?" itself. If another subtitle B had taken A's place by the time Replace was answered (the standalone file switched,
or A's video left the queue and the panel fell back to the standalone file), B's text was written into the file chosen for
A. An edit made to A in between went in too. The same happened without any question when the save window answered after B
had taken A's place. Found in the CXC1 review (B79, L1 in the LOSS2 design note). The first fix's review (CXM1) added two
points: the Replace question still ran its modal loop inside the save's Swift task, and "Nothing was written" went to the
subtitle panel, unseen once the person had left the Burn In page.

## Root cause

`SubtitleEditPanel.write` took the document when the save window answered, and after `.occupied` and the question it called
`write` again, which read the panel's document again: through the view's captured preview row, falling back to the
standalone file when that row was gone. Nothing tied a write to the subtitle Export As was pressed for. The question was
`FileReplaceQuestion.ask` (`runModal`) called from inside that task, the crash mechanism of
[Check for Updates…](2026-11-27-check-for-updates-crash-tracking-owner-selectors.md); the messages went to the panel's own
SwiftUI alert.

## Fix

- `SubtitleEditorExport` (new; the panel's Save and Export As only call it): the subtitle and its place
  (`BurnInSubtitles.panelPlace`: the preview row, or the standalone file) are taken when the button is pressed. Before each
  write, when the save window answers and when Replace is answered, that place must still hold exactly that subtitle, the
  same file and text. Otherwise nothing is written and the person is told "Nothing was written: the subtitle changed. Export
  again." The place is the row or the standalone file, not the panel: the preview moving to another video's row while the
  standalone file stays open, unedited, still exports that file. No queues, no ordering and no file identity: the smallest
  safe change (the user's call, 2026-11-28).
- The Replace question is asked from a run-loop turn (`FileReplaceQuestion.askFromRunLoop`, through `RunLoopAlert`), never
  inside the save's task; what a save has to say is an app-level "Could Not Save" alert from a run-loop turn, seen off the
  Burn In page too (the panel's own alert is gone).
- When a write lands on the subtitle's own file, its mark follows the drive: saved only while it holds exactly what was
  written, in its own format.
- Rule: [system file windows](../architecture/system-file-windows.md) rules 9 and 10.

## Verification

- `scripts/check-export-profile.sh` (`SubtitleExportChecks`, 9 assertions), through the panel's own `exportAs` / `save` on
  real files, a save window the check answers late, and the production "Replace?" and "Could Not Save" alerts' buttons pressed
  by title: B in A's place, A edited, or A's video gone by the time Replace is answered writes nothing and says so in an
  app-level alert; unchanged, Replace writes A; a window answered after B took A's place writes nothing; the preview moving
  to a video's row while A stays open on its own exports A; Save marks A saved; an export in another format onto its own
  file leaves it unsaved; no alert, Replace included, ran inside a Swift task.
- Each part undone on its own, run, and restored byte for byte: no check before a write turns 4 red; the old retry (whatever
  the panel shows by then) turns 3 red and writes "Line from B" into the file chosen for A; Replace asked inside the save's
  task turns the thread assertion red; the message not shown at app level turns 4 red; the mark only ever set to saved
  turns 1 red. `checks/file-io-off-main-wiring.sh` goes red for each wiring part (the check line, the retry writing what was
  pressed, Replace from the run loop, the app-level message).
- Not verified in a real window: manual item 5 in [system file windows](../architecture/system-file-windows.md).

## Lessons

- A retry after a question writes what the question was about, never what the screen shows by then.
- A non-modal window or a write off the main thread leaves time for the world to change. Check the subject again at each
  step, or refuse with a clear sentence.
- A message about work started on a page must not depend on that page being on screen when the work ends.
- A question awaited inside a task is asked from a run-loop turn, never by running its modal loop in the task.
