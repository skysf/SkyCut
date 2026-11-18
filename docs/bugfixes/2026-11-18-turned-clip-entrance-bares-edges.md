# 2026-11-18 A turned clip that fills the frame bared its corners while it rose or popped in

## Symptom

Found through #454 (2026-11-17), which taught look to report `uncovered`. A clip turned 5° at scale 1.2 on a 16:9 frame fills it
(`fills_frame: true`, 5° needs about 1.152). Given entrance `rise`, its top corners were bare while it rose: at intensity 1, about 400
frame-edge pixels of a 640 × 360 preview frame at 0.3 s into a 2 s rise, still 70 at 0.8 s. Given `pop`, it sprang up from 0.65 of its
size and bared a ring of the frame (about 780 edge pixels at 0.3 s). Exits did the same in reverse. The preview, the export (its animated clips
are prerendered by the same builder) and look's frames all showed it, and look's `uncovered` listed the bare corners. #454's doc said so
on purpose: "a turned clip with rise or pop bares the frame during the motion".

Keyframed clips had the same blind spot from the other side: a clip placed small (scale 0.9) whose scale keys fill the frame
(1.2 → 1.3) got the picture-in-picture motion, and so did any clip turned by a static rotation, keys or not.

## Root cause

- The no-bare-edge growth (2026-09-18, product decision 4) lived in `ClipAnimator.state`: `scale = max(scale, 1 + 2·max|offset|)`, and
  only when `EditClip.placementCoversCanvas` said the clip covers the canvas. That test was the static, axis-aligned box
  (`resolvedPlacement`) and returned false for any turned clip, because "the growth cannot be one scalar" for a turned box.
- So a turned clip that fills got the picture-in-picture variant: a rise of 16 % of its height instead of 5 %, pop springing up from
  `1 − 0.35 × intensity` instead of coming down from `1 + 0.18 × intensity`, and no growth at all.
- Keyframes were not read: position, size and rotation keys (`animatedPlacement` / `animatedRotation`, which the builder draws) could
  make the static answer wrong both ways.
- #454 moved fills_frame and look's `uncovered` onto the rotation-aware geometry (`PictureCoverage`) but left the builder's test alone
  (it was another session's area), so look described the bare corners correctly while nothing prevented them.

## Fix

- `ClipMotionCover` (new, `Sources/SrtFlow/ClipMotionCover.swift`):
  - `coversCanvas(_:edge:canvas:)` — the full-frame variant applies when the clip's picture at rest covers the canvas on the clip's
    first frame (entrance) or last frame (exit): `ClipCoverage.picture` + `PictureCoverage.covers`, the geometry behind fills_frame
    (placement or default fit, crop, flips, rotation, keyframes). Per edge, so scale keys 0.8 → 1.2 enter small and leave full-frame.
  - `keepingCovered(_:rest:)` — the moving picture grows about its centre just enough to cover its own resting place at that moment
    (`PictureCoverage.growth(_:toCover:)`, new: the other picture's four turned corners in the moving picture's frame).
- Why "cover its resting place" and not "cover the canvas": for an unturned picture it is exactly the old rule (1 + 2·offset, and ≥ 1
  for pop's dip), so every unturned clip without keyframes renders as before, also those larger than the frame; a motion never shows
  more of what is below than the clip at rest does; and it needs no canvas tolerance of its own.
- Why the first / last frame: the entrance starts from the clip's first frame and the exit ends on its last; for unkeyed clips it is the
  same moment as any other, and a slow drift that bares the frame later still enters full-frame, as before.
- `EditClip.presetState` (the one place the builder and look's `uncovered` read the motion from): which edge plays
  (`ClipAnimator.edge`, shared with `ClipAnimator.state`) → the decision → the curve (`ClipAnimator.state`, now only the curve and the
  variant's amplitudes) → the growth. `placementCoversCanvas` is removed.
- Preview equals export by construction: the prerenderer builds the same composition, and its fill and matte carry the same placement,
  rotation and (remapped) keyframes, so both get the same decision and growth.
- Every check script that compiles `VideoEditClipAnimator.swift` now also lists `ClipMotionCover.swift`, `PictureCoverage.swift` and
  `ClipCoverage.swift` (22 scripts; `checks/check-script-source-lists.sh` green).
- Rule: [入场 / 出场动画](../architecture/clip-animation.md) "不露边"; [预览自由变换](../architecture/preview-free-transform.md)
  "Does the picture cover the frame" no longer says turned clips bare the frame during the motion.

## Verification

- `scripts/check-preview-composition.sh` → `checks/PreviewComposition/EntranceCover.swift`:
  unturned growth equals the old rule exactly (moved from `main.swift`); nine pictures that fill the frame (turned 5° at 1.2, −12° at 1.6
  off centre, flipped, a 9:16 picture filled across 16:9 and turned 3°, unturned off centre, turned with scale keys, turning keys,
  drifting keys, placed small with filling scale keys) × rise, pop, zoom × intensity 0.6 and 1, in and out, cover the canvas and their
  resting place at every 1/120 s frame of the motion; the variant follows the first / last frame (5° at 1.1, which does not fill, keeps
  the picture-in-picture rise and pop); real compositor frames of a turned rise, a turned pop and a turned clip with scale keys rising
  out keep every edge pixel covered (dark = below half the picture's brightness at that moment, since it fades), and the same probe sees
  the bare edges of a clip that does not fill.
- `scripts/check-clip-animation.sh` → `checks/ClipAnimation/TurnedEntrances.swift`: a turned rise on V1 and a turned pop on V2 (fill +
  matte) over black, real preview frames against the real export: every corner of the frame as bright as its centre in both, and the
  two pipelines agree.
- `scripts/check-mcp.sh` → `ClipCoverageChecks`: look's `uncovered` is empty while a turned clip that fills rises (it used to list its
  corners), and still reports a turned clip that does not fill.
- Reverse: the old decision (static box, turned = not covering) and the old growth put back in `ClipMotionCover` → 37 red in
  check-preview-composition (28 sweep cases: rise and pop on the seven turned or small-placed pictures; 3 variant checks; 6 real-frame
  checks: the turned rise at 0.3 / 0.5 / 0.8 s with 413 / 247 / 70 dark edge pixels, the turned pop at 0.3 s with 781, the keyed rise
  out at 3.6 / 3.8 s with 145 / 366), and 8 red in check-clip-animation (the turned rise's top right corner at 0.3 and 0.5 s and the
  turned V2 pop's top left and bottom right corners at 0.3 s, each in the preview and in the export). Green under the old code, as they
  should be: unturned growth, the unturned off-centre picture, zoom, and the picture turned only by small rotation keys (the old
  1 + 2·offset over-covers small turns).
  Restored → green. look's case in check-mcp was not rerun reversed: it is #454's assertion turned around, which was green on main
  with the old code.
- Not run: a real AI client calling look through SkyCut's MCP, and the editor by hand (manual list in the rule).

## Lessons

- When a fix moves one consumer (the AI's answers) onto a better geometry, the other consumer of the old test (the renderer) is the next
  bug; "look shows it" is a description, not a fix.
- A conservative "not covering" for a case the formula cannot handle is not conservative when it picks a different, bigger motion.
- Generalize a rule by its meaning, not its formula: "cover the resting place" reproduces 1 + 2·offset exactly where it held and extends
  to turned and keyframed pictures without a second rule.
