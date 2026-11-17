# 2026-11-17 Sound effects added with new_audio landed on the voice and music tracks

## Symptom

A team cutting the South Pole trailer (B, 2026-11-13, feedback MCP-2) put 13 sound effects made on this Mac on the timeline
with one `add_clips`, every item `track=new_audio`. The new track was A5, but the riser and the impact, which overlapped the
effect before them, landed on A2 (music) and A1 (voice). Nothing said so: only each item's `track` field showed it, and the team
noticed while reading the reply and moved them with `edit_clip track`. Per-track volume, curves and the mix go wrong when effects
sit on the voice track.

Two related reports made it likely to happen:

- MCP-8: a made effect's clip is longer than the `duration` asked for (impact `duration 1` is a 2.7 s clip; `listen` hears
  silence after about a second). Effects planned back to back by `duration` overlap.
- MCP-4: naming an audio track that did not exist yet (`A2` with only A1, `A3`…) failed the whole call ("There is no track A2;
  the audio tracks are A1…A1"), and one call could create only one new audio track. The teams split their sound plans into one
  call per track (6–7 undo steps) and used `new_audio`, which is how they hit the first problem.

Reproduced on main `97ca7431` with real App objects (`checks/ParameterLimits/AddClipsChecks.swift`): voice on A1 0–3 s,
music on A2 10–20 s, 13 `new_audio` effects with `hit_at` 4.2–6.8 s: 6 of the 13 landed on A1 or A2; two clips named `A2`, one
where A2 was taken: it landed on A1; one call naming A1–A7: "There is no track A2".

## Root cause

`add_clips` placed clips with the drop rule (`mediaImportLandings`, the same function as dragging files onto the timeline). For
audio that rule is: the track you pointed at if the clip fits there, otherwise the first track from A1 that fits, otherwise a new
one at the bottom. That is right for a mouse drop: the user sees where it went. For an AI that named a track (or asked for a new
one) the fallback sends the clip to whichever track has a gap at that moment, which in a mixed project is the voice or the music.
`new_audio` clips of one call share the track the first one opened, so an effect overlapping the previous one there fell back to
A1 / A2. The reply did not compare the track asked for with the track used, so the move was silent.

The track names were read by `AITrackName.target`, which only knows the existing tracks and "one past the last" (a new track),
so `A3` with only A1 was an error.

The clips run past `duration` by design: a made sound keeps the preset's tail (reverb, decay), which the user approved when the
presets were made ([sound-effect-synth.md](../architecture/sound-effect-synth.md) section 2 items 2 and 5). Trimming it to
`duration` would change the sounds (an impact is still at -30 dBFS 1.27 s after its hit), so the clip stays as long as the
sound and the reply now says how long it is heard.

## Fix

- `Sources/SrtFlow/AITrackLanding.swift` (new, pure values): an audio clip that names a track (`A<n>`, `new_audio`) goes on it
  when that track has room at that time; otherwise on another new track (one chain per asked-for track, shared by later clips that
  do not fit either), never on a track that already had content. A hidden named track is treated the same way. A-numbers past
  the last audio track are created in the same call, right after the existing tracks in number order and without gaps
  (`A5` with no audio tracks becomes A1). Audio that names no track still takes the first free track, as a dropped file does.
  Video keeps the drop rule (a taken spot lifts the clip a track up: stacking order).
- `AITimelineEdits.place` sends named audio through it and returns a note for every clip that is not on the track it asked for
  (video lifts included). `AITimelineTools.addClips` turns each note into a `track` entry in that item's `adjustments`
  (`requested`, `applied`, `reason` = `track_busy` / `track_hidden` / `tracks_numbered_without_gaps`, `overlaps` = the clip in
  the way, `wanted_track` for new_audio). Still one `perform`, one undo step.
- add_voiceover's lines take the same path (its `track` names an existing track or a new one): a line on a taken spot opens a new
  track instead of going to the first free one.
- MCP-8: the reply of a made sound carries `audible_duration` (`AISoundEffectRequest.audibleEnd`): how long it is heard at its
  volume, by `listen`'s rule (43 ms windows, -45 dB silence floor). Impact `duration 1` at -8 dB: heard for 1.2 s of its 2.7 s
  clip. The guide (`add_clips` topic) says the clip runs past `duration` by the tail and where to read both.

Long-term rule: [AI interface (MCP)](../architecture/ai-control-mcp.md) section 4 item 2.

## Verification

- Real App objects, `scripts/check-parameter-limits.sh` (`AddClipsChecks`): the 13 `new_audio` effects all land on new tracks,
  none on A1 / A2, every one not on the call's first new track has a `track_busy` adjustment, one undo restores the project; a
  clip on a taken spot of A2 goes to A3 with `overlaps`; one call fills A1–A7 (seven tracks, every clip where it asked, one undo
  removes all seven); `A5` alone becomes A1 with `tracks_numbered_without_gaps`; impact `duration 1` reports `audible_duration`.
- Pure: `checks/MCP/TrackLandingChecks.swift` (`scripts/check-mcp.sh`): the same rules on `TimelineState`, plus hidden tracks,
  numbers given out of order, `new_audio` next to numbered tracks, a clip naming no track, video lifts and their notes.
- Reverse: the real-App scenarios on unmodified main were red (above). With main's `place` body put back into this tree,
  `TrackLandingChecks` turned red in 15 places (8 clips on A1/A2, no notes, one track instead of seven…); restored and green.

## Lessons

- A fallback that "puts it somewhere that fits" is right where the user sees the result (a mouse drop) and wrong where the caller
  named the place and does not look (an AI). When a named request cannot be honoured, do the least surprising thing and say what
  happened in the reply.
- A reply that reports requested and applied values must cover every field the request names; a field that is silently replaced
  (here `track`) is exactly where the caller stops trusting the result.
