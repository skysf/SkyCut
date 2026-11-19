# 2026-11-19 A voice-band cut set back to 0 while playing kept filtering, so the preview no longer matched the export

## Symptom

Found in review CXR2 (finding R10, on #479's `edit_clip voice_band_db`). Play two layers of related sound (the same tone, or
a shot's sound on two tracks), give one clip a voice-band cut, then set it back to 0 while it keeps playing. The level of each
layer alone stays flat, but the sum in the preview is no longer the sum in the export: with two identical 300 Hz tones the
live mix sat at −28 dBFS (the review measured −34) against the export's −11 (−17), about 17 dB apart, until the next seek or
restart. Turning a cut on mid-stream also jumped by about half the signal (a click).

## Root cause

`VoiceBandRendering` kept the filter running once a stream had needed it, "even back at gain 1": at g = 1 the three bands sum
to an all-pass, flat in level, so this was meant to avoid a phase jump when switching it off. But an all-pass is not the dry
sound: at the 300 Hz crossover its phase is about −180°, so a layer still filtered cancels against a related layer that is
not. The export builds a new engine, and a stream whose cut is 0 there never starts the filter: it plays the raw samples. So
the same settings gave different samples live and in the export. The checks only measured an engine built (or updated with
`updateGains` before rendering) with the cut on, never a cut changed between blocks of one continuous render, and never two
related layers. Starting mid-stream had a sibling problem: the filter started from rest at full weight, and its first output
is about half the input, so the stream jumped.

## Fix

`VoiceBandRendering` now fades between the filter and the dry sound when the cut starts or stops mid-stream, over
`fadeFrames` (1,024 frames, about 21 ms): a cut that starts fades in from the dry sound; a cut set back to 0 fades out to the
dry sound and then stops and resets the filter. After a jump (seek, start) it starts settled, as before and as the export
does. The crossfade is a second `VoiceBandFilter.process` that mixes the dry input in per frame (`dry` share moving toward 0
or 1); the settled path is the old one, so the export's samples are unchanged. Files:
`Sources/SrtFlow/AudioEngine/VoiceBandFilter.swift`.

## Verification

- `scripts/check-audio-engine.sh` group 16b (`checks/AudioEngine/VoiceBandLive.swift`): two in-phase layers of a 300 Hz tone
  rendered through the engine in continuous 4,096-frame blocks, A1's cut set to −10 after 1 s and back to 0 after 2 s with
  `updateGains`. The cut is heard at once; once faded out the live mix equals a fresh render of both layers at 0 dB sample for
  sample; no sample-to-sample step around either change is larger than 1.5 times the tone's own.
- Reverse verification: with the old `VoiceBandRendering`, group 16b has 2 red — back at 0 the live mix is −28.07 dBFS
  against the export's −10.97 (worst sample off by 0.40), and starting the cut mid-stream steps by 0.119 against the tone's
  0.016. With the fix all 326 engine checks pass; the existing group 16 (steady cut, `updateGains` before rendering) is
  unchanged.

## Lessons

- "Flat in level" is not "the same sound": anything that can sum with a related signal (a duplicate layer, the same shot's
  sound on two tracks) hears phase. Preview and export must reach the same samples for the same settings, not just the same
  level.
- A setting that can change mid-stream needs a check that changes it between blocks of one continuous render; a fresh render
  with the new value proves nothing about the transition.
- The rule lives in [sound-scenes.md](../architecture/sound-scenes.md) section 5, rule 3.
