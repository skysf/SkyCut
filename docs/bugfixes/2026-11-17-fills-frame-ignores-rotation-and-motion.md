# 2026-11-17 fills_frame said a turned or moving picture fills the frame, and look never said where it was bare

## Symptom

Found walking the film-craft knowledge cards in SkyCut 0.18.66 (P5 walkthrough, "SkyCut to-dos" item 3).
`edit_clips … rotation:5, scale:1.1` on a 16:9 clip in a 16:9 canvas replied `picture.fills_frame: true`, but `look` showed the
top-right corner bare (a 5° turn needs about scale 1.15). A keyframed drift (x 0.5 → 0.53 at scale 1) showed a black strip along the
left edge in `look`, and neither `get_timeline` nor `look` said anything. The AI trusts `fills_frame`, so it ships black corners.

## Root cause

- `AIFrameFit.describe` decided `fills_frame` from the static box alone: `frame.minX <= 0.5 && … maxY >= height − 0.5` on
  `resolvedPlacement`, the box **before** its rotation and **without** keyframes. Its own comment said "rotation is not counted".
  Position / size / rotation keyframes (`animatedPlacement`, `animatedRotation`), which the preview and the export draw, were never
  read, and nothing looked at the clip's time on screen.
- look's frame text had brightness and `black_bars`, both measured from pixels (letterbox bars inside the footage). A black corner left
  by framing and dark footage look the same in pixels, so nothing could report the first without misreporting the second.
- The render path has two more "covers the canvas" tests (`coversCanvasOpaquely` for the dissolve path, `placementCoversCanvas` for the
  entrance / exit no-bare-edge compensation); both deliberately count any turned clip as not covering. They were never what the AI read.
- Reproduced on main (26cb133d): with `ClipCoverage.fill` put back to the old static box, the new checks say the walkthrough's turn
  "fills" (15 checks red); the real preview frame of a 640×360 clip turned 5° at 1.1 shows bare top-right and bottom-left corners of
  about 100 × 9 px (`scripts/check-preview-composition.sh`, `RotatedPictures.swift`).

## Fix

- `PictureCoverage` (new, pure): a picture is its box turned clockwise about the box's centre — the order both pipelines draw it in.
  `fillFactor` (how much it must grow about its centre to cover the canvas, from the four corner pixels' centres) and `gaps` (bare
  edges and corners along the canvas edges, in pixels).
- `ClipCoverage` (new): a clip's picture at a moment (placement or default fit, keyframes, and on request that moment's entrance / exit
  motion), `fill` over its time on screen (a 1/120 s grid holds every frame of 24, 30 and 60 fps; one test when the box does not move),
  and the pictures on screen at a moment (`onScreen`, which look's `on_screen` now uses too).
- `AIFrameFit.describe` takes `fillsFrame` from `ClipCoverage.fill`; `AITimelineSummary.picture` writes `fills_frame`, and when false
  `fill_scale` and (only part of the time) `fills_except` (`AIPictureCoverage.fields`); set_keyframes returns `picture`; look adds
  `uncovered` to every timeline frame (`AIPictureCoverage.uncovered`).
- `fill_scale` is measured to the canvas's own corners, not the corner pixels' centres: the preview compositor draws edges up to about a
  third of a pixel off the geometry, and at the pixel-centre value two corner pixels of a real frame stayed dark.
- MCP wording only in the guide (the catalog has under 1 KB left): look `timeline_and_files`, edit_clip `placement`, set_keyframes
  `interactions`, get_timeline `contents`. Rule: [预览自由变换](../architecture/preview-free-transform.md) "Does the picture cover the frame".

## Verification

- `scripts/check-mcp.sh`: `PictureCoverageChecks` holds the geometry against an independent bitmap (each pixel centre taken back
  through CoreGraphics's own inverse transform) over 1,092 turns, sizes and offsets, plus the smallest growth, gaps between pictures and
  a half wipe; `ClipCoverageChecks` covers the walkthrough's turn (`fill_scale` 1.152) and drift (`fills_except` 0.025–2 s,
  `fill_scale` 1.06, look `left` 57 px), flips, a crop, rotation keys, a spring dipping below its keys, the sampling grid and look's
  `uncovered` with V2, hidden clips and tracks, transparency, a gap, wipes, a transition and rise.
  Reverse: `ClipCoverage.fill` back to the old static box → 15 red; restored → green.
- `checks/MCP/coverage-wiring.sh` (in check-mcp): look writes `uncovered`, `on_screen` and `uncovered` share `ClipCoverage.onScreen`,
  picture and describe read `ClipCoverage`, set_keyframes returns `picture`, no AI file tests coverage itself.
  Reverse: removing look's `uncovered` line → red; restored → green.
- `scripts/check-preview-composition.sh` (`RotatedPictures.swift`): real compositor frames — turned, turned and flipped, drifting,
  turning — show dark runs where the geometry predicts (within 2 px, plus antialiasing along a shallow edge), and at `fill_scale` the
  edges are covered while 0.02 less shows the corners. Reverse: the turn's direction flipped in `PictureCoverage` → 10 red (the
  corners swap); restored → green.
- Not run: a real AI client calling look through SkyCut's MCP (no SkyCut app in this task); the field is built by the same function the
  checks call and wired in by the scanned line.

## Lessons

- "Does it cover" has to use the geometry the renderer uses, at every moment the clip is on screen — not the box at rest.
- Give the AI the fix with the verdict: when and how much (`fills_except`, `fill_scale`), not just a boolean.
- Coverage from pixels cannot tell framing from dark footage; compute it from the clips and say so.
- A CoreGraphics aliased fill is no pixel-centre reference: it also fills pixels a box edge only clips (6 px off along a 5° edge).
  Hold geometry against your own pixel-centre sampling, and hold it against real rendered frames separately.
