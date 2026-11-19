# 2026-11-19 listen cuts=true reports music, effect and noise-floor cuts as "on speech"

## Symptom

Production feedback MCP-14, group A (2026-11-13): `listen cuts=true` reported three V1 cuts (13.0, 15.75, 16.5 s) as `on_speech`
with suggested trims; there was only the car cabin's noise floor at those moments (`listen file=` measured the line at 16.72–17.87 s,
whole inside the clip). The AI either trimmed good cuts or had to rule each report out by hand. inspect_video had the same fault and
was fixed on 2026-11-16 ([case](2026-11-16-inspection-reports-sound-onsets-as-speech.md)); that case left listen cuts=true out.

## Root cause

`listen cuts=true` turned the level reading straight into the verdict: `AICutCheck.side` says `onSpeech` wherever the cut sits on
sound with no pause within reach, and a transcript only named the word. Music, a sound effect's attack, ambience and a steady noise
floor are all "sound with no pause", so without a transcript every such cut was a cut on speech, and a file's own first second
(nothing cut off) too. The 2026-11-16 fix had moved inspect_video to speech evidence (`AIInspectionSpeech`) but left the shared level
step alone because listen cuts used it, so the two tools disagreed about the same cut.

## Fix

- `AICutCheck.speechJudged` (pure): a side the levels put on speech is judged on the evidence inspect_video uses
  (`AIInspectionSpeech`): the file's own first or last second → `file_edge`; a word in the sound clip's cached transcript, or a line
  of narration subtitles, at that source second → `on_speech` (naming it); a transcript without a word there → `on_sound`; no
  evidence → `on_sound` and the clip in `speech_unchecked`. Only `on_speech` keeps the suggested source_in / source_out.
- `AIListenCuts` reads each sound clip's cached transcript once (one call site), keeps the waveform reading as it was, and passes
  every side through `speechJudged`; the result counts `on_speech` and `on_sound` apart and lists `speech_unchecked`.
- `AIInspectionSpeech.isFileEdge` gained a source-time form: listen cuts asks it on the sound a V1 cut is heard from, which may be a
  linked clip whose own edges sit elsewhere.
- The listen guide's `cuts` section and [AI interface](../architecture/ai-control-mcp.md) (the cuts=true paragraph) say so.

## Verification

- `scripts/check-mcp.sh` → `checks/MCP/CutCheckChecks.swift` (`checkCutSpeechEvidence`): the "When I got" sample on sound alone is
  `on_sound` and unchecked with no suggestion; a transcript word there makes it `on_speech` naming the word with the same suggestion;
  a transcript without a word there `on_sound`; a narration line `on_speech`; subtitles heard only elsewhere unchecked; a head at the
  file's first second and a tail at its last `file_edge`; a pause passes through; the JSON statuses and the two counts.
- `checks/MCP/listen-wiring.sh` pins the wiring: every side goes through `AICutCheck.speechJudged`, the evidence is
  `AIInspectionSpeech`'s, and clips without it are listed.
- Reverse: with `speechJudged` passing every side through unchanged (the levels alone deciding), 12 assertions failed; with
  `AIListenCuts` calling `AICutCheck.side` directly, the wiring guard failed. Both restored, both green.
- Not run: the South Pole projects (the human project stays closed by rule); group A's acceptance ("only cuts that really cut a word")
  waits for the next real run.

## Lessons

- One judgement, one rule: when a fix moves one tool to better evidence, the other tool sharing the old step must move with it, or
  the two disagree on the same cut. The rule lives in [finished-video inspection](../architecture/finished-video-inspection.md),
  "范围与证据".
- A level says "sound", never "speech": a semantic verdict needs semantic evidence, and "can't tell" is a status of its own.
