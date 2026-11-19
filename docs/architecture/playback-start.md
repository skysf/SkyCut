# Playback start

## The preview path

The Play button and Space use `PlayerClock.togglePlayback()`. A loaded timeline can receive Play while its first
composition is still being built. The clock retains the request through installation of the item and audio source and
placement of the playhead. The current player and item must be ready for the synchronized native start. Pause, a second
press while pending, and preview teardown cancel the request. [Play during project open could crash the preview](../bugfixes/2026-11-19-play-before-preview-ready.md).

After an exact paused seek, the clock waits for both the native player and its item, then prerolls asynchronously
while audio stays paused. A new item prerolls at playback rate when Play requests it. A positioned item prerolls at a smaller rate
to prepare less data around a trimmed cut. If the new composition has picture in a mounted preview, the
clock also waits for the preview layer's first display-ready frame. Any newer placement or item cancels
the earlier preparation. A surface that becomes hidden or detaches can finish the wait after 750 ms.
Play advances an already positioned preview with the ordinary native rate start. When the output
graph has just restarted, Play aligns video to the audio host clock. The audio engine can reuse its prepared
samples whenever the paused anchor matches the playhead. Audio supplies the master clock.
`PlayerClock` corrects sustained video drift against this clock. See the [audio engine](audio-engine.md) and
the [composition time ledger](preview-free-transform.md#两条渲染管线一份时间账).

Build and media work belongs to open and edit preparation. Play consumes the preview that exists or is on its way.
The optimized-media coordinator queues swaps for paused playback. [Optimized media](optimized-media.md).

The normal Play path leaves an active audio graph running. Getting a suspended or system-stopped output graph back
can require Core Audio to start a device. If the first input after the idle stop is Play, the existing recovery path
starts the device before advancing the playhead. The user-presence signal can wake it ahead of Play. The two-minute
policy and measured hardware behavior are in the [audio-engine contract](audio-engine.md).

## Measurements

`scripts/check-playback-start.sh` launches the debug editor five times in a graphical session. Each launch opens a
saved synthetic project through the same document and preview path as the editor. The launch starts with an empty
in-process media and composition cache. Filesystem caching follows the host operating system.

The project has a 1080p opening and cut, three composited upper video tracks, six PCM tracks, and a trimmed 4K H.264
source with an eight-second GOP. The timeline starts cold at zero, then tests the positioned start, a deep seek within
the 4K GOP, the frame before the 1080p cut, the 4K tail, Play at the exact end, and a suspended output graph. The
end replay waits for native placement at the tail and must start at zero. The idle case uses the production
suspension entry and confirms the graph has suspended before Play. If focus or pointer activity wakes it during
preparation, the check tries the setup once more. The idle-policy tests cover when the two-minute stop is due.

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

The display deadlines and the rendered PCM are in-process endpoints. Speaker latency, window compositing, lip sync in
actual footage, and monitoring devices also belong in the manual regression.

## CI and budget changes

The graphical step contributes to `check-all`. It uploads all samples, the machine fingerprint, individual outliers,
and each scenario's median and worst result. The first launch of the freshly built editor is an unscored warm-up:
it runs the same scenarios, may fail, and its start skews are printed in the summary. Every scored launch must
produce first audio and advancing video and satisfy the structural limits. A cold open must build and attach once and
open exactly three video assets. Warm and idle starts must build, attach and open zero times. Cold open and replay from
the end each require one successful native preroll. In each scenario the median of each timing must be in budget, and
at least half of the whole launches must jointly meet the per-launch budgets in `checks/PlaybackStart/budgets.json`.
A gross stall, an onset gap or start skew of 500 ms or more or a missed one-second follow-up, is the reported
failure itself: none may occur in the first five launches, and at most one per scenario across the eight after
confirmation. A median budget may not exceed its per-launch budget.

The warm median budget is 130 ms to first audio and 180 ms to the first video presentation. Single trials have
340 ms audio and 380 ms picture ceilings. One hosted start needed 290 ms for audio and 314 ms for picture,
with 16 ms onset skew or less across the five launches. The trim immediately before the cut
has a 230 / 265 ms median budget and 300 / 340 ms single-trial ceiling so the decoder can prepare both sides.
Replay from the end also rewinds the item. Its median audio and picture budgets are 220 / 300 ms, capped at
265 / 380 ms per trial, and its start skew is 48 ms median and 60 ms per trial.
Warm onset and all one-second offsets have a 34 ms median budget on the 30 fps fixture. Individual samples
have a 45 ms ceiling for display and audio sampling noise, with 48 ms one second after a device restart.
Cold open includes preview construction and output startup.
Its median budgets are 3.2 s to first audio and 3.3 s to first video, capped at 3.8 s and 3.9 s per trial.
Its start skew limit is 145 ms median and 150 ms per trial, and its onset separation is 170 ms median and 330 ms per
trial. A suspended graph has a separate 700 ms audio and
800 ms video ceiling for output device startup. Its onset skew limit is 45 ms median and 160 ms per trial.
The JSON also caps onset separation, dispatch time and how much of the timeline either stream can skip.
The idle median limit on lost audio is 75 ms and the single-trial limit is 200 ms.
Cold dispatch has a 20 ms median budget and a 90 ms single-trial ceiling. In calibration the first Play
was usually dispatched in under 2 ms. An individual launch took 61 ms without a build or native seek in
the Play callback.

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
together, with the same budgets. The required graphical step stops after six minutes. Shard 1 has 40 minutes for
the full suite and both graphical checks, which took about 30 minutes with a cold build cache.

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

The hosted gate cannot separate a partial regression that stays near the runner's noise. Before the final #502 fix,
the cold-open onset gap had a 151 ms median in launches 2–5 and a single 700 ms stall in launch 1, which would pass
today. The local M1 run, the warm-up line in each summary and the manual first-launch check cover that range.

`checks/playback-start-wiring.sh` guards the Play entry against rebuilding, proxy work and synchronous media reads,
pins graph starts to recovery, and checks the item installation order and CI connection.

Reverse verification injected 350 ms into the production audio start. The GUI check failed both warm onset budgets
in every launch, and the wiring guard rejected the blocking call. Separate mutations exercised each other wiring
rule, including a duplicate open build and removal of the graphical CI step.

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

- [ ] Open a larger project, press Play as soon as the timeline appears, and watch the first motion while listening
      to the onset. Repeat with the playhead placed in the middle, just before a hard cut, and near the end.
- [ ] Repeat in original and optimized-media modes while proxies are still being prepared. Check that the active
      playback stays on its item. Pause and check that the pending swap can install.
- [ ] Leave the editor idle for more than two minutes. Compare Play as the first input with Play after returning
      the pointer to the window. Check the first frame and sound, including through the usual external output device.
- [ ] Check lip sync at the first audible syllable and one second later with a real talking-head clip.
- [ ] Right after installing a new build, launch it, open a larger project and press Play at once. CI does not score
      the first launch of a new build.
