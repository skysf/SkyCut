# 2026-11-18 Pressing Play at the end of the timeline does nothing

## Symptom

B07 (2026-11-11, production feedback UI-2) saw the time ruler run on past the end of a 6.5 s project (23.3 / 6.5) after the
Play button had turned back to "Play"; its acceptance asks that playback stops at 6.5 and that **pressing Play or going back
to 0** both replay normally. On main the first half already held; the second did not: with the playhead at the end,
Play and the space bar did nothing, and only Return (go to start) got playback going again.

## Root cause

- The runaway ruler is the 2026-11-11 bug: when the picture reached its end nobody stopped the audio engine, which drives the
  playhead ([case](2026-11-11-preview-audio-engine-never-idles.md), PR #391, merged the afternoon B07 was written). Since then the
  audio clock ends playback itself on the timeline's total length (`PlayerClock.finishAtEnd`); `scripts/check-player-clock.sh`
  pins it. Nothing more to fix there.
- That fix's review found that starting playback at the end let the audio clock carry the playhead past the end again, and
  resolved it by making `play()` refuse to start at the end ("going back to the start is Return's job"). The Play button and
  the space bar call `togglePlayback`, which went straight to `play()`, so the user's Play at the end became a no-op.

## Fix

`PlayerClock.togglePlayback()` at the end now replays from the start: `goToStart()` (playhead to 0, hover peek ended, the timeline
scrolls back to the left) and then `play()`, which plays to the end and stops on the total length again — as other editors and
players do. `play()` itself still never starts at the end: a preview rebuild that resumes playback there must not jump to 0,
and smoke steps call it directly.

## Verification

- `scripts/check-player-clock.sh` (real `AVPlayer`, scripted audio clock): at the end of a 60 s timeline, Play while hovering
  elsewhere starts sound and picture from 0, ends the peek and asks the timeline to scroll left; on a 2 s timeline the replay
  stops on the total length again and stays there. The existing end checks (`play()` at the end does not start, eight natural
  ends in a row, a late end notice) still pass. Reverse verification: without the new branch 4 checks fail; restored, 88 pass.
- The ruler acceptance itself (stops at 6.5) is the existing `check-player-clock` end check, unchanged.

## Lessons

A guard against the wrong thing ("never start at the end") can take away the thing the user meant ("play it again"). Fix the
cause at the lowest layer (`play()` never starts at the end) and give the user's gesture its meaning one layer up. The rule is in
[audio engine](../architecture/audio-engine.md) section 2, item 11.
