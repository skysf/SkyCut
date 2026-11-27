# 2026-11-27 An untitled project with only ruler markers and their notes closed without asking

## Symptom

Found by code review CXC1 (of the Check for Updates… crash fix), not reported by a user. A project that was never saved, whose
only content was markers on the ruler — with the notes typed into them — closed without "Save this project before closing
it?": Quit, Restart and Update, File ▸ New Project, Open / Open Recent, a project window's close button, the AI's
`close_project`. An untitled project has no autosave, so the markers and their notes were gone. The fix's review (CXL1) found
the same for review reasons: an untitled project left with one review reason after its last clip was deleted closed on New
Project with 0 questions, and the reason was gone.

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
3. Review reasons (v35) and a pinned Sky Studio style version (v40) were not on it either. The first version of this fix
   judged review reasons not to be content ("they describe clips that are gone, nothing shows them"), which contradicts the
   inspection rule: `inspect_video` keeps listing them, as not reproduced, until they are explicitly cleared. A pinned version
   decides which version of the style the film reads next time.
4. A translation track without an original was not on the list. SkyCut's own flows never leave one (removing the original
   removes it, and every subtitle edit keeps the original), but the file can hold it.

## Fix

- `isEmpty` (`VideoEditModels.swift`) counts markers on the ruler, with or without a note, a translation track, review
  reasons and a pinned Sky Studio style version. It stays the one answer — no second notion of empty next to it. Every field
  the project file keeps was checked; what counts and what doesn't (settings, switches, a style's source alone), and why, is
  the rule in [project file](../architecture/video-edit-project-file.md) §5 "What an empty project is", which now agrees with
  [finished-video inspection](../architecture/finished-video-inspection.md).
- Every caller of `isEmpty` already meant "the project holds something the person made", so they all follow: an untitled
  project with only ruler markers now keeps its timeline (markers visible) instead of the start screen; Play and Export are
  enabled as for a project with only a grade or a storyboard (Export says "Add at least one clip to the main track first.");
  the AI no longer replaces it in the main window with its own project, and `close_project` saves it first instead of
  dropping it; a saved version keeps it.

## Verification

- `scripts/check-project-file.sh` group 54 (`EmptyProject.swift`, 24 assertions): each kind of content alone is not empty —
  a ruler marker without and with a note, a clip on each kind of track, the original and the translation track, a shape, a
  text, a grade carrying a marker, a storyboard, an explicit ending, a review reason, a pinned Sky Studio style version; each
  kind of setting alone (canvas, frame rate, faders, eyes and magnet, tracks without clips, subtitle style / place /
  highlight / lines, a preset's style record) is; files holding only ruler markers, or only review reasons, read back with
  them and are not empty.
- `scripts/check-project-saves.sh` `UntitledContentChecks` (9 assertions), real App objects and production calls: media in,
  a ruler marker with a note, the media out — the project does not close at once; closing, New Project and Quit each ask;
  Cancel, and Save… to a place that can't be written, keep the project with its marker and note; Discard lets it go. A clip
  plus a review reason, or plus a pinned style version, then the clip deleted (Codex's measurement): New Project asks, and
  Cancel keeps it.
- Reproduced on unchanged main before the first fix: group 54 red 4 times (the two ruler-marker cases, the translation track,
  the file read back), the ruler-marker flow red 6 times (it closed at once; closing, New Project, Quit, the failing save and
  Discard never asked).
- Reverse verification: `rulerMarkers.isEmpty` taken out → group 54 red 3 times and the ruler-marker flow red the same 6
  times; the translation condition taken out → 1 red; review reasons taken out → group 54 red 2 times (the reason alone, the
  file read back); the pinned version taken out → 1 red; both taken out → `UntitledContentChecks` red twice ("asked 0", as
  Codex measured). Restored: 1,451 checks and 73 assertions, all green.
- Not verified here: the real alert in a real window (manual item in [project file](../architecture/video-edit-project-file.md)
  §7).

## Lessons

- A list that says what "empty" is has to grow with the file format: a new field the project file keeps goes on one side of
  it in the same change. The rule now names both sides, and group 54 pins them.
- Data protected by a format version because it is hand-typed is content for every other question too — closing an untitled
  project, the start screen, saved versions.
- Before deciding a field is "not content", read the rule of the feature that owns it: what its own tools still show decides,
  not whether it still makes sense without the clips.
