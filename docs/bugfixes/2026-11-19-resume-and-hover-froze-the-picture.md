# 2026-11-19 Resuming playback or pressing Play while hovering froze the picture while the sound played

## Symptom

The user: pressing Play on a newly opened project, the picture sometimes took a while to catch up with the sound.
On the M1 (MacBookPro17,1, macOS 26.5.2) the playback-start benchmark reproduced it in two everyday actions on the
fixture's 4K H.264 source with an eight-second GOP:

- Space to play, space to pause a second later, space again: the sound came back after 28–34 ms, the picture stayed
  on the paused frame and first moved after 827–921 ms (onset gap 799–887 ms, three launches).
- Play while the pointer hovered another part of the timeline: sound after 32–38 ms, first moving picture after
  624–655 ms (onset gap 592–617 ms).

After the frozen stretch the picture jumped ahead and was in step again. The existing benchmark never paused and
resumed and never hovered, so its gate was green.

## Root cause

1. **Play only started cleanly from a "positioned" picture, and a pause did not leave one.** `PlayerClock.play()`
   took the synchronized start (`playImmediately` plus the engine from the same position) only when a paused precise
   placement had finished at the playhead. After a pause there was none, so Play sent the sound from the clock's
   last tick (up to 50 ms stale) and called `anchorVideo(to: start)`: `setRate(_:time:atHostTime:)` with a time is a
   native seek. On a long GOP the decoder restarts at the keyframe. The picture's timebase ran in step with the
   sound, so the drift check saw nothing, but no frame arrived until the decode caught up.
2. **A hover moves the one native player away from the playhead.** Hover preview scrubs the same player. Its end
   scrubbed back without preparing playback, and Play while hovering took the same re-seeking start.
3. **A new item was primed only by Play.** After opening, an edit or an optimized-media swap, the first Play paid
   the full preroll (124–129 ms at the 4K source's second GOP) before either stream started. In sync, but a wait.
4. **After the idle stop the picture started ahead of the sound.** Play started the output device and then the
   picture at once, while the sound waited for the device's first render (an anchor pinned by that render). In 3 of
   5 launches the picture ran 51–151 ms ahead, and the drift correction re-seeked it: a stall of 100–183 ms in the
   first two seconds.

The bench also sampled the picture on the wrong display: on this Mac the window landed on a 25 Hz television, so
every picture time was quantized to 40 ms and a short stall could hide between two refreshes.

## Fix

- The sound never starts ahead of the picture: `play()` starts both clocks only with a positioned, primed picture.
  Otherwise it places and primes the picture at the playhead and keeps the Play pending. It never re-seeks the
  picture while starting. Already playing, it only re-anchors a picture that stopped.
- A pause holds the picture: once the item's timebase has stopped (inside `pause()`, or as reported by the time
  observer, which AVFoundation also calls when playback stops) the playhead and the sound move to the picture's
  frame and that position counts as positioned. A picture that did not stop where the sound did (over 50 ms apart:
  a stall or a drift correction in flight) is placed precisely at the sound instead.
- A hover that ends places and primes the picture back on the playhead instead of scrubbing.
- When the output device has just started, Play waits until it has rendered once (`isRendering` on the audio source,
  `OutputStartWait` in the clock), then pins the sound to the next quantum and starts the picture at that quantum's
  host time: both begin together. (Starting the picture when the first render was noticed still left its first frame
  up to 97 ms behind the sound.)
- Every paused placement primes the picture, a new item's first one included, at a quarter rate (rate 1 only when
  Play is already pending). On the M1 a new item primed that way started as fast as one primed at full rate.
- `PlayerClock` shed named helpers to stay under 600 lines: `PreviewReadiness`, `ChainedScrub`, `VideoDriftCheck`,
  `PlaybackTimeEstimate`, and `PausedPictureHold` / `SoundStartWait` (`PlaybackStartSync.swift`).
- The benchmark samples on the fastest display, watches the first two seconds (longest stall, worst skew) and adds
  fresh-item, seek-play, resume and peek-play scenarios. Off the hosted runner every launch must keep the picture in
  step (`strict` in `checks/PlaybackStart/budgets.json`).

## Verification

- M1, interleaved launches under the same load, before / after (first sound / first moving picture, ms):
  resume 31 / 874 → 25 / 26; fresh item 126 / 135 → 29 / 45. Play while hovering 37 / 645 → 602 / 616: in step now,
  and the remaining wait is the decode at the playhead (see Lessons). The final local gate (five launches and a
  warm-up): no stall over the 33 ms frame cadence in any scenario, the idle start included; worst skew 24 ms, and
  49 ms after the idle stop in the one start whose first audible sample came 128 ms into its timeline (the sound
  side, not explained yet). Details: [playback start](../architecture/playback-start.md).
- `scripts/check-player-clock.sh`, `SyncedStartChecks.swift` (real AVPlayer on a picture-only long-GOP clip): a new
  item starts inside the Play call, a pause puts playhead and sound on the stopped picture, a resume and a Play
  after a hover cause no native jump, Play while hovering does not start the sound before the picture is back, a
  pause with the picture elsewhere places it at the sound, neither clock starts before a just-started device renders
  and then both start together. The previous `PlayerClock` fails 9 of these checks; ignoring the device fails 1.
- `checks/playback-start-wiring.sh`: nine mutations (the old preroll condition, a re-seeking start, the sound started
  before the placement, no hold on pause, the stop callback ignored, a hover end that scrubs, a start that does not
  wait for a just-started device, an engine that always reports rendering, a picture not started on the sound's
  quantum) each turn it red.
- `checks/PlaybackStart/test_compare.py` pins the recorded M1 freezes red under hosted and local scoring.

## Lessons

- A start is synchronized only if nothing seeks after the sound has started. Every paused state must be a prepared
  position, a pause included; check the actions people repeat (pause / resume, hover), not only a click then Play.
- One native player serves hover and playback: after a hover the picture must be decoded at the playhead again,
  and on an eight-second GOP that wait is about 0.6 s on the M1. Optimized media makes it short.
- Measure the picture where it can show a short stall: the fastest display, and the whole first seconds.
- The rules live in [playback start](../architecture/playback-start.md).
