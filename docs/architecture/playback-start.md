# Playback start

## The preview path

The Play button and Space use `PlayerClock.togglePlayback()`. A loaded timeline can receive Play while its first
composition is still being built. The clock retains the request through installation of the item and audio source and
placement of the playhead. The current player and item must be ready for the synchronized native start. Pause, a second
press while pending, and preview teardown cancel the request. [Play during project open could crash the preview](../bugfixes/2026-11-19-play-before-preview-ready.md).

An already positioned preview uses the completed native seek. The audio engine can reuse its prepared samples when
the paused anchor matches the playhead. Audio starts on its next render quantum and supplies the master clock.
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
end replay must start at zero. The idle case uses the production suspension entry and confirms the graph has suspended
before Play. The idle-policy tests cover when the two-minute stop is due.

Time begins at the call to the editor's Play action. Each attempt measures the following.

- Action dispatch time on the main thread.
- Host time and position of the first nonzero PCM samples rendered by the first active audio track. The benchmark
  measures real source-node output after track gain. For onset it takes the later of the render callback and the
  sample's host timestamp. The master output is muted downstream.
- Host time and position of the first frame offered for display by the production player's item while playing.
  The observer samples at display-link deadlines once the editor's mounted `AVPlayerLayer` is ready and keeps
  normal layer rendering enabled. Presentation timestamps identify the timeline frame.
- The difference between the two onset times and how far the first sampled audio and video have moved from the requested time.
- The signed audio timeline minus video presentation timestamp at video onset and at the first follow-up display deadline
  with audio at least one second later. The PCM sample clock supplies the audio position at the same host time.

The display deadlines and the rendered PCM are in-process endpoints. Speaker latency, window compositing, lip sync in
actual footage, and monitoring devices also belong in the manual regression.

## CI and budget changes

The graphical step contributes to `check-all`. It uploads all samples, the machine fingerprint and a table with each
scenario's median and worst result. Every trial must produce audio and video and meet the limits in
`checks/PlaybackStart/budgets.json`. A cold open must build and attach just once and open the source assets. Warm and
idle starts must build, attach and open zero times.

The warm budget is 130 ms to first audio and 180 ms to the first video presentation for each scenario's median.
Single trials have 220 ms audio and 280 ms picture ceilings for occasional scheduling noise. The picture and sound
clocks must agree within 34 ms at onset and one second later on the 30 fps fixture. Cold open includes first-preview
construction and output startup. Its median budgets are 3.2 s to first audio and 3.3 s to first video, capped at 3.8 s
and 3.9 s per trial. Its sync limit is 65 ms skew at
onset and 34 ms one second later. A suspended graph has a separate 700 ms audio and 800 ms video budget for output
device startup, with 75 ms skew at onset and 34 ms one second later. The JSON also caps onset separation, dispatch
time and how much of the timeline either stream can skip.

On the M1 MacBookPro17,1 with macOS 26.5.2, five runs of the 111.5 MB fixture put positioned picture onset at
69–88 ms median across the five warm scenarios and 129 ms worst overall. First-open audio and video were
1.62 / 1.96 s and 1.71 / 2.04 s median / worst. Suspended-graph audio and video were 428 / 436 and
508 / 588 ms. Busy-machine repeats reached 3.22 s to the first-open picture, 648 ms after idle and 234 ms near the
4K tail. The worst offset one second in was 22.8 ms across the calibration runs.

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
