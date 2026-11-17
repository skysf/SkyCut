# 2026-11-17 A short sparkle or shutter sound effect crashed SkyCut

## Symptom

Found while measuring the synthesizer's renders for MCP-8 (2026-11-17), not reported by a user yet: `add_clips` with
`sound_effect: {preset: sparkle, duration: 0.3}` (any `duration` under about 0.47 s) or `{preset: shutter, duration: 0.06}`
(under about 0.085 s) stops the process with `Fatal error: Range requires lowerBound <= upperBound`. The render runs inside the
App, so SkyCut quits. `duration` 0.05–10 is accepted for every preset.

Reproduced on main `97ca7431`: the real-App check process died with SIGTRAP on that call
(`checks/ParameterLimits/AddClipsChecks.swift`, `noTrap`).

## Root cause

- sparkle lays eight twinkles over 0.45 s whatever the duration; each is rendered with `for i in from..<n`, and a twinkle that
  starts after the end of a short sound has `from > n`, which traps in Swift.
- shutter's second click starts at about 85 ms: `from..<min(n, from + 2400)` traps when the sound is shorter than that.
- The preset checks only rendered each preset at its default duration, where neither can happen.

## Fix

`Sources/SrtFlow/SoundEffects/SoundEffectTonePresets.swift`: sparkle skips a twinkle that starts after the end
(`guard from < n else { continue }`, placed after that twinkle's random draws, so the random sequence of every sparkle that
rendered before is the same); shutter's range is `from..<max(from, min(n, …))`. Every one of 5,472 parameter combinations that
rendered on main gives bit-identical samples after the fix (scratch comparison of main's synthesizer with this one: 16 presets ×
durations 0.05–3 × pitch × size × brightness × three variations, the crashing ones left out on main).

## Verification

- `checks/MCP/SoundEffectChecks.swift` (`shortDurationChecks`, in `scripts/check-mcp.sh`): every preset renders at 0.05, 0.07 and
  0.3 s, plus sparkle at 0.45 / 0.46 and shutter at 0.06 / 0.08 / 0.09 s. A sweep of all 16 presets over 6,336 parameter
  combinations (durations 0.05–10, pitch 0.25–4, size and brightness 0 and 1, three variations) rendered without a trap.
- Real App objects (`AddClipsChecks.noTrap`): sparkle 0.3 s and shutter 0.06 s are placed.
- Reverse: without the sparkle guard, and separately without the shutter one, the `check-mcp` self-test process trapped (exit 133).
  Restored and green.

## Lessons

- The range a tool accepts is the range its checks must render: test the edges of every accepted parameter, not the defaults.
- A loop over a computed start (`from..<n`) must handle a start past the end; in Swift that is a crash, not an empty loop.
