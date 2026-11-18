# 2026-11-18 Official ice page fails frame replay

## Symptom

During PR C preview generation, the new ice-crack page failed the helper's `same_twice` check at
1.125 seconds: the same frame differed between page instances after other frames had been drawn.
The request used the default four seconds, 320 by 180 pixels, 24 fps and three page instances.
The other two official designs passed. No rejected ice movie was accepted as a bundled preview.

## Root cause

The Canvas implementation did not satisfy the page contract's pixel-stable frame replay, despite
balanced save/restore calls. Resetting its backing width before each frame was insufficient:
the next run still failed replay, at 0.583 seconds. The exact contribution of font readiness,
clipping, shadows or WebKit raster caching was not isolated; there is no evidence for a general
Canvas or WebKit defect. The concrete defect was this page implementation's replay instability.

## Fix

The ice design now uses SVG with its text and font specified at load. Each frame derives the
seam, opening clip, light and text opacity from its own time and overwrites the corresponding
attributes. It uses the same locked helper, clock, alpha path and exact pixel comparison.
The box and collision pages retain their independently verified Canvas implementations.

## Verification

- Two independent SVG renders passed all six checks and produced identical hashes for all
  96 frames. A further restored render matched the accepted preview's same 96 hashes.
- Reverse verification temporarily restored the rejected Canvas source to the real source path.
  The first attempt exited 1 with `same_twice` at 1.125 seconds. The exact SVG source was restored
  in `finally`, then the helper passed all six checks again.
- Logs: `/tmp/g26-c-previews/ice-crack-light-svg-1.log`, `ice-crack-light-svg-2.log`,
  `ice-reverse-1.log` and `ice-restored.log` in the same directory.
- The App-linked official-template checks render every shipped page fully twice and compare all
  frame hashes; bundled receipts also bind the accepted preview to its source and defaults.

## Lessons

A first pass through a page is insufficient evidence of a reusable template. Keep exact replay
checks on every design, including a second page instance after unrelated frames. A speculative
state reset is not a fix until the failing replay is rerun. The permanent contract is in
[renderer determinism](../architecture/web-motion-renderer.md#10-versions-and-determinism).
