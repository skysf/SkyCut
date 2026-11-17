# 2026-11-17 Detached camera audio was treated as an added sound

## Symptom

While completing `listen voice=…`, camera audio moved to an audio track by Detach Audio was classified as `other` rather
than `clip_sound`. This would allow the new grey "may be loud" hint to suggest it was an added music, ambience or effects
layer, contrary to the approved exclusion of a clip's own sound.

The same review found that a known SkyCut voice-over on a masker track was counted as a second voice only if the caller
also selected that track in `voice`. It must still get `two_voices` when its provenance identifies it as voice-over.

## Root cause

`AIListenVoicePlan.Provenance.kind` checked both video-track placement and `isAudioOnly` to identify a camera recording.
`EditClip.detachedAudio` sets `isAudioOnly` but preserves the picture's `info`. Moving a recording between tracks does not
change where its sound came from; the old placement check discarded that evidence.

The report similarly used only the layer's selected-voice role to recognise overlapping voices, ignoring its known kind.

## Fix

Classify a picture or a clip retaining picture metadata as `clip_sound`, regardless of track. Remove the redundant
`onVideoTrack` argument. `Layer.isAddedSound` excludes that kind, voices and the combined `rest` layer before the report
asks the single pure `VoiceClarity.hint` rule. The report leaves the verdict and warning counts unchanged and separately
counts optional suggestions in `summary.may_be_loud`.
The overlapping-voice check accepts either a selected voice track or known voice-over provenance, at the existing speaking level.

The lasting provenance and hint contracts are in [the listening engine](../architecture/listening-engine.md), sections 2 and 7.

## Verification

`checks/MixLayers/VoiceHints.swift` constructs a picture, calls the real `detachedAudio`, builds a real voice plan with that
audio on A2, and requires `clip_sound` and no added-layer eligibility. The same group drives `AIListenVoiceReport` with
controlled ESTOI results to cover every hint boundary, excluded kinds, only the first masker and separate summary counts.
`checks/Listening/VoiceChecks.swift` covers the pure tiers and hint rule. All signals used for offline rendering are synthetic.

Reverse verification: dropping the ESTOI < 0.50 gate failed three pure checks (0.50, E36-like 0.553 and E39-like 0.637).
Removing the retained-metadata test failed both detached-audio assertions in mix-layers (201 checks, 2 failures).
Ignoring known voice-over provenance failed the new second-voice report assertion (203 checks, 1 failure).
Every change was restored. Final checks also run after merging the latest main.

## Lessons

Use retained source metadata to classify a recording. Track placement and audio-only playback are editing choices, not
provenance. A report-only suggestion still needs explicit exclusions and a regression through the production plan and report.
