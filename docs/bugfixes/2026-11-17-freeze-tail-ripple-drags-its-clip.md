# 2026-11-17 Ripple-deleting a freeze hold moves the clip before it (and deleting the tail deletes the clip)

## Symptom

Found by walking the editing knowledge cards in SkyCut 0.18.66 over MCP (P5 walkthrough, to-do 1). Two V1 clips added with
`add_clips sound=separate`; the second clip's sound moved to A2 and started a second early (a J cut, same link group).

- face 0–4, ship 4–9 on V1; ship's sound 3–9 on A2.
- `freeze_frame time=8.958` → a 2 s hold at 8.958–10.958 and a 0.04 s `tail_id` at 10.958–11.
- `delete_items ids=[<hold>] ripple=true` → ship moved −2 s to 2–6.958, **on top of face** on V1 (which `edit_clip` itself refuses),
  the tail closed up to 8.958–9 behind a 2 s gap, and the A2 sound moved −2 s to 1–7.

The same without separated sound, or with a freeze inside the last frame (no tail), was correct. Reproduced on main (`5f20457c`)
with the production functions: the same numbers to the millisecond. Reproducing it also showed a worse sibling: doing what the
freeze reply says ("To end on the still, delete tail_id with delete_items") with linkage on deleted the **whole ship clip and its
sound** along with the 0.04 s tail. By the same code path, ⌫ on the tail in the editor deletes all three, and dragging it with the
magnet off drags all three.

## Root cause

1. **The tail inherited the clip's link group.** `insertFreeze` cuts the clip with `TimelineClipSplit.make`, which copies `linkGroup`
   to the right piece (a plain split then regroups by overlap in `LinkRegrouping.split`). The freeze skipped the regroup on purpose:
   the 2026-09-28 case reasoned that a freeze "cuts one clip and takes no partners, so regrouping by overlap gives the same result".
   It does not: the right piece moves on by the hold while the separated sound stays where it was (the freeze only moves its own
   track, freeze-frame.md §4), so the tail is no longer the sound's pair — yet it stayed in the group with the left piece and the sound.
   Every "with its link partners" path then treated the 0.04 s tail, the 5 s clip and its sound as one thing: ⌫ / `delete_items`
   deleted all three, a drag moved all three.
2. **The AI's V1 ripple dragged whole link groups.** `AITimelineEdits.shiftMain` (ripple delete, `edit_clip ripple`, `add_clips insert`,
   `cut_to_beat`) moves the V1 clips from the ripple point on and, with linkage on, every link partner of theirs — including a partner that
   is itself on V1 *before* the ripple point. Deleting the hold with ripple moved the tail −2 s, and with it ship (its "partner") and the
   sound. A group with two pictures on V1 can also come from a split made with linkage off (`LinkRegrouping` keeps picture–sound–picture
   in one chain when the sound spans the cut) and from tails saved before this fix.

## Fix

- `TimelineState.insertFreeze` (`VideoEditTimelineEdits.swift`): the right piece keeps no link group. The left piece and the sound stay a pair.
- `RippleLinkPartners` (new, `Sources/SrtFlow/RippleLinkPartners.swift`), used by `AITimelineEdits.shiftMain`: a ripple brings a mover's link
  group along only when none of that group's V1 pictures stays behind. A V1 clip before the ripple point never moves; a sound shared with it
  stays with it (as linkage rule 13 pairs it with the earliest picture).
- Rules written down: [Freeze frame](../architecture/freeze-frame.md) §4 (the right piece has no partners),
  [Timeline linkage](../architecture/timeline-linkage.md) §一 (which groups a V1 ripple brings along),
  [Copy / cut / paste](../architecture/timeline-clipboard.md) §三之二 (why the freeze does not regroup, corrected).
- One tool call stays one undo step: both changes are pure-value steps inside the same `perform`.

## Verification

- `scripts/check-mcp.sh` → `checks/MCP/FreezeRippleChecks.swift`: the walkthrough's project with production calls (`ClipSoundSeparation`,
  `insertFreeze`, `AITimelineEdits.delete`, `TimelineLinkage.follow`): ripple-delete the hold → V1 starts `[0, 4, 8.958]`, the sound stays at 3,
  no V1 overlap; delete the tail → the clip and its sound stay; a tail still linked as saved before the fix → the ripple moves only the tail
  and the shared sound stays; a plain pair still comes along when the clip before it is ripple-deleted.
- `scripts/check-freeze-frame.sh` → `checks/FreezeFrame/LinkChecks.swift`: the right piece and the hold are unlinked, the left piece and its
  sound are still a pair, the sound is untouched, a freeze at the first frame keeps the pair.
- **Reverse verification** (2026-11-17): without the unlink 6 of 15 FreezeRippleChecks and 3 of the LinkChecks fail; without
  `RippleLinkPartners` 3 fail (`[0, 2, 8.958]`, sound at 1, V1 overlap); without both 12 fail with exactly the walkthrough's numbers.
  Restored: all pass.

## Lessons

- "Copy every field" is wrong for identity-like fields when the new piece no longer sits where the old one did: the 2026-09-28 case
  said so for splits; the freeze moves its right piece, so its link group has to go even though nothing else was cut.
- A rule that moves "X and its partners" must ask whether a partner is also anchored to something that is not moving. Pushing V1 from a
  point on must never move a V1 clip that starts before it.
- Old projects: a tail frozen before this fix still shares its clip's group. Ripples are safe now (`RippleLinkPartners`); deleting such a
  tail with linkage on still takes the clip with it — turn linkage off for that delete, or freeze again.
