# 2026-11-19 A narrower range still could not reach the 41st sound past its picture

## Symptom

Review CXR2 finding R8 (P2). A long film with 41 sounds named `object`, each ringing a few frames past its shot's cut. The report
measured the first 40 and said "Only the first 40 sounds past their picture were measured; inspect a narrower from/to for the other
1". Inspecting only the last cut, as advised, found nothing: that call measured 40 sounds outside its range and skipped the one inside.

## Root cause

`AIDeliveryLinger.candidates` picked candidates over the whole timeline, sorted them by cut, kept the first 40 and counted the rest;
the checked range was applied only afterwards, in `AIDeliveryLinger.findings`. The cap ran before the range, so a narrower from/to
never changed which 40 were measured — the opposite of what the limitation advised.

## Fix

`AIDeliveryLinger.candidates` takes the checked range. Which shot a sound belongs to is still read against every cut of the timeline
(a sound brought in early belongs to the next shot even when that cut is outside the range); then the candidates whose cut is outside
the range are dropped before sorting, the cap and the count of the rest. `AIDeliverySound.prepare` passes its scope, so `more` (and
the limitation) counts only what this range leaves out. `Sources/SrtFlow/AIDeliveryLinger.swift`, `Sources/SrtFlow/AIDeliverySound.swift`.

## Verification

- `checks/VideoInspection/DeliveryEdgeChecks.swift` (`SRTFLOW_INSPECTION_CASE=edges scripts/check-video-inspection.sh`): 42 half-second
  shots alternating two files and 41 named objects ringing 0.25 s into the next shot. Whole timeline: 40 picked, 1 left out. A range
  holding only the last cut (20.25–21 s): one candidate at 20.5 s and none left out; the production preparation
  (`AIDeliverySound.prepare`) measures only it, with no cap note, and the lingers rule reports it.
- Reverse: with the range filter removed, the narrow range picks the 40 earlier cuts, the preparation keeps the cap note and the
  report is empty (3 assertions fail); with the fix restored they pass.

## Lessons

Apply the caller's range before a cap, never after: a cap in front of the filter makes the narrower request useless. Keep the
context that decides meaning (here every cut, for which shot a sound belongs to) apart from the subset that is measured.
The lasting rule is in [finished-video inspection](../architecture/finished-video-inspection.md), "Second-tier sound checks" →
Measuring.
