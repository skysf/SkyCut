# 2026-11-20 After the idle stop, Play started the picture ahead of the sound, and starts lost their first sound

## Symptom

E2's open item 1 (2026-11-19): after the audio engine's two-minute idle stop, Play as the first input starts the picture
at once while the sound waits for the output device. On the M1 (MacBookPro17,1, macOS 26.5.2, built-in speakers) the
playback-start bench reproduced it with a 20 s stop (`SRTFLOW_PLAYBACK_START_IDLE_SECONDS=20`, 8 idle starts in one
launch, main's code at 685c5d80, load 4–10):

- in 3 of 8 starts the picture ran ahead and the drift correction then re-seeked it: start skew −97 / −79 / −42 ms,
  the picture frozen for 133 / 117 / 67 ms in its first two seconds;
- in 2 of 8 starts the sound lost its first 109 / 47 ms (11,718 / 12,834 frames of engine underrun, 6 tracks);
- every start lost its first quantum (3,348 frames, 11.6 ms per track): the first sound came one quantum after Play's
  position.

With the bench's usual 2 s stop the same code was in step in 23 of 24 starts and lost 93 ms of sound once, so the gate's
idle scenario rarely showed it; E2 had skipped it in the M1's strict profile.

## Root cause

1. **Picture and sound started in the same main-thread turn as the device start.** `PlayerClock.play()` started the
   output synchronously (`recoverIfNeeded`), then at once `playImmediately` and the engine from the playhead. The
   engine's anchor is pinned to the device's next quantum, but a device start slows every thread of the process for a
   while: instrumented launches showed `playImmediately` taking 11–111 ms right after the device start in 3 of 8 cold
   starts (the picture's timebase already 10–37 ms along when it returned), and the device's first quanta coming late.
   The picture's clock started at once; the sound's first sample reached the output 50–170 ms later. The drift
   correction then put the picture back with `setRate(_:time:atHostTime:)`, a native seek, which froze it on the 8 s
   GOP ([picture re-seeked under running sound](2026-11-20-picture-reseeked-under-running-sound.md)).
2. **A paused seek left the ring empty.** `AudioRing` is single-writer / single-reader: after a seek the writer marks a
   new round and the reader moves to it on its next render. Paused, the render block returned before touching the
   ring, so the writer's free space still counted the old round's frames: a ring that was full when the seek came took
   no new data until the first playing render. Every Play after a paused seek (every positioned start) began with one
   silent quantum per track, and when the feeder thread itself ran late after a device start the sound lost 50–140 ms.

E2 had tried starting both on the device's first rendered quantum (`setRate(_:time:atHostTime:)` with that quantum's
host time). It looked right on the picture's numbers but lost 58–139 ms of sound in 6 of 24 starts. Two reasons, found
here: cause 2 above, and a probe (2026-11-20, 1080p picture-only clip, 8 s GOP) showing that `setRate(_:time:
atHostTime:)` re-seeks for any host time but the present: a start 100 ms in the future froze the picture 354 ms, one
100 ms in the past 171 ms, and even `.invalid` time at "now" 418 ms. Following the sound's first render from the main
thread instead (start the sound, start the picture when its first quantum has rendered) failed too: 5 of 8 starts out of
step by 82–114 ms either way, because the main thread itself is late after a device start. Starting both in one turn
right after the first render was in step but still lost up to 140 ms of sound in 4 of 10 starts: inside
`playImmediately` the rate observation's subscribers (`isPlaying`, 5–28 ms of SwiftUI and Combine work in the debug
build, more while the process was slowed) ran between the picture's start and the sound's.

## Fix

- **The paused render takes up a paused seek** (`AudioRing.syncReader`, `AudioTrackRenderer.syncWhilePaused`, the
  source node's paused branch in `TimelineAudioEngine`) and wakes the feeder, which fills the new position before Play.
  Play starts with sound from its first sample, every time.
- **Play on an output that is not rendering starts cold** (`PlaybackAudioSource.isRendering`: the graph stopped by the
  idle rule, or started and not yet rendered): `play()` starts the device as before, then holds sound and picture until
  the output renders, checked every 2 ms on the main run loop (`OutputStartWait`, limit 1.5 s). That also waits for the
  main thread to come back from the device start; then both start as from a running output.
- **Both clocks start back to back** (`PlayerClock.startClocks`): the rate observation leaves `isPlaying` alone while
  they start, and it is published after both.
- **A start that stalled inside `playImmediately` pins the sound to the picture's own start** (`PictureStart`, engine
  `play(from:alignedToHostTime:)`, a pending anchor carrying that host time): if the picture's timebase moved more than
  10 ms before the call returned, the sound joins where the picture is, losing that much of its beginning, in step.
- Drift is no longer corrected by a re-seek ([second case](2026-11-20-picture-reseeked-under-running-sound.md)).
- The bench reports `underrunFrames` and `driftCorrections` per start and has local knobs to repeat one scenario and to
  lengthen the idle stop (`SRTFLOW_PLAYBACK_START_ONLY`, `_REPEAT`, `_IDLE_SECONDS`). The M1's strict profile no longer
  skips the idle start.

## Verification

- M1, 20 s idle stop, one launch each (load 7–11 before, 4–5 after), start skew (picture ahead negative) / longest frame
  hold / lost sound in ms: before, 8 starts, 3 out of the strict limits: skew −97 to −9 (−19 median), holds 133 / 117 /
  67, lost sound 12 on every start and 47 / 109 twice (12,834 / 11,718 frames underrun), 3 drift corrections; after,
  10 starts, all within the strict limits: skew −27 to +1 (−16 median), no frame held over 33 ms, no sound lost, no
  underrun, no drift correction. First sound 138–320 ms after Play, first picture 155–332 ms (the device start).
- `scripts/check-audio-engine.sh` group 17 (`PausedSeek.swift`): a paused seek, then Play: the first quantum has data and
  sound from its first sample. Without the paused sync: 4,096 frames underrun, the whole quantum silent (2 checks red).
- `scripts/check-player-clock.sh` (`LandingChecks.swift`, real AVPlayer): Play on an output that has not rendered holds
  sound and picture, both start from the playhead once it renders, without a native jump; a second press cancels;
  an output that never renders lets both start after 1.5 s; a stalled start pins the sound 50 ms back, a quick one does
  not. The previous `PlayerClock` fails the hold.
- Eight mutations of the new rules (a re-seeking or too-large drift correction, a seek while playing that lets the sound
  run, a cold start without the wait, the rate subscribers between the starts, the sound before the picture, no pin
  after a stall, no paused sync) each turn `checks/playback-start-wiring.sh` red.
- `checks/playback-start-wiring.sh` pins the cold start, the pinned sound after a stall and the paused sync;
  `checks/PlaybackStart/test_compare.py` pins the recorded idle starts red under the strict profile.

## Lessons

- A device start slows the whole process for a while after `start()` returns: do not start one clock in that turn and
  trust the other to follow. Yield to the run loop and let the output render first.
- Test the condition the user meets: two seconds of idle left the device warm and hid the failure; 20 s reproduced it.
- `setRate(_:time:atHostTime:)` is a seek whenever the host time is not the present or a time is given. A start or a
  correction that must keep the picture moving uses `playImmediately` or the `rate` property.
- A lock-free ring whose reader only runs while playing holds its old round while paused; let the reader take up a new
  round on every quantum, paused or not.
- The rules live in [playback start](../architecture/playback-start.md) and the [audio engine](../architecture/audio-engine.md).
