# 2026-11-18 Automatic voice selection can crash when it fills the layer budget

## Symptom

`listen voice=auto` on twelve independently audible SkyCut voice-over tracks plus music terminates the App with a negative
Array index trap. Eleven voice tracks plus music work. Explicit selection already refuses twelve voice tracks.

## Root cause

`AIListenVoicePlan.voiceTracks` checked the explicit selection's count but returned automatically found tracks without the
same check. Twelve voices consumed `maxLayers = 12`; `make` calculated zero remaining room and sliced the other tracks from
`room - 1`, or -1. A Swift Array trap cannot be caught as an ordinary tool error. More than twelve voices could also produce
an over-budget plan even without another audible track.

## Fix

Both selection paths use one count validator before returning voice indices. At most eleven distinct voices are accepted,
reserving a layer for other sounds or `rest`, including when no other track currently sounds. Excess voices return the same
existing `AIToolError` as explicit selection. The guide states this shared limit; nothing is silently dropped or merged as voice.

## Verification

- Reproduced with the production planner on main `8a16cccb` (the planner's blob was unchanged from `afc6355e`): eleven voices
  plus music returned twelve layers; twelve voices without music were incorrectly accepted; twelve voices plus music exited
  with signal 5 and `Fatal error: Negative Array index is out of range`. Only an isolated synthetic probe crashed.
- `checks/MixLayers/Voice.swift` exercises 11/12/13 voice tracks with zero/one/many other tracks through auto and explicit
  selection. Accepted plans partition the audible tracks exactly once and retain every voice clip's layer reference.
- Reverse verification temporarily restores the old auto branch and runs `scripts/check-mix-layers.sh`: the new boundary
  checks fail and the isolated checker traps at twelve voices plus another track; restore the fix afterward.
- `scripts/check-local.sh mix-layers` includes every scan guard and the existing rendered synthetic voice/masker checks.
  No real narration, cloud request, sound device or installed App is involved in the new boundary fixtures.

## Lessons

Automatic discovery must meet the same limits as explicit user input before downstream capacity arithmetic. Reserving room
is part of validating the selection, not a later array-index workaround. The lasting rule is in
[the listening engine](../architecture/listening-engine.md).
