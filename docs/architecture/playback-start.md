# Playback start

## The preview path

The Play button and Space use `PlayerClock.togglePlayback()`. A loaded timeline can receive Play while its first
composition is still being built. The clock retains the request through installation of the item and audio source and
placement of the playhead. The current player and item must be ready for the synchronized native start. Pause, a second
press while pending, and preview teardown cancel the request. [Play during project open could crash the preview](../bugfixes/2026-11-19-play-before-preview-ready.md).

**The sound never starts ahead of the picture** (2026-11-19, the user: 「声音和画面必须要同步的，我们要解决的是播放就马上响应，
不应该让用户等待」). Play starts both clocks at once only from a *positioned* picture: placed precisely at the playhead and
primed, so it moves the moment the sound does. Every paused state of a played item is kept that way:

- After an exact paused seek, the clock waits for both the native player and its item, then prerolls asynchronously
  while audio stays paused, at a quarter of playback rate (less data to prepare around a trimmed cut). If the new
  composition has picture in a mounted preview, the clock also waits for the preview layer's first display-ready
  frame. Any newer placement or item cancels the earlier preparation. A surface that becomes hidden or detaches can
  finish the wait after 750 ms.
- **A new item (after opening, an edit or an optimized-media swap) is primed only when Play asks**, at playback
  rate, and both clocks start once it is primed. Priming every installed composition while editing holds the
  preview's playback buffers: on the preview ratchet's busy scenario a full-rate preroll measured 324–344 MB on the
  hosted runner ([case](../bugfixes/2026-11-19-preview-start-before-preroll.md)), and a quarter-rate one held about
  50 MB more while paused on the M1 (193 instead of 140 MB after the scenario's build) and peaked at 318–321 MB
  hosted (limit 315; other PRs that day 263–282 MB). So the first Play after an edit waits for that preroll, in
  step: about 0.13 s on the M1 for the 4K fixture.
- A pause holds the picture: once the item's timebase has stopped (usually inside `pause()`; otherwise the time
  observer reports it, AVFoundation calls it when playback stops) the playhead and the sound move to the frame the
  picture stopped on, a few milliseconds, and that counts as positioned. A stopped `CMTimebase` is read without the
  player's queue (`currentTime()` stays banned). If picture and sound stopped more than 50 ms apart (a stall, a
  drift correction still seeking) the picture is placed precisely at the sound instead.
- A hover never moves this picture (since 2026-11-20): it runs on its own player, see [Hover](#hover) below.

Play from a positioned picture is the ordinary native rate start plus the engine from the same position; the audio
engine reuses its prepared samples when the paused anchor matches. Any other Play (a scrub, a placement still preparing,
a failed preparation) stays pending while the clock places and primes the picture at the
playhead, then starts both. **Play never re-seeks the picture after the sound has started**: before 2026-11-19 a resume
and a Play while hovering did (`setRate(_:time:atHostTime:)` with a time is a native seek), and on a long-GOP source the
picture stayed frozen for 0.6–0.9 s while the sound played
([case](../bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md)).

**Nothing re-seeks the picture under running sound** (2026-11-20). `setRate(_:time:atHostTime:)` re-seeks for any
explicit time and for any host time but the present (probe on a 1080p 8 s GOP: `.invalid` at "now" froze the picture
418 ms, a host time 100 ms ahead 354 ms, 100 ms back 171 ms), so `PlayerClock` never calls it
([case](../bugfixes/2026-11-20-picture-reseeked-under-running-sound.md)):

- *A click or a drag on the timeline while playing* holds the sound with the picture (`holdForLanding`), places and
  primes the picture there like a paused seek, and the Play that stays pending starts both together. The sound used to
  jump at once while the picture re-seeked under it (0.6 s at 4K mid-GOP in original mode). The wait is the decode at
  the click, in step: short with optimized media.
- *Drift* (the picture's timebase and the engine's playhead more than 40 ms apart on two ticks, both read at the same
  moment) is corrected by running the picture 0.75–1.25× until it is back on the sound (`AVPlayer.rate`: no time jump,
  frames keep flowing), and beyond 0.25 s by landing both again like a click. Already playing, a Play that finds the
  picture stopped under the sound lands both again too.
- *The output restarted under a playing picture* (a device change) lands both again.

**Play on an output that is not rendering** (2026-11-20; the graph stopped by the two-minute idle rule, or restarted and
not yet rendered: `PlaybackAudioSource.isRendering`). `play()` starts the device as before, then holds sound and picture
until the output renders (`OutputStartWait`, polled every 2 ms on the main run loop, at most 1.5 s), so the start also
waits for the main thread to come back from the device start. A device start slows the whole process for a while:
started in the same main-thread turn, `playImmediately` took 11–111 ms in 3 of 8 cold starts, and the picture ran
42–97 ms ahead of a sound that reached the speakers 50–170 ms after Play
([case](../bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md)). Every start then runs `startClocks`: the
picture first, then the sound from the same position on the output's next quantum (the picture 10–25 ms ahead, as on
every start); the rate observation's subscribers (5–28 ms of SwiftUI and Combine work in the debug build) run after
both, not between them. If `playImmediately` still stalled after the picture had begun to move (its timebase more than
10 ms along when the call returns, `PictureStart`), the sound is pinned to the picture's own start instead (the engine's
pending anchor carrying that host time): in step, the sound loses that much of its beginning. On the M1 after a 20 s
stop, 10 cold starts kept start skew within −27 to +1 ms with no frame held over 33 ms and no sound lost (before: 3 of
8 out of step by up to 97 ms, frames held up to 133 ms).

**A paused seek fills the new position before Play** (2026-11-20). The engine's ring is single-writer / single-reader and
its reader used to move to a seek's new round only while playing, so after a paused seek a full ring took no new data
and every positioned start lost its first quantum (11.6 ms per track), 50–140 ms when the feeder ran late after a device
start. The source node's paused branch now takes up the new round on every quantum and wakes the feeder
([audio engine](audio-engine.md)).

What still waits, in step: the first Play on a new item (its preroll); a Play right after a click, while
the picture at the playhead is still being decoded (about 0.6 s on the M1 three seconds into an eight-second 4K GOP,
short with optimized media); a click while playing (the same decode at the click); a Play during project open; a Play
as the first input after the two-minute idle stop (the output device starts). Audio supplies the master clock. See the
[audio engine](audio-engine.md) and the [composition time ledger](preview-free-transform.md#两条渲染管线一份时间账).

Build and media work belongs to open and edit preparation. Play consumes the preview that exists or is on its way.
The optimized-media coordinator queues swaps for paused playback. [Optimized media](optimized-media.md).

The normal Play path leaves an active audio graph running. Getting a suspended or system-stopped output graph back
can require Core Audio to start a device. If the first input after the idle stop is Play, the existing recovery path
starts the device before advancing the playhead, and the cold start above holds both until it renders. The
user-presence signal can wake it ahead of Play. The two-minute
policy and measured hardware behavior are in the [audio-engine contract](audio-engine.md).

## Hover

**A hover runs on its own player** (2026-11-20, approved by the user: 「做，多 50 MB 可以」). With the engine,
`PlayerClock.peek` shows the pointer's frame on `HoverPreview`'s player. The editing player stays placed and primed at
the playhead, so Play while hovering or right after a hover starts at once, like a resume. Before, the hover scrubbed
the editing player, and Play waited until the playhead's frame was decoded again: 0.59 / 0.61 s median to sound and
picture on the M1, three seconds into the fixture's eight-second 4K GOP. Now it is 17–22 / 40–49 ms.
([case](../bugfixes/2026-11-20-play-after-hover-waited-for-decode.md)).

- **The hover item is the preview's own.** It is built on the preview item's asset and video composition, so upper
  tracks, alpha sources and web-motion movies are composed exactly as in the preview. `HoverPreviewSurface` draws it over the editing
  picture with the grade and covers at the hover's time: a `PlayerLayerView` with its own `FilterStackAttachment`
  and a `CoverHostView`, the same classes as the preview. The overlays above (shapes, texts, subtitles) read
  `displayTime` as before. The editing picture under it keeps the playhead's grade and covers.
- **Visibility.** The hover picture is shown once its first seek has landed (a frame composed at the hover time:
  `seekingWaitsForVideoCompositionRendering`). A frame left from an earlier hover never flashes. It is hidden in the
  same turn as the hover's end: `peekTime` set to nil hides it, from `endPeek`, Play, a seek, a new item or a teardown.
  `HoverPreview` sets the view's `alphaValue` directly, never through SwiftUI. The layer's background is clear, so a
  frame not drawn yet shows the editing picture, not black.
- **Memory only around a hover.** The item is created at the first hover and dropped
  `HoverPreview.releaseDelay` (3 s) after the hover ends. A new preview item ends the hover, and the next hover builds
  on the new item. On the M1 the first hover cost 43 MB over the 4K fixture and 12 MB over its 1080p opening. On the
  preview ratchet's busy 1080p scenario it cost 10 / 48 MB in two launches against 10 / 1 MB for the old hover. The
  preview ratchet gates it as its own item, `<scenario>.hover.peakMB`
  ([preview perf ratchet, section 15](preview-perf-ratchet.md)).
- **Without the engine** (the burn-in preview, or before the first item) a hover still scrubs the one player. `endPeek`
  scrubs it back.

## Measurements

`scripts/check-playback-start.sh` launches the debug editor five times in a graphical session. Each launch opens a
saved synthetic project through the same document and preview path as the editor. The launch starts with an empty
in-process media and composition cache. Filesystem caching follows the host operating system.

The project has a 1080p opening and cut, three composited upper video tracks, six PCM tracks, and a trimmed 4K H.264
source with an eight-second GOP. The timeline starts cold at zero, then tests the positioned start, a deep seek within
the 4K GOP, the frame before the 1080p cut, a new item from the production rebuild (`fresh-item`: Play once its paused
picture is up, as after an edit), Play right after a far click (`seek-play`), space to play, pause a
second later and play again (`resume`), Play while the pointer hovers the 1080p opening with the playhead in the 4K
source (`peek-play`) and right after it leaves the timeline (`peek-end-play`), a click far ahead while playing in the 4K
source (`play-seek`: the click is the measured action), the 4K tail, Play at the exact end, and a suspended output
graph. The scenarios are staged through the editor's entry points in `PlaybackStartScenarios.swift`. The end replay waits for native placement at the
tail and must start at zero. The idle case uses the production suspension entry and confirms the graph has suspended
before Play. If focus or pointer activity wakes it during preparation, the check tries the setup once more. The
idle-policy tests cover when the two-minute stop is due.

**Each scenario starts from a settled pause** (`PlaybackStartScenarios.settle`). Before staging, the bench pauses, which
also drops a failed trial's pending Play. It waits until the item's timebase has stopped and no placement runs, then
250 ms more, the gap a person leaves before the next action. Until 2026-11-20 each staging seek followed the previous
measurement's pause within a millisecond. In about 1 of 10 gate launches the seek to 10.0 after the `cut` scenario then
reported done without the frame ever arriving, and one failed trial's leftover Play turned the next scenario's Play into a
pause ([case](../bugfixes/2026-11-20-playback-gate-staging-after-pause.md)).

A staging step waits only for what its measurement needs. `fresh-item` waits for the click's placement and then for the
rebuilt item's paused picture, never for the paused picture of the item the rebuild replaces. A staging timeout names
the player's state: playhead, timebase, rate, item status, placement and last picture.

The window goes on the display with the highest refresh rate. On the M1 it had landed on a 25 Hz television
(40 ms between display deadlines), which quantized every picture time and could hide a short stall.

Time begins at the call to the editor's Play action. Each attempt measures the following.

- Action dispatch time on the main thread.
- Host time and position of the first nonzero PCM samples rendered by the first active audio track. The benchmark
  measures real source-node output after track gain. For onset it takes the later of the render callback and the
  sample's host timestamp. The master output is muted downstream.
- Host time and position of the first advancing frame offered for display by the production player's item.
  The observer takes the display's host timestamps from Core Video's sampling thread once the mounted
  `AVPlayerLayer` is ready and keeps normal layer rendering enabled. Presentation timestamps identify the
  timeline frame. The raw samples also record when the item first offered a frame, including a still frame
  during paused preparation. The display thread separately records its shortest presentation interval and
  longest callback gap, including while the preview has no frame. Warm-start samples supply the display
  interval control for the same run.
  [Core Video display link](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k).
- The difference between the two onset times and how far the first sampled audio and video have moved from the requested time.
- The signed audio timeline minus video presentation timestamp at video onset and at the first follow-up display deadline
  with audio at least one second later. The PCM sample clock supplies the audio position at the same host time.
- The picture's first two seconds after its first advancing frame, or up to the timeline's last frame
  (`PlaybackStartContinuity`): `stallMs`, the longest time between consecutive advancing frames including the gap to
  the end of the window (33 ms for this 30 fps fixture on a 60 Hz display), and `maxSkewMs`, the largest
  audio-minus-picture difference at any displayed frame with sound at the same host time.

The display deadlines and the rendered PCM are in-process endpoints. Speaker latency, window compositing, lip sync in
actual footage, and monitoring devices also belong in the manual regression.

## CI and budget changes

The graphical step contributes to `check-all`. It uploads all samples, the machine fingerprint, individual outliers,
and each scenario's median and worst result. The first launch of the freshly built editor is an unscored warm-up:
it runs the same scenarios, may fail, and its start skews are printed in the summary. Every scored launch must
produce first audio and advancing video and satisfy the structural limits. A cold open must build and attach once and
open exactly three video assets. Warm and idle starts must build, attach and open zero times. Cold open, a new item,
replay from the end, Play right after a click and a click while playing each require one native preroll after Play (a
new item primed while paused would show none). Play during or right after a hover requires none: the picture stayed
placed and primed. In each scenario the median of each timing must be in budget, and
at least half of the whole launches must jointly meet the per-launch budgets in `checks/PlaybackStart/budgets.json`.
A gross stall, an onset gap or start skew of 500 ms or more or a missed one-second follow-up, is the reported
failure itself: none may occur in the first five launches, and at most one per scenario across the eight after
confirmation. A median budget may not exceed its per-launch budget.

The budgets, per launch / median in ms (`checks/PlaybackStart/budgets.json`, recalibrated on hosted samples on
2026-11-19, see below):

- Every scenario unless listed: first sound 340 / 130 and first picture 380 / 180, onset separation 160 / 105, start
  skew and one-second offset 45 / 34 (display and audio sampling on the 30 fps fixture), longest stall in the first
  two seconds 300 / 100, worst skew there 60 / 40.
- Cold open (includes preview construction and output startup): sound 3.8 / 3.2 s and picture 3.9 / 3.3 s, dispatch
  90 / 20, onset separation 330 / 220, start and worst skew 190 / 175, one-second offset 120 / 60.
- Warm start: sound median 200, picture median 220, one-second offset 60 / 45.
- The frame before the cut: sound 300 / 230 and picture 340 / 265, so the decoder can prepare both sides.
- Deep in the GOP: start skew 60 per launch. The 4K tail: sound 360 per launch, picture 420 / 250, start skew
  60 / 45, worst skew median 45.
- Replay from the end (it rewinds, then prerolls after Play): sound 340 / 250, picture 410 / 330, start skew 60 / 55,
  worst skew 100 / 80 (a hosted run's five-launch median reached 53 ms; three runs of data).
- A new item (Play primes it): sound 700 / 450, picture 800 / 460, with the common skew limits (120 / 137 ms median
  on the M1, 101–298 / 141–307 ms hosted).
- Play right after a click and a click while playing include decoding the picture at the playhead (about 0.6 s on the
  M1): sound 3.5 / 2.5 s, picture 3.6 / 2.6 s; start skew 80 and worst skew 120 per launch.
- Play while hovering and right after a hover (since 2026-11-20): the common budgets, with start skew 60 per launch as
  deep in the GOP. The same placed 4K start, `middle`, measured 26 / 58 ms median to sound and picture hosted.
  Before the hover player these scenarios waited for the decode (581 / 606 ms hosted, 590 / 606 ms on the M1).
- The start after the idle stop (output device startup): sound 700 / 600, picture 800 / 650, onset separation
  550 / 230, start and worst skew 160 / 45, one-second offset 48 per launch, lost audio 200 / 75.

The JSON also caps dispatch time and how much of the timeline either stream can skip. A median budget may not exceed
its per-launch budget, and since the worst skew includes the first frame no worst-skew budget may be below the start
skew budget: `compare.py` rejects such a file. In calibration the first Play was usually dispatched in under 2 ms.

**This Mac fails on any picture out of step** (`strict` in `budgets.json`, applied wherever the runner is not the
hosted virtual Mac): every launch of every scenario must start the picture within 70 ms of the sound and within 45 ms
of its timeline, never hold a frame longer than 100 ms in the first two seconds (three frames at 30 fps; the cadence
is 33 ms) and never differ from the sound by more than 45 ms there. Since 2026-11-20 no scenario is skipped; until then
the start after the idle stop was (its hosted limits still allow 160 ms of skew per launch). On the M1 after the
2026-11-19 fix the worst elsewhere were 51 ms onset (a resume), 25 ms skew and one 50 ms frame hold. The onset limit was
60 ms until 2026-11-20. Since then the first sound is the playhead's own sample instead of one 11.6 ms quantum later. A
cold open whose first advancing picture is the second frame is in step at 47–64 ms onset gaps (start skew −2 to
−19 ms), and it failed the old limit in 2 of 5 launches twice. The hosted limits above stay looser: the virtual Mac decodes 4K in
software and sometimes stalls for a second after a clean start, and an isolated stalled launch counts as one
outlier under the half-of-the-launches rule.

On the M1 MacBookPro17,1 with macOS 26.5.2, five runs of the 111.5 MB fixture put positioned picture onset at
69–117 ms median outside the cut and at 232 ms just before it. First-open audio and video were 1.36 / 1.74 s
and 1.38 / 1.75 s median / worst, with a 16 ms maximum onset skew. The suspended graph took 335 / 402 ms
for audio and 373 / 515 ms for picture. Calibration repeats reached 138 ms of device startup skew and
41 ms one second later. They also reached 3.22 s
to the first-open picture, and 648 ms to a picture after idle.

On the hosted VirtualMac2,1, waiting for the mounted picture lowered worst cold onset separation from 750 ms
to 137 ms and worst timeline skew from 617 ms to 114 ms. All first advancing cold frames were one frame from
the requested position. [Hosted calibration samples](https://github.com/skysf/SkyCut/actions/runs/44456515780/artifacts/14498244162).

A hosted virtual Mac can deliver a late display or audio sample after good playback onset. The gate distinguishes
onset from the one-second sample and stops waiting five seconds after Play. A missing onset or failed scored launch
fails the check. A follow-up timeout after both streams start is a failed launch for the whole-launch count, ranks
above every measured follow-up in the median, and counts as a gross stall. A one-second skew of 500 ms or more is
an outlier, not a stall: hosted runners sometimes stall decoding for a second after a clean start, for example
1,365 ms and 1,824 ms at the cut, while every scored start was in sync.

When hosted timings need confirmation, the check starts three more processes once and scores all eight launches
together, with the same budgets. The required graphical step stops after 15 minutes (each launch after 120 s; watching
the first two seconds of every start added about 4 minutes on 2026-11-19). It runs in shard 1 right after the App
build, with the preview perf ratchet and the lightest share of `check-all.sh`, so a re-run after a timing flake costs
that shard (until 2026-11-20 shard 1 held every full-App check and took 27–31 minutes). Shard 1 has 45 minutes, the
others 30.

The hosted budgets were recalibrated on 2026-11-19 from 55 launches in 11 runs of the merged #502 code
(44 after the warm-up). Of those launches, 24% of cold opens and end replays and 2–11% of the other scenarios
exceeded a per-launch budget set from the first 15 hosted launches. The first launch of each fresh build
froze the cold-open picture for 4.5 s once in 11 runs, and its warm-start skew reached 218 ms at the 90th
percentile against 19 ms later. The five raised median budgets are those whose 8-launch median exceeded the old
budget in more than 0.5% of bootstrap resamples. End replay's per-launch picture limit moved to the hosted 95th
percentile, 380 ms, and its per-launch skew limit to 60 ms, above the new median. Every other limit is unchanged.
A bootstrap of the scoring over the 44 scored launches is red in 3% of runs.
The recorded hosted failure from before the fix stays red even with three healthy confirmation launches. A 100 ms
delay at Play and a picture 300 ms late in every cold open are red in all resamples. A picture 1 s late in a
quarter of the cold opens is red in 64% of them. `checks/PlaybackStart/test_compare.py` pins these
verdicts. [Hosted timing case](../bugfixes/2026-11-19-playback-start-hosted-timing-outliers.md).

**Second calibration, from 25 hosted attempts (2026-11-19).** That 3% did not hold: 6 of the 23 hosted attempts
of main's code since #517 failed the step, none of them on a regression
([case](../bugfixes/2026-11-19-playback-gate-failed-healthy-hosted-runs.md)). The hosted virtual Mac (three cores)
runs the benchmark at a load average of 20–50. There its cold open starts the picture about 100 ms after the sound
(launch medians 102 ms start skew, 127 ms onset separation), and on a slow host the five-launch medians reached
208 / 230 ms. Every other start stays within about 20 ms. Three attempts failed because no audio block covered the
first picture and two because a staged placement took over 5 s; both are bench defects, fixed. The rest were medians
just over budgets set from too few runs. The budgets above come from all 25 attempts (22 of main's code, 3 of the
2026-11-19 fix) under one rule: **the first five launches of a slow host may fail, the eight with confirmation must
pass**. Confirmation launches run cleaner: the slowest healthy cold open had 230 / 208 ms five-launch medians and
174 / 141 ms over eight. So each median budget sits above every healthy eight-launch median with a margin and below
the recorded hosted failure confirmed with three healthy launches (cold open onset and skew 240 / 204 ms against
220 / 175 ms budgets, replay from the end skew 76 against 55 ms). Per-launch limits sit near the hosted 95th–99th
percentile: 8% of cold-open launches exceed one, 12% of replays from the end, 0–8% elsewhere.

Replayed on those 25 attempts (`test_compare.py` pins the slowest one), the scoring passes 24, 17 of them in the first
five launches. The last needs a confirmation its run never made (replay from the end, 257 ms median to first sound at
a load of 45). With the earlier budgets the same attempts, bench defects left out, passed 19 of 22 (12 in the first
five). The recorded hosted failure, the M1 freezes of the
[resume and hover case](../bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md) and a 350 ms delay at Play still
fail. On the hosted runner a cold-open picture up to about 200 ms behind its sound passes, as it does on a slow host
today; on this Mac the strict profile holds every start to 45 ms.

The hosted gate cannot separate a partial regression that stays near the runner's noise. Before the final #502 fix,
the cold-open onset gap had a 151 ms median in launches 2–5 and a single 700 ms stall in launch 1, which would pass
today. The local M1 run, the warm-up line in each summary and the manual first-launch check cover that range.

`checks/playback-start-wiring.sh` guards the Play entry against rebuilding, proxy work and synchronous media reads,
pins graph starts to recovery, and checks the item installation order and CI connection. It also requires that a new
item's preroll waits for Play (the memory rule above), that Play places and primes the picture before starting the sound
and never re-seeks it while starting, that a pause holds the stopped picture (inside `pause()` or from the time
observer's stop callback), and that a hover with the engine runs on its own player, built on the preview item's asset
and video composition, leaving the editing picture placed. Since 2026-11-20 it also
requires that `PlayerClock` never calls `setRate(_:time:atHostTime:)`, that drift is corrected by the picture's rate
and a too-large drift lands both again, that a seek while playing holds the sound with the picture, that a Play on an
output that is not rendering waits for it, that both clocks start back to back in `startClocks` (`PictureStart.begin`:
the sound pinned to a stalled picture's start), and that the engine's paused render takes up a paused seek. It also
requires that the bench stages every scenario from a settled pause and `fresh-item` without waiting for the replaced
item's picture.
`scripts/check-player-clock.sh` (`SyncedStartChecks.swift`, `LandingChecks.swift`) checks the same behavior on a real
AVPlayer with a picture-only long-GOP clip; `scripts/check-audio-engine.sh` group 17 checks the paused seek.

Reverse verification injected 350 ms into the production audio start. The GUI check failed both warm onset budgets
in every launch, and the wiring guard rejected the blocking call. Separate mutations exercised each other wiring
rule, including a duplicate open build and removal of the graphical CI step. On 2026-11-19 the previous
`PlayerClock` failed 8 of the clock checks, seven mutations of the playback rules (priming every new item while
paused, Play not priming a new item, a re-seeking start, the sound started before the placement, no hold on pause,
the stop callback ignored, a hover end that scrubs) each turned the wiring guard red, and
five pre-fix M1 launches failed the gate on structure, on the hosted rules (resume and Play while hovering: five
gross stalls each) and on the strict rules. On 2026-11-20 the previous `PlayerClock` failed 12 of the new clock checks
(the cold start, a click and a drag while playing, drift both ways and a too-large drift), the engine without the
paused sync failed group 17 (a whole first quantum silent), and `test_compare.py` pins the recorded idle starts and
clicks while playing red.

Run locally from a logged-in graphical session with the repo's ffmpeg available.

```bash
PLAYBACK_START_OUT=/tmp/playback-start /bin/bash scripts/check-playback-start.sh
```

Update the versioned budgets in a PR. Attach fresh local and CI runs with all initial and confirmation samples, machine
fingerprints and the reason for each proposed change. Base a hosted change on several runs' launches, not one batch,
and check each median budget against the spread of resampled 8-launch medians. Check that a deliberate delay at the
production playback entry and the recorded failure in `test_compare.py` still fail. Keep fixture changes and any
resulting budget changes visible in review.

## Manual regression before release

- [ ] On a long-GOP source (a screen recording or an original without optimized media), play, pause, and press Play
      again at once and after a few seconds: picture and sound continue together, no frozen frame under the sound.
- [ ] Move the pointer over the timeline (the hover picture follows it) and press Space while it is still there, and
      again right after moving it off: playback starts at once from the playhead, picture and sound together, and the
      hover picture is gone. Hover over a graded part, a blur or mosaic and a web-motion clip: the hover picture
      looks like the preview there.
- [ ] Make an edit and press Play as soon as the preview has updated: no wait before both start.
- [ ] While a long-GOP source plays in original mode, click far ahead on the timeline, and drag the playhead: the sound
      stops until the picture there moves, then both run together; no sound over a frozen picture.

- [ ] Open a larger project, press Play as soon as the timeline appears, and watch the first motion while listening
      to the onset. Repeat with the playhead placed in the middle, just before a hard cut, and near the end.
- [ ] Repeat in original and optimized-media modes while proxies are still being prepared. Check that the active
      playback stays on its item. Pause and check that the pending swap can install.
- [ ] Leave the editor idle for more than two minutes. Compare Play as the first input with Play after returning
      the pointer to the window. Check the first frame and sound, including through the usual external output device.
- [ ] Check lip sync at the first audible syllable and one second later with a real talking-head clip.
- [ ] Right after installing a new build, launch it, open a larger project and press Play at once. CI does not score
      the first launch of a new build.
