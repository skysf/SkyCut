# 2026-11-19 An over-long web-motion duration quit SkyCut before it could be refused

## Symptom

`set_motion` with a finite but far too long duration — `duration: 1e20` (an AI's typo or unit mix-up), the same value in
the reserved `parameters.duration`, or `"1e300"` written as text — quit SkyCut with
`Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max` instead of
answering "The duration must be more than 0 and at most 60 seconds." No AI was needed either: a project file whose stored
web-motion record had such a duration (or a frame rate whose frame count overflows, e.g. `Int.max` fps over 3 s) quit
SkyCut as soon as it was opened with its movie missing, because cache recovery validates the record. Editing that clip's
parameters, reusing it as a template and the inspector's Re-render did the same. The helper `skycut-web-motion`, handed
such a request, crashed on a signal instead of refusing it, so SkyCut could only say "stopped by the system".
Found by review CXR2 (R6).

## Root cause

`WebMotionRequest.frameCount(duration:fps:)` multiplied first and converted `round(duration × fps)` to `Int`, guarding only
against a non-finite or non-positive duration and fps ≤ 0. A finite product of 2^63 or more traps in Swift. The request's
initializer computes it for its default time limits (`WebMotionLimits.standard(frames:)`), and `problems()` computed it for
"shorter than one frame" with only the frame-rate range in front of it, not the 60 s cap. So the trap fired inside the
validation that exists to refuse the value: `WebMotionValidation.validate` (the AI call, template reuse, the inspector,
recovery — every `WebMotionCache.render`) and the helper's own `main.swift`. The AI argument reader only checks that a
number is finite, by design (each tool owns its ranges); the record decoder keeps stored values as they are.
The shared type had this conversion since the renderer was built; #460 connected it to `set_motion` and to project records.

## Fix

- `WebMotionRequest.frameCount` turns only a duration and frame rate inside the caps into frames (`timingWithinCaps`:
  0 < duration ≤ 60 s and 1–120 fps, so at most 7,200 frames) and is 0 otherwise. `problems()` says "shorter than one
  frame" only for timing inside the caps; values outside get the duration / frame-rate sentences. SkyCut and the helper
  still share this one validation (`Sources/SrtFlowWebMotionKit/WebMotionRequest.swift`).
- The inspector's own check speaks only for its length field: a stored frame rate outside the caps goes on to the shared
  validation, which names it, instead of being blamed on the length (`WebMotionEditorModel.render`).
- Cache recovery's notice goes through `WebMotionUIError.message`; it printed `AIToolError(message: …)`
  (`WebMotionRecovery`).

## Verification

- `scripts/check-web-motion.sh`, pure group (`PureChecks.oversizedTiming`): 10^20 s, the largest finite duration,
  `Int.max` fps and a huge negative duration make no frame count, get the plain sentence and keep an empty render's default
  limits; inside the caps the count is unchanged (7,200 at 60 s × 120 fps, 12 for 0.51 s at 24 fps).
  Hostile group (`HostileChecks.oversizedRequest`): the real helper, sent a 10^20 s request that only it sees, exits
  `invalidRequest` (2) with the sentence and writes no movie.
- `scripts/check-motion-placement.sh`, core group (`DurationBounds.swift`): set_motion's top-level duration,
  `parameters.duration`, a new page in full-access mode and a duration written as text are refused in plain words. A
  project file holding a 10^20 s record and an `Int.max`-fps record, movies missing, opened through
  `OpenProjects.open`: recovery ends with a plain notice; set_motion parameter edits, AI template reuse, the inspector's
  Re-render and the card add all refuse in plain words. No motion job, no renderer start (a marker helper), no edit and no
  undo step anywhere.
- Reverse verification, the three source files restored to main: the pure group trapped at its first case
  (`Trace/BPT trap: 5`); the helper exited on signal 5 (`signaled true`), 1 of 13 hostile checks red; the placement core
  group trapped at the first set_motion call (exit −5), and, with the AI calls skipped, again while opening the damaged
  project (recovery). Fix restored: pure + hostile 63/63, placement core 220/220 and official 167/167.

## Lessons

- In validation code, a conversion that can trap belongs after the range check, never inside it. "Finite" is not "in
  range": 10^20 is a finite Double.
- A value read back from a project file is input like an AI argument: opening a file must not crash on it, and the same
  validation has to cover every path that reads it (recovery, edits, template reuse, the inspector).

The rule is in [web-motion renderer §5](../architecture/web-motion-renderer.md).
