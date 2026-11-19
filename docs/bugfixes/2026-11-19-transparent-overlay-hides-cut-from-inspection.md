# 2026-11-19 A transparent title over a cut hid that cut from inspect_video

## Symptom

Review CXR2 finding R7 (P2). Two different clips meet on V1 at 3 s and the place's sound clearly jumps there. A web motion on V2
crosses 3 s: a few words on a clear page, rendered at the canvas size. `inspect_video` did not check that cut: no `audio_cut_jump`,
and a sound ringing past the V1 shot was not checked for `audio_linger` there either, although the change of person and place is
plain in the preview and the export. The title's own start and end were taken as the cuts instead.

## Root cause

- `AIDeliveryCutJumps.pictureCuts` reads the top picture that fills the frame on each side of every clip edge. For upper tracks it
  asked only `ClipCoverage.fill(clip).fillsFrame`, which is geometry: placement, rotation, keyframes. A web-motion movie is rendered
  at the canvas size, so its box fills the frame even when nearly every pixel is clear; the same V2 clip was the top picture on both
  sides of 3 s and the V1 cut disappeared.
- `ClipCoverage` leaves opacity, fades and transparency out on purpose (fills_frame and look's uncovered are about framing).
  `ClipCoverage.coveringPictures` already skips pictures with alpha, but the delivery check did not ask that question. An upper clip
  at reduced opacity, or inside its fade-in or entrance window, hid the cut under it the same way.

## Fix

- An upper clip can hide the pictures under it only when its media has no transparency (`EditClip.sourceAlpha == .opaque`: a web
  motion with any clear pixel, a transparent PNG and ProRes 4444 with alpha are not), and only at moments when it is fully opaque
  (`AIDeliveryCutJumps.hidesBelow`): full opacity, keyframed or not, and outside its fade-in / fade-out window, which entrance and
  exit animations share (fade, rise, pop and zoom ramp the opacity from 0; a wipe reveals the picture). Otherwise the picture below
  decides, so the V1 cut stays a cut for both checks that read `pictureCuts` (cut jumps and lingers).
- A transparent clip's own edges are no longer cuts, and an opaque clip's faded edge is none (the picture dissolves); its hard edges
  still are. An opaque full-frame upper clip still hides the cut under it.
- `Sources/SrtFlow/AIDeliveryCutJumps.swift`.

## Verification

- `checks/VideoInspection/DeliveryEdgeChecks.swift` (`SRTFLOW_INSPECTION_CASE=edges scripts/check-video-inspection.sh`): `pictureCuts`
  on values with V1 cutting at 3 s under a full-frame V2 from 2 to 4 s — opaque: cuts at 2 and 4 s; clear pixels: 3 s; half opacity:
  3 s; a V1 cut inside V2's fade-in or wipe-in: 3 and 4 s. The pair through the production preparation (`AIDeliverySound.prepare`,
  real render) and the cut_jumps rule as the registry runs it: under the opaque V2 nothing is reported at 3 s; under a transparent V2
  of the same size the 40 dB jump at 3 s is.
- Reverse: with the old upper-track filter and the old `top()` put back, the clear-pixel, half-opacity, fade and wipe cases and the
  transparent half of the pair fail (5 assertions); with the fix restored they pass.

## Lessons

- "Fills the frame" (geometry) is not "hides what is under it" (geometry, transparency, opacity, fades). Ask the question the rule
  needs; the coverage helper deliberately answers only the first.
- A picture rendered at the canvas size (a web motion, a transparent PNG) always fills the frame geometrically: judge it by its
  pixels' alpha (`sourceAlpha`), the one answer the preview and the export use too.
- The lasting rule is in [finished-video inspection](../architecture/finished-video-inspection.md), "Second-tier sound checks" →
  Rules.
