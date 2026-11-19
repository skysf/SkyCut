# Playback start

## The preview path

The Play button and Space use `PlayerClock.togglePlayback()`. A loaded timeline can receive Play while its first
composition is still being built. The clock retains the request through installation of the item and audio source and
placement of the playhead. The current player and item must be ready for the synchronized native start. Pause, a second
press while pending, and preview teardown cancel the request. [Play during project open could crash the preview](../bugfixes/2026-11-19-play-before-preview-ready.md).

After an exact paused seek, the clock waits for both the native player and its item, then prerolls asynchronously
while audio stays paused. A new item prerolls at playback rate. A positioned item prerolls at a smaller rate
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
suspension entry and confirms the graph has suspended
before Play. The idle-policy tests cover when the two-minute stop is due.

Time begins at the call to the editor's Play action. Each attempt measures the following.

- Action dispatch time on the main thread.
- Host time and position of the first nonzero PCM samples rendered by the first active audio track. The benchmark
  measures real source-node output after track gain. For onset it takes the later of the render callback and the
  sample's host timestamp. The master output is muted downstream.
- Host time and position of the first advancing frame offered for display by the production player's item.
  The observer samples at display-link deadlines once the editor's mounted `AVPlayerLayer` is ready and keeps
  normal layer rendering enabled. Presentation timestamps identify the timeline frame. The raw samples also
  record when the item first offered a frame, including a still frame during paused preparation.
- The difference between the two onset times and how far the first sampled audio and video have moved from the requested time.
- The signed audio timeline minus video presentation timestamp at video onset and at the first follow-up display deadline
  with audio at least one second later. The PCM sample clock supplies the audio position at the same host time.

The display deadlines and the rendered PCM are in-process endpoints. Speaker latency, window compositing, lip sync in
actual footage, and monitoring devices also belong in the manual regression.

## CI and budget changes

The graphical step contributes to `check-all`. It uploads all samples, the machine fingerprint and a table with each
scenario's median and worst result. Every trial in the accepted batch must produce audio and video and meet the limits in
`checks/PlaybackStart/budgets.json`. A cold open must build and attach just once and open the source assets. Warm and
idle starts must build, attach and open zero times. Cold open and replay from the end each require one successful
native preroll.

The warm median budget is 130 ms to first audio and 180 ms to the first video presentation. Single trials have
340 ms audio and 380 ms picture ceilings. One hosted start needed 290 ms for audio and 314 ms for picture,
with 16 ms onset skew or less across the five launches. The trim immediately before the cut
has a 230 / 265 ms median budget and 300 / 340 ms single-trial ceiling so the decoder can prepare both sides.
Replay from the end also rewinds the item. Its median audio and picture budgets are 190 / 250 ms, capped at
265 / 310 ms per trial.
Warm onset and all one-second offsets have a 34 ms median budget on the 30 fps fixture. Individual samples
have a 45 ms ceiling for display and audio sampling noise, with 48 ms one second after a device restart.
Cold open includes preview construction and output startup.
Its median budgets are 3.2 s to first audio and 3.3 s to first video, capped at 3.8 s and 3.9 s per trial.
Its onset skew limit is 120 ms median and 150 ms per trial. A suspended graph has a separate 700 ms audio and
800 ms video ceiling for output device startup. Its onset skew limit is 45 ms median and 135 ms per trial.
The JSON also caps onset separation, dispatch time and how much of the timeline either stream can skip.
The idle median limit on lost audio is 75 ms and the single-trial limit is 200 ms.
Cold dispatch has a 20 ms median budget and a 90 ms single-trial ceiling. In calibration the first Play
was usually dispatched in under 2 ms. An individual launch took 61 ms without a build or native seek in
the Play callback.

On the M1 MacBookPro17,1 with macOS 26.5.2, five runs of the 111.5 MB fixture put positioned picture onset at
69–117 ms median outside the cut and at 232 ms just before it. First-open audio and video were 1.36 / 1.74 s
and 1.38 / 1.75 s median / worst, with a 16 ms maximum onset skew. The suspended graph took 335 / 402 ms
for audio and 373 / 515 ms for picture. Device startup skew reached 104 ms at onset and settled within
17 ms one second later. Calibration repeats reached 41 ms after one second on a device restart, 3.22 s
to the first-open picture, and 648 ms to a picture after idle.

On the hosted VirtualMac2,1, waiting for the mounted picture lowered worst cold onset separation from 750 ms
to 137 ms and worst timeline skew from 617 ms to 114 ms. All first advancing cold frames were one frame from
the requested position. [Hosted calibration samples](https://github.com/skysf/SkyCut/actions/runs/44456515780/artifacts/14498244162).

A hosted virtual Mac can supply an isolated late frame. CI runs one fresh five-launch batch when each affected
scenario has only one failed trial. Eligible failures are one-second timing, a positioned start skew of at most
100 ms, or a rewind onset time within 50 ms of its single-trial budget. Each scenario must have a complete
five-trial batch within budget. A failure in the same scenario in both batches fails the gate. Missing playback,
other timing failures, repeated failures in one scenario and structural failures fail immediately.
The artifact preserves both raw summaries and gives the complete confirmed batch for each scenario.

`checks/playback-start-wiring.sh` guards the Play entry against rebuilding, proxy work and synchronous media reads,
pins graph starts to recovery, and checks the item installation order and CI connection.

Reverse verification injected 350 ms into the production audio start. The GUI check failed both warm onset budgets
in every launch, and the wiring guard rejected the blocking call. Separate mutations exercised each other wiring
rule, including a duplicate open build and removal of the graphical CI step.

Run locally from a logged-in graphical session with the repo's ffmpeg available.

```bash
PLAYBACK_START_OUT=/tmp/playback-start /bin/bash scripts/check-playback-start.sh
```

Update the versioned budgets in a PR. Attach fresh local and CI runs with all five samples, machine
fingerprints and the reason for each proposed change. Check that a deliberate delay at the production playback
entry still fails. Keep fixture changes and any resulting budget changes visible in review.

## Manual regression before release

- [ ] Open a larger project, press Play as soon as the timeline appears, and watch the first motion while listening
      to the onset. Repeat with the playhead placed in the middle, just before a hard cut, and near the end.
- [ ] Repeat in original and optimized-media modes while proxies are still being prepared. Check that the active
      playback stays on its item. Pause and check that the pending swap can install.
- [ ] Leave the editor idle for more than two minutes. Compare Play as the first input with Play after returning
      the pointer to the window. Check the first frame and sound, including through the usual external output device.
- [ ] Check lip sync at the first audible syllable and one second later with a real talking-head clip.
