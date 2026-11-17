# 2026-11-17 An AI ripple clamps a J cut's sound at 0:00, so it runs late by its lead-in

## Symptom

Left over from the freeze-ripple fix (G15 report, follow-up 1; no user report). Two V1 clips, the second one's sound separated
and leading by half a second (a J cut: `add_clips sound=separate`, `set_transition sound=lead`, or `edit_clip … alone=true`):

- face 0–4 and ship 4–9 on V1, ship's sound 3.5–9 on A1 (it starts in ship's file 0.5 s before ship's picture does).
- `delete_items ids=[face] ripple=true` → ship moved to 0, and its sound to 0 as well: the half second that would have been
  before 0:00 was not cut off, the whole sound slid right, and it played **0.5 s late** against ship's picture for the rest of
  the clip. The reply said nothing.
- The same with `edit_clip <face> source_out=… ripple=true` (shortening the first clip by more than the lead) and with
  `cut_to_beat` when the first clip comes out shorter than the next clip's lead.

The editor was already right: with the magnet on, deleting the first clip lets linkage rule 13 move the sound and trim its
head (2026-11-16, [case](2026-11-16-separated-sound-left-behind-on-magnet-repack.md)).

## Root cause

1. **The AI's V1 ripple clamped.** `AITimelineEdits.shiftMain` (delete_items / edit_clip ripple, add_clips insert,
   cut_to_beat, cut_speech) moves the V1 clips from a point on and their link partners itself, with
   `timelineStart = max(0, timelineStart + delta)`. For a clip that has source time, clamping is a shift: everything after the
   clamp plays late. Linkage rule 13 trims the head instead (`EditClip.moveForLinkage`), but it never saw the sound: the ripple
   had already moved it, and linkage leaves what an edit moved itself alone (rule 5).
2. **cut_to_beat's own partner fitting clamped too** (`AIBeatCuts.apply`: a listed clip's linked sound follows its start).
3. Nothing told the AI that a lead-in got shorter, so it could not decide to keep the J cut some other way.

## Fix

- `shiftMain` and `AIBeatCuts.apply` move clips with `moveForLinkage` — the one implementation of "pushed before 0:00": the
  part before 0:00 is cut off (in point and fade-in follow), the timing against the picture is kept; a clip wholly before 0:00
  is still clamped (it has nothing left to play).
- `LinkageHeadTrims` (in `VideoEditTimelineLinkage.swift`, which ~20 check scripts compile) finds the clips an edit trimmed
  this way by comparing before and after; `TimelineLinkage.follow` stores them in `Report.trimmedHeads` whenever V1 moved,
  which covers the ripple and rule 13 alike. `AILinkageReport` lists them as `linkage.trimmed_heads` (`id`, `seconds`) with a
  note, so every tool that reports linkage tells the AI.
- Rule written down in [Timeline linkage](../architecture/timeline-linkage.md) §一 and rule 13, the reply in §三.

## Verification

- `scripts/check-mcp.sh` → `checks/MCP/RippleHeadTrimChecks.swift`, production calls only (`ClipSoundSeparation`,
  `AITimelineEdits.delete`, `AIClipEdit.apply`, `AIBeatCuts.layout` / `apply`, `TimelineLinkage.follow`, `AILinkageReport`):
  ripple-deleting the first clip trims the sound's 0.5 s head (in point 9.5 → 10, end kept, fade-in gone) and keeps it in sync
  with ship, the report says 0.5; a ripple that leaves the lead after 0:00 moves it whole and reports nothing; edit_clip ripple
  and cut_to_beat trim 0.1 s each and stay in sync; the reply lists `trimmed_heads` and explains it.
- **Reverse verification** (2026-11-17): with both `max(0, …)` clamps put back, 10 of the 8,177 MCP checks fail (in point,
  fade-in, sync and report in all three paths); with the report hook in `follow` removed, the 3 report checks fail. Restored:
  all pass.

## Lessons

- A clip with source time must never be clamped at 0:00: that is a shift of everything after it. Whatever moves clips in bulk
  goes through `moveForLinkage`, so "pushed before 0:00" has one answer.
- A rule that lives at the end of `perform` (linkage) does not see what an earlier step moved on its own: when two paths move
  the same thing, both need the rule, from one implementation.
- When an edit has to give something up (here, part of a lead-in), say so in the reply; the AI cannot see the timeline.
