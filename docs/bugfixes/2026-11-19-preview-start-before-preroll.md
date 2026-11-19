# 2026-11-19 Preview sound advanced before video was ready to move

## Symptom

The five-trial graphical benchmark on the hosted VirtualMac2,1 measured 367.6 ms median and 750.2 ms worst
separation between first sound and first picture after opening. The first picture's audio timeline error reached
616.9 ms. Mid-GOP starts and replay from the end also exceeded the onset sync budget. One second later,
every measured offset was under 19 ms. [First runner samples](https://github.com/skysf/SkyCut/actions/runs/44446600269/artifacts/14494172744).

## Root cause

A successful precise seek places the paused frame. The native player and item can report ready before their
render pipelines have media buffered for advancing playback. Play published the sound anchor as soon as the seek
completed and called the native synchronized start. The slower picture pipeline continued to prepare as the audio
anchor moved. Measuring only after drift correction missed the delay.

## Fix

An exact paused seek uses short asynchronous `AVPlayer.preroll` while the audio anchor is paused. The
player can accept the preroll as its new item finishes loading. The short preroll limits how much of the next
segment the decoder prepares at a cut. The Play request stays pending until preparation completes. A later
seek or a new item invalidates the previous positioning request and cancels its preroll.

A positioned preview starts with `playImmediately(atRate:)`. Reanchoring to a host time after a full preroll
caused the first 4K picture to arrive more than two seconds into playback on the M1 test. After an audio
device restart, startup uses a fresh synchronized host anchor. Both the current item and the native player
must be ready for synchronized start.

## Verification

The first runner samples record the failing production path before preroll. The focused wiring guard requires
the preparation callback before releasing Play and the graphical gate checks actual sound, picture and sync.
The guard also failed when preroll was temporarily removed. The clock check cancels a pending Play during native
positioning and verifies that completion leaves both streams paused.

## Lessons

Measure sync when the first moving picture arrives and again after the clocks have converged. Treat seek completion
and native playback preroll as distinct steps in [the playback-start contract](../architecture/playback-start.md).
