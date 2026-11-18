# 2026-11-19 A one-frame head or tail at 60 fps crashed inspect_video

## Symptom

Review CXR2 finding R5 (P1). In a 60 fps project, keep one frame of a clip at the start of V1 (a split can leave exactly that) and
cut to another file, with sound on the timeline. `inspect_video` stopped SkyCut while preparing the delivery report's second tier:
Swift's "Range requires lowerBound <= upperBound" trap inside the job's task. The call only reads the project, but a trap is not an
error: `AIInspectionTool`'s `catch` never sees it and the whole app quits. A one-frame tail does the same at the other end.

## Root cause

- `AIDeliveryCutJumps.pictureCuts` counts a change of picture more than half a frame from either end as a cut, so a cut at 1/60 s
  (0.0167 s) is one.
- The cut-jump rule measures `CutSoundWindows`: 0.3 s on each side of the cut, leaving a 0.02 s gap at the cut itself.
  `AIDeliveryCutJumps.windows(at:duration:fps:)` clipped the outer side to the timeline and built the `ClosedRange` first —
  `max(0, time − 0.32) ... time − 0.02`, here `0 ... −0.0033` — and only then checked that each side held a frame. At a one-frame tail
  `time + 0.02 ... duration` is reversed the same way. `AIDeliverySound.prepare` builds the windows for every cut in range (for the
  render), and `AIDeliveryCutJumps.findings` builds them again.
- Only 60 fps (or an off-grid cut closer than 0.02 s to an end) reverses the range: a one-frame head at 24 or 30 fps (0.042 s,
  0.033 s) leaves a short positive side that the length check already dropped. The existing integration cases cut between clips
  seconds long at 24 fps, so nothing reached the edge.

## Fix

`windows(at:duration:fps:)` compares the bounds as numbers — each side at least one project frame — and builds the two ranges only
after that. A side under a frame returns nil, as the function always promised: that cut is not measured, and every other cut is
measured as before. `Sources/SrtFlow/AIDeliveryCutJumps.swift`.

## Verification

- Reproduced on main `e030ba67` with the new check before the fix: the real job trapped (`Fatal error: Range requires lowerBound <=
  upperBound`, SIGTRAP). That run is the reverse verification; with the fix it is green.
- `checks/VideoInspection/DeliveryEdgeChecks.swift` (`SRTFLOW_INSPECTION_CASE=edges scripts/check-video-inspection.sh`; also run from
  `SoundTierChecks`, so the full and `sound` cases include it): the real inspect_video job on a 2 s 60 fps timeline — a one-frame head
  and tail between two files, a noise bed that drops 40 dB at 1.0 s — finishes and reports the jump at 1.0 s and nothing at the edges.
  On values: the windows at 1/60 s and 2 − 1/60 s are nil, a middle cut keeps its 0.3 s windows, a two-frame side is still measured.
- The other ranges built on the delivery and inspection path were read for the same pattern (`AIDeliveryMix`, `AIDeliverySoundLevels`,
  `AIDeliveryVoice`, `DeliveryWindowHighPass`, `AIDeliveryLinger.measure`, `AIInspectionSpeech`): each checks its bounds first.
  set_transition sound's measurement (`CutSoundMeasure.level`) compares `to > from` before reading.

## Lessons

- Check a window's bounds as numbers before building a `ClosedRange` or `Range` from them: a trap is not an error a job can catch, so
  one bad input stops the app instead of failing one call.
- Edge cases depend on the frame rate: test a one-frame head and tail at every project rate, not only the default 24 fps.
- The lasting rule is in [finished-video inspection](../architecture/finished-video-inspection.md), "Second-tier sound checks" →
  Measuring.
