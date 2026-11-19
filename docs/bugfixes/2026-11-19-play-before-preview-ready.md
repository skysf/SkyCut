# 2026-11-19 Play during project open could crash the preview

## Symptom

Press Play as soon as the timeline of a freshly opened project appears. A synthetic 4K project with four picture tracks
and six audio tracks reproduced a process exit on macOS 26.5.2. The exact error was
`AVPlayer cannot service a synchronized playback request via setRate:time:atHostTime: until its status is AVPlayerStatusReadyToPlay`.

## Root cause

The transport becomes usable when the document's timeline arrives. Its first composition is still being built. The old
clock forwarded Play to the empty native player, whose rate became positive. After attaching the new item and sound
source, the rebuild's restoring seek treated that rate as active playback. It called `setRate(_:time:atHostTime:)`
while the replacement item was still loading. The usual edit debounce also delayed the first preview of an open
document by 120 ms. Once a frame was positioned, Play issued another zero-tolerance seek and reset the audio
feeders even when the starting position was the one already prepared.

## Fix

Keep the Play request on `PlayerClock` until the first preview is installed. The restore seek happens while paused,
after which the clock consumes the request when both the player and its current item are ready and positioning
has completed. Play can reuse the positioned picture and audio buffers. Closing the preview or pressing Play
again discards the request. Opening a document starts its first build immediately using the existing asynchronous
composition path.

## Verification

The production clock check presses Play before attaching a real item, then installs sound and restores the time just
as a preview rebuild does. It also presses Play twice and closes a preview with a request pending. Both cases leave the
new item paused. Temporarily dropping the request while no item was attached made the early Play assertion fail.

## Lessons

Track a user's request independently of the native player's rate while installing an item. Synchronised playback
requires the native player and the specific current item to be ready. See the [audio-engine contract](../architecture/audio-engine.md).
