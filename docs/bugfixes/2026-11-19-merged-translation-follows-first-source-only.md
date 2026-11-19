# 2026-11-19 A merged translation was kept or deleted by its first original alone

## Symptom

Found in review CXR2 (finding R11, on #473's subtitle linkage). A narration has two original subtitles with word timing,
spoken over 1–2 s and 3–7 s; their two translations are merged into one (the merged translation names both originals).
Trimming the narration's first 2.5 s keeps 4 of the 5 seconds spoken, yet linkage deleted the merged translation (1 → 0)
while the second original stayed. The mirror case went the other way: trimming the tail so that most of the speech was gone
kept a merged translation whose first line survived. The same happened on V1's own picture (rule 12).

## Root cause

Linkage keeps a subtitle when half or more of the seconds it is spoken survive (rule 12, `LinkageCueFollow`). A translation
has no word timing of its own, so `LinkageCueFollow.speech` reads the original it was translated from — but only
`sourceIDs.first`. `SubtitleTrackEditing.mergeCues` legitimately gives a merged translation every source of the lines it
joined, so a merged translation was judged by whichever line came first: 0 of 1 s left (deleted) in the review's case, 1.6 of
2 s left (kept) in the mirror case. The existing checks only had single-source translations.

## Fix

`LinkageCueFollow.speech` returns the stretches spoken, not one span: a translation reads every original it names (each
one's words, or its display time when it has no word timing; overlapping stretches are joined), and only when none of them
has word timing does the translation's own display time count, as before. `survived` adds the kept seconds over all the
stretches and divides by all their seconds, so the keep rule still goes by how long the speech is. Single-source and own-word
cases give the same span as before. Both callers (`TimelineLinkage.followMain`, `CaptionSourceFollow.plan`) pass it through
unchanged. Files: `Sources/SrtFlow/VideoEditTimelineCueFollow.swift`.

## Verification

- `scripts/check-timeline-snap.sh` group 1l (`checks/TimelineSnap/LinkageMergedTranslation.swift`), translations merged by the
  production `mergeCues`: the review's case (the merged translation stays from 2.5 s to its end, the first original is
  deleted, the second stays); two 2 s lines at 1–3 s and 3.5–5.5 s, on a narration (rule 11) and on V1 (rule 12): the head
  trimmed to 2.8 s and the tail trimmed at 3.7 s both keep it (2.2 of 4 s), the head trimmed to 3.9 s and the tail at 2.6 s both
  delete it (1.6 of 4 s).
- Reverse verification: with only the first original read, group 1l has 5 red (the review's case, and on each path the head
  trim keeping 2.2 s deletes it while the tail trim keeping 1.6 s keeps it). With the fix all 728 checks of the script pass,
  including group 1h's single-source translation and the subtitle without words or source.

## Lessons

- When a model allows a list (`sourceIDs`), a reader that takes `.first` silently assumes the list has one element. Look for
  the operation that makes the list longer (here: merging) and test the reader with it.
- A keep / delete rule should give the same answer for the same amount kept, whichever end was cut: checking head and tail
  trims as a pair catches a reader that only looks at one end.
- The rule lives in [timeline-linkage.md](../architecture/timeline-linkage.md) rule 12.
