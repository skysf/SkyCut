# 2026-11-17 Projects saved before the freeze fix still delete the clip with its freeze tail

## Symptom

Left over from the freeze-ripple fix (G15 report, follow-up 2; no user report). Since #444 a freeze no longer gives the piece
after the hold (the "tail") the clip's link group, but a project saved before that still has one:

- The P5 walkthrough's project as SkyCut 0.18.66 saved it: face 0–4 and ship 4–8.958 on V1, a 2 s hold, ship's 0.042 s tail at
  10.958, ship's separated sound on A2 at 3–9 (a J cut). Ship, its sound and the tail share one link group.
- Opened in a build with #444, deleting the tail (what the freeze_frame reply suggests) with linkage on still deleted **ship and
  its sound** as well; dragging the tail still dragged them; trimming it trimmed them. Only ripples were safe
  (`RippleLinkPartners`).

## Root cause

The fix changed how a freeze cuts, not the projects it had already cut. A link group is stored on each clip (`linkGroup`), so
the tail's stale membership came back with every open. G15 left it because a tail can't be told from "a deliberate link" by its
fields alone. It can by its timing: in one link group the pictures of one file are pieces of one clip and play in step (the
same timeline time for the file's 0 s); the tail plays the hold's length later than the clip and its sound. SkyCut has no way to
link clips by hand: groups only come from separating sound, screen recordings and splits, so a picture out of step with its
group's other pieces is never something the user linked on purpose.

## Fix

- `LinkGroupRepair.unlinkStrayPieces` (new, `Sources/SrtFlow/LinkGroupRepair.swift`), run by `VideoEditProjectIO.load` after the
  main track is sorted: in each group, the pictures of one file at one speed keep one timing — the one the group's sound from
  that file plays at, else the earliest picture's — and a picture off it leaves the group (`linkGroup` nil), which is what a
  freeze has done to its tail since the fix.
- Nothing else changes: every clip keeps its place and media, the clip and its sound stay a pair, groups with one picture (a
  separated sound nudged for sync) and pieces at another speed are left alone. It also takes out a piece of a linkage-off split
  that was later moved alone, which `LinkRegrouping` would have done at the next split anyway.
- No format version: no field is added, and an older build reading the repaired file reads a plain unlinked clip.
- Rule written down in [Project file](../architecture/video-edit-project-file.md) ("Opening a project repairs link groups") and
  [Freeze frame](../architecture/freeze-frame.md) §4.

## Verification

- `scripts/check-project-file.sh` group 49 (`checks/ProjectFile/OldFreezeTails.swift`): the walkthrough's project as saved before
  the fix (a literal project file, format 34) opened with the production `VideoEditProjectIO.load`: the tail is unlinked and
  links to nothing else, ship and its sound are still a pair, face's pair and the hold are untouched, every clip keeps its
  place and media; saved and reopened, a second pass changes nothing. Controls through the rule itself: a split left in place
  keeps its group; a piece moved alone leaves it (and the sound decides which piece, even when the earliest one moved); a
  nudged sound with one picture stays linked; a screen recording's old tail leaves while the screen and its mic stay a pair;
  pieces at another speed are left alone.
- **Reverse verification** (2026-11-17): with the call removed from `load`, 5 of the 1,330 project-file checks fail (the tail
  still in the group with ship and its sound, also after saving). Restored: all pass.

## Lessons

- A fix to how data is made does not fix the data already made: ask what old files look like and repair them on open when the
  fix is about structure, not a new field.
- "Can't tell it apart from a deliberate X" deserves a second look at how X can be made at all: here only three code paths
  make link groups, and none makes pieces of one clip play out of step.
