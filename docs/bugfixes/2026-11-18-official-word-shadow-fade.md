# 2026-11-18 Official collision title does not fade with its duration

## Symptom

The new collision template passed the six renderer checks, but its duration-only pixel check
failed. A four-second render and a shortened three-second render had identical pixels at all
12 common four-fps samples, including 2.75 seconds when the shorter page should be fading.
The initial App-linked check exited 1 on this assertion; a shorter-duration rerun also failed.

## Root cause

The request and JavaScript values were correct: at 2.75 seconds with duration 3, both the computed
fade and `ctx.globalAlpha` were 0.9259259259259264. In this capture environment the shadowed
Canvas text pixels still held. Removing only the shadow, or applying the envelope to the canvas
element's CSS opacity, produced the expected changed pixels. The WebKit-internal mechanism was
not isolated beyond this observed shadowed-text path.

The six page checks establish rendering safety, completeness and replay consistency; they do
not establish that an editable parameter has its intended visual effect. The added parameter
check supplied that missing observation.

## Fix

The page applies its final fade envelope to its own canvas element's opacity. Text, particles
and flash are still drawn from time, with their intrinsic decay, without applying the final
envelope twice. This changes only the transparent overlay's pixels; the underlying picture
does not move or dim. The preview movie and its source/defaults receipt were regenerated.

## Verification

- Restoring the old HTML reproduced identical common-prefix hashes for the 4 s and 3 s renders,
  the condition that made the real parameter assertion fail. The exact fixed HTML was restored
  in `finally`; the same comparison then changed frame 11 (2.75 s) as expected.
- Two independent fixed renders passed all six checks and matched all 96 hashes. A four-fps
  control matched the 24-fps render's same-time frames; the shortened version and portrait
  render also passed all six checks.
- Evidence: `/tmp/g26-word-debug/summary.txt` and the requests, results and logs in that directory;
  full failing App-linked runs: `/tmp/g26-c-check-local.log` and `/tmp/g26-c-check-local-final.log`.
- The final App-linked suite passes all 352 assertions, including independent duration, word,
  font, color and hit changes for every design: `/tmp/g26-c-origin-restored.log`.

## Lessons

Test an editable template's visual response, alongside its parameter values and duration.
Compare pixels at common times so a different frame count cannot manufacture a pass. An
extended hold may legitimately preserve earlier frames; a shortened fade is the useful control.
The permanent constraint is in [renderer determinism](../architecture/web-motion-renderer.md#10-versions-and-determinism).
