# 2026-11-27 An untitled project with only ruler markers and their notes closed without asking

## Symptom

Found by code review CXC1 (of the Check for Updates… crash fix), not reported by a user. A project that was never saved, whose
only content was markers on the ruler — with the notes typed into them — closed without "Save this project before closing
it?": Quit, Restart and Update, File ▸ New Project, Open / Open Recent, a project window's close button, the AI's
`close_project`. An untitled project has no autosave, so the markers and their notes were gone.

How to get there: add media, click the ruler and press M (or right-click the ruler ▸ Add Marker Here), double-click the flag
and write a note, delete the media. The timeline also went back to its empty placeholder (or the start screen), so the markers
could not even be seen any more.

## Root cause

1. Whether there is anything to ask about is `TimelineState.isEmpty` (`prepareToClose`, `closesAtOnce` and the checks'
   `prepareToCloseDocument` in `ProjectClosing.swift`): an untitled project is asked about only when it is not empty.
2. `isEmpty` is a list of the content kinds, kept by hand: clips on each track, the subtitle, shapes, texts, grades, the
   storyboard (added with v34) and an explicit ending (v37). Ruler markers came with v28 (2026-09-30) — into the project file,
   behind a format version precisely because they are hand-typed data that can't be got back — but not into that list. Markers
   on blocks were never at risk: they come with their block, which counts.
3. A translation track without an original was not on the list either. SkyCut's own flows never leave one (removing the
   original removes it, and every subtitle edit keeps the original), but the file can hold it.

## Fix

- `isEmpty` (`VideoEditModels.swift`) counts markers on the ruler, with or without a note, and a translation track. It stays
  the one answer — no second notion of empty next to it. Every field the project file keeps was checked; what counts and what
  doesn't, and why, is the rule in [project file](../architecture/video-edit-project-file.md) §5 "What an empty project is".
- Every caller of `isEmpty` already meant "the project holds something the person made", so they all follow: an untitled
  project with only ruler markers now keeps its timeline (markers visible) instead of the start screen; Play and Export are
  enabled as for a project with only a grade or a storyboard (Export says "Add at least one clip to the main track first.");
  the AI no longer replaces it in the main window with its own project, and `close_project` saves it first instead of
  dropping it; a saved version keeps it.

## Verification

- `scripts/check-project-file.sh` group 54 (`EmptyProject.swift`, 23 assertions): each kind of content alone is not empty —
  a ruler marker without and with a note, a clip on each kind of track, the original and the translation track, a shape, a
  text, a grade carrying a marker, a storyboard, an explicit ending; each kind of setting alone (canvas, frame rate, faders,
  eyes and magnet, tracks without clips, subtitle style / place / highlight / lines, review marks, the style record) is; a
  file holding only ruler markers reads back with them and is not empty.
- `scripts/check-project-saves.sh` `UntitledMarkersChecks` (7 assertions), real App objects and the production marker calls:
  media in, a ruler marker with a note, the media out; the project does not close at once; closing, New Project and Quit each
  ask; Cancel, and Save… to a place that can't be written, keep the project with its marker and note; Discard lets it go.
- Reproduced on unchanged main (the two checks above, before the fix): group 54 red 4 times (the two ruler-marker cases, the
  translation track, the file read back; 1,450 checks in all), `UntitledMarkersChecks` red 6 times (it closed at once;
  closing, New Project, Quit, the failing save and Discard never asked: 71 assertions in all).
- Reverse verification: `rulerMarkers.isEmpty` taken out of `isEmpty` again → group 54 red 3 times (the translation case stays
  green) and `UntitledMarkersChecks` red the same 6 times; the translation condition taken out → exactly 1 red. Restored:
  1,450 checks and 71 assertions, all green.
- Not verified here: the real alert in a real window (manual item in [project file](../architecture/video-edit-project-file.md)
  §7).

## Lessons

- A list that says what "empty" is has to grow with the file format: a new field the project file keeps goes on one side of
  it in the same change. The rule now names both sides, and group 54 pins them.
- Data protected by a format version because it is hand-typed is content for every other question too — closing an untitled
  project, the start screen, saved versions.
