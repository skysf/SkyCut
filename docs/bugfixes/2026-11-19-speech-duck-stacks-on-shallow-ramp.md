# 2026-11-19 A clip only the shallow start of a duck's ramp reaches stacks another dip on every call

## Symptom

Found in review CXR2 (finding R9, on #475's `set_track duck_others_db`). Speech at 2.0–2.5 s, music at 0 dB ending at
1.70 s. The dip under the line starts at 1.60 s, so the music only reaches the first quarter of the attack ramp. Calling
`duck_others_db` −10, −10, 0 left the music's end at −2.5, −5.0, −5.0 dB: the second call dipped it again, and 0 did not
take the dip out. Each changing call also left one more undo step. The same happened to a clip starting in the shallow end
of the release (less than half way down).

## Root cause

`SpeechDuckCurve.existingDip` measures the dip already drawn, so that calling again sets the dip instead of stacking it.
Under the hold it reads the deepest point under the edge line. When only a ramp reaches the clip it read only the ramp
points at least half way down (`fraction >= 0.5`), dividing by `max(fraction, 0.5)`. A clip whose edge stops before the
ramp is half way down has no such point, so the measured dip was always 0: every call drew the full depth again, and depth
0 moved nothing. The existing checks covered windows crossing the clip's start and end, but always with the clip edge more
than half way down the ramp (the hold or a 0.75 fraction), so the gap never showed.

## Fix

`existingDip` now reads a ramp-only clip on the deeper half of the ramp the clip covers (points at least half as far down
as the deepest point it reaches), each divided by how far down the ramp is there. The dip is drawn with keys at the
window's corners and the curve is dB-linear between keys, so a duck drawn there is exactly that share of its depth at every
point, however shallow. Reading the deeper half (not one point) keeps the rule that a bump above the dip's floor never reads
as the dip. A window reaching less than 1 ms into a clip (`SpeechDuckCurve.minimumReach`) now leaves it alone: its two corner
keys would merge into one (keys closer than 0.5 ms are one key), so the dip could neither be drawn exactly nor read back, and
it would be under 0.1 dB. Files: `Sources/SrtFlow/SpeechDuckCurve.swift`.

## Verification

- `scripts/check-mcp.sh` (`checks/MCP/SpeechDuckChecks.swift`, `duckShallowRampChecks`): a bed ending a quarter and 2 ms
  into the attack and one starting 0.4 of the way down the release each dip by that share of −10 dB; the same depth again
  changes nothing, −20 sets the dip instead of adding to it, and 0 brings the line back to 0 dB at the edge and through the ramp; a window
  reaching 0.3 ms in leaves the clip untouched.
- `scripts/check-parameter-limits.sh` (`checks/ParameterLimits/SpeechDuckAppChecks.swift`): real App objects with a sting
  ending in the first line's attack — calling again changes nothing and leaves no undo step, 0 takes every dip out in one
  step, undo takes each changing call back in one step.
- Reverse verification: with the old `existingDip` and `touching` filter restored, `SpeechDuckChecks` goes red (same depth
  stacks, −20 adds to the stacked dip, 0 leaves it, the 0.3 ms sliver is touched) and the App check goes red (the second call
  changes the sting); with the fix restored both are green.

## Lessons

- "Measure what is there, then set it" only works if the measurement covers every case the drawing covers: the drawing
  reached clips the measurement skipped. When a reader filters its input (here: only ramp points half way down), check that
  everything the writer can produce still has something to read.
- The rule lives in [audio-volume-curve.md](../architecture/audio-volume-curve.md) section 5, rule 5.
