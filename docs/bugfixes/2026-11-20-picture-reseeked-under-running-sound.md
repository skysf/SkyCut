# 2026-11-20 A click while playing and every drift correction re-seeked the picture under the running sound

## Symptom

E2's open items 2 and 3 (2026-11-19), on a long-GOP source in original mode:

- **A click on the timeline while playing**: the sound jumped to the click at once and the picture stayed on the old
  frame until the decode at the click caught up. On the M1 (MacBookPro17,1, macOS 26.5.2) the playback-start bench's
  new `play-seek` scenario (playing in the fixture's 4K source with an 8 s GOP, a click from about 11 s to 18 s) put
  the sound at the click after 31–38 ms and the first moving picture there after 980–1,046 ms: picture and sound about
  a second apart in 10 of 10 clicks.
- **Drift correction**: when the picture's clock and the engine's drifted more than 40 ms apart (after the idle start,
  [case](2026-11-20-idle-start-picture-ahead-and-lost-sound.md)), the correction itself froze the picture: holds of
  67–133 ms in the bench's first two seconds, 0.43 s in a probe one second into an 8 s 1080p GOP.

## Root cause

Both used `AVPlayer.setRate(_:time:atHostTime:)` to put the picture on the sound's timeline while the sound kept
playing (`anchorVideo`). With a time it is a native seek: the decoder restarts at the previous keyframe and no frame
arrives until it decodes up to the target. A probe on 2026-11-20 (1080p picture-only clip, 8 s GOP) showed it is a seek
in every form: an explicit time 100 ms back froze the picture 429–439 ms; `.invalid` time at "now" 418 ms; a host time
100 ms ahead 354 ms, 100 ms back 171 ms; each with a time-jump notification. The picture's timebase was in step the whole
time, so nothing measured the frozen stretch: the drift check compares timebases, and the gate had no scenario for a
click while playing.

The same call served the start after a system-stopped output (`anchorVideo(to: nil)`), Play finding the picture stopped
under the sound, and the output's recovery while playing: each a seek under running or about-to-run sound.

## Fix

- `PlayerClock` no longer calls `setRate(_:time:atHostTime:)` (`anchorVideo` is gone; the wiring guard rejects the call).
- **A seek while playing holds the sound with the picture** (`holdForLanding`: engine and player paused, Play kept
  pending) and then runs the paused seek: a click places and primes the picture at the target, a drag scrubs; the
  pending Play starts both together once the picture can move.
- **Drift is corrected by the picture's rate** (`VideoDriftCheck`): the picture's timebase and the engine's playhead,
  read at the same moment, more than 40 ms apart on two ticks in a row → the picture runs 0.75–1.25× (`AVPlayer.rate`)
  until the gap is closed (aiming at 0.5 s), then at 1× again. The probe: 0.8× and 1.25× for 0.5 s each caused no time
  jump, the longest frame 44 ms at 0.8×. Beyond 0.25 s apart, or when the output restarted under a playing picture, or a
  Play finds the picture stopped under the sound, both land again like a click.
- The bench gained `play-seek` (the click is the measured action; one native preroll expected) with the budgets of
  Play right after a click.

## Verification

- M1, `play-seek`, two interleaved pairs of launches, five clicks each, load 5–7: before, sound 31–38 ms and picture
  980–1,046 ms after the click (10 of 10 out of the strict limits); after, sound 862–895 ms and picture 881–920 ms, start
  skew within 24 ms, no frame held over 33 ms, no underrun (0 of 10 out of the limits). The wait is the decode at the
  click in original mode (short with optimized media).
- `scripts/check-player-clock.sh` (`LandingChecks.swift`, real AVPlayer, picture-only long-GOP clip): a click while
  playing holds the sound until both start together at the click, with no native jump after; a drag holds it until the
  scrub settles; a sound 120 ms behind slows the picture (0.76×) and one 100 ms ahead speeds it up, one correction
  each, no native jump, back in step within 30 ms at 1×; one 0.5 s away lands both again. The previous `PlayerClock`
  fails 10 of these checks.
- `checks/playback-start-wiring.sh`: a re-seeking drift correction, a too-large drift that seeks, and a seek while
  playing that lets the sound run each turn it red; `test_compare.py` pins the recorded clicks red.

## Lessons

- Treat every `setRate(_:time:atHostTime:)` as a seek. To keep a playing picture moving, change its `rate`; to put it
  somewhere else, hold the sound and place it.
- A timebase in step is not a picture in step: measure frames on screen (the bench's stall and onset metrics) for every
  action that can move the picture while sound plays, a click included.
- The rules live in [playback start](../architecture/playback-start.md).
