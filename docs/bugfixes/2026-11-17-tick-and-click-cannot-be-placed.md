# 2026-11-17 The tick and click sound effects could not be placed, and failed calls left their files

## Symptom

The P5 walkthrough of SkyCut 0.18.66 ("SkyCut to-dos" item 2): `add_clips` with `sound_effect: {preset: tick}` failed with
`clips[0]: source_out must be 0.1 to 0.08; requested 0.08. No valid source window remains…`. `click` failed the same way with
`0.1 to 0.03741666666666667` by default, with `duration` 0.15 or 1 and with `size` 0.8: click ignored `duration`. `tick` with
`duration=0.1` failed with `0.1 to 0.09997916666666666`; 0.12 and 0.15 worked. The schema allows `duration` 0.05–10. The failed
calls still wrote their files: four `click-*.m4a` and two `tick-*.m4a` were left in `SkyCut/音效/`, against "a failed call changes
nothing".

Reproduced on main `97ca7431` with real App objects (`checks/ParameterLimits/AddClipsChecks.swift`): the same error for tick, and a
failing call left its new files.

## Root cause

- The timeline's shortest clip is 0.1 s (`TimelineTrim.clipMinimumDuration`, also the floor of every source window), but the
  synthesizer cuts each file to its sound: the tail is trimmed where it falls under -60 dB. tick's default is 0.08 s; click is a
  6 ms decay that falls under -60 dB after 37 ms whatever `duration` says; tick at 0.1 s lost its last sample to the trim
  (0.0999791 s). Every preset whose sound is shorter than 0.1 s, at any `duration` from the allowed 0.05, failed the same way.
- `add_clips` renders and writes the file before it checks the source window, and nothing removed the file when a later step (this
  check, another item, the commit) failed.

## Fix

- `SoundEffectSynth.render` → `fileSeconds`: a sound shorter than `max(duration, 0.1 s)` is padded with silence up to it, and far
  enough past its hit that `hit_at` at second 0 (the clip then starts at the hit) still leaves a whole clip. A sound that is long
  enough is untouched. So `duration` is the clip length for a short sound (click 0.15 → a 0.15 s clip) and no clip is under 0.1 s.
  The samples before the padding are the same: every one of 5,472 parameter combinations that rendered on main gives bit-identical
  samples now (only zeros appended), so nothing audible changed and no one needs to listen again.
- `SoundEffectSynth.version` 1 → 2: the file name hashes the version, so a short version-1 file a failed call left behind (same
  name otherwise) is not reused.
- `Sources/SrtFlow/AISoundEffectFiles.swift` (new): the call's ledger. `AISoundEffectTool.make` tells it which file it uses (before
  rendering) and which it wrote (it was not there before); when the call fails, `addClips` removes what it wrote, unless another
  running call uses the file or a clip in an open project points at it. A file that was there before is never removed.

Long-term rules: [synthesized sound effects](../architecture/sound-effect-synth.md) section 2 items 4–6.

## Verification

- Real App objects (`AddClipsChecks.shortPresets`, `failedCallFiles`): a version-1 click file (0.037 s) is planted where the old
  name points; tick, click, click `duration 0.15` (a 0.15 s clip), tick `duration 0.1` and tick `hit_at 0` are all placed. A call
  whose third item fails (`source_out` 99) leaves no new file, keeps a file that was already there and changes nothing.
- Pure (`checks/MCP/SoundEffectChecks.swift`, `fileLengthChecks`): every preset at its default, 0.05, 0.1 and 0.15 s is at least its
  duration and the shortest clip and passes `AIClipSourceWindow`; tick, click, pop, beep, shutter, glitch with `hit_at 0` are
  placeable; click 0.15 has silence after the click; `fileSeconds` keeps long sounds and tails.
- Reverse: on main the real-App scenarios were red. Without the padding 38 pure checks turned red; with `version` back at 1 the
  planted file was reused ("source_out must be 0.1 to 0.037395833333333336"); without the cleanup the failed call left its files.
  Restored and green.

## Lessons

- A generator whose output goes straight into a validated consumer must produce what the consumer accepts: the timeline's shortest
  clip is part of the synthesizer's contract.
- A tool that writes a file before validating must roll the file back when the call fails.
- When file names encode a content version, change the version whenever the content of any file changes, or the old file comes
  back under the same name.
