# 2026-11-18 Changing a screen recording's source range shortens or deletes its narration subtitles

## Symptom

B07 lesson project (2026-11-11, production feedback UI-3): V1 holds screen recordings, A1 the local narration (`add_voiceover`,
subtitles on). Changing which part of a recording plays (a new source range for the clip) "again" shortened or deleted the
subtitles above it. The tester restored them by the narration's timing and re-checked six subtitles against three narration
clips by hand. The report does not say whether the change was made in the editor or with `edit_clip`; both run the same rules.

Reproduced on main `6e285c66` with `checks/TimelineSnap/LinkageVoiceCues.swift` (group 1k): a recording at [0,10), narration
across the cut at [6,14) with three subtitles. `source_in` 0 → 4 moved two of them 4 s earlier, off their words, and the
translation of the first with them; ending the recording 3 s earlier (`source_out` 10 → 7) deleted one and cut the other to
0.8 s — while the narration audio did not move at all. Ten checks failed.

## Root cause

Linkage has two subtitle rules: rule 12 makes a subtitle follow the V1 **picture** under it (both ends mapped; deleted when
less than half of its speech survives, trims included), and rule 11 makes a subtitle generated from a clip **off V1**
(`provenance.clipID`: narration, an interview on an audio track) follow that **sound**. The rule-11 case said the two "do not
stack", but `TimelineLinkage.followMain` ran rule 12 on every subtitle first, and rule 11 then skipped whatever rule 12 had
already touched. So whenever V1 changed, narration subtitles were judged by the screen recording's picture — which never held
their words — and a new source window looked like "this speech was trimmed away". A V1 drag (rule 8) also carried them with the
dragged clip even when their narration stayed behind. Translations had no rule-11 path at all.

The 2026-10-15 rule "trimmed speech deletes its subtitle" was right for subtitles of V1's own sound; the gap was which
subtitles that rule may touch.

## Fix

One map decides which subtitles belong to a sound off V1: `CaptionSourceFollow.voices(in:)` (original cues whose source clip
is not on the main track, plus translations sitting on the clip all their originals came from). All three places use it:

- `TimelineLinkage.followMain` leaves the ones sitting on their sound out of the picture rule;
- `CaptionSourceFollow.plan` moves, retimes or deletes them by their sound, translations included (they show the same words);
- `TimelineLinkage.attachments` carries them in a V1 drag only when their sound rides along, landing with it (same host).

"Sitting on it" (the subtitle overlaps the clip on the timeline) keeps a known rule-11 limit from spreading: after a narration
is split, the right half's subtitles still name the left half. Owned by the left half, they would be deleted with it even
though their words are in the right half; not sitting on it, they keep following the picture as before.

Subtitles without a source (typed, imported) and subtitles generated from V1's own sound follow the picture as before. When the
narration itself moves with the picture (both shots ripple), its subtitles still land where rule 12 used to put them.

## Verification

- `scripts/check-timeline-snap.sh` group 1k: new source window, shorter recording, ripple with the narration on top, moving
  and deleting the narration (translation included), the drag attachments, and a split narration whose left half is deleted.
  Reverse verification: without the three wirings (only the map added) 10 checks fail — the same 10 the first run on main
  showed; letting the picture rule skip every voiced subtitle, sitting on its sound or not, fails the split case. With the
  fix all 708 pass, including the existing linkage groups 1f–1j.
- Not covered by automation: the real editor's trim handles and an MCP `edit_clip` on a real lesson project; listed in the
  manual regression of [linkage](../architecture/timeline-linkage.md).

## Lessons

"The two rules do not stack" needs one owner list both rules read; "whoever runs first wins" silently lets the general rule
take the special case. When a subtitle is shortened or deleted, ask what its words came from before asking what is under it.
The rule now lives in [linkage](../architecture/timeline-linkage.md) rules 8, 11 and 12.

## Follow-up (2026-11-19): typed subtitles over a silent recording

The first fix left one part of the symptom: a subtitle with no recorded source (typed, imported) over a screen recording
without audio still went through rule 12, so a new source range that dropped its stretch of picture deleted it, and a trim
cut it short — as if it were speech of a picture that has no sound. The open question went to Master, who decided
(2026-11-19): such subtitles follow the picture the way linkage does by default.

- Fix: `LinkageCueFollow.overSilentPicture` — when every V1 clip under a subtitle is known to have no sound of its own
  (`info.hasAudio == false`: a screen recording without audio, a still), `TimelineLinkage.followMain` gives it the default
  outcome (rules 2–4: moved whole with its picture, left in place when a trim takes the picture away, deleted only by a real
  delete) instead of rule 12. A clip not probed yet counts as having sound; over a picture with sound nothing changes.
- Verification: `scripts/check-timeline-snap.sh` group 1k now runs on a silent recording (as in B07) and contrasts one with
  sound and one not probed. Before the change 3 checks fail (the typed subtitle and its translation deleted on a new source
  range, the report counting them, and a ripple cutting it to [0,1) instead of moving it whole to [0,2)); after, 713 pass.
