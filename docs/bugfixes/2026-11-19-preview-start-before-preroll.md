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

An exact paused seek uses asynchronous `AVPlayer.preroll` while the audio anchor is paused. A new item
primes after both readiness signals and uses playback rate. Its mounted preview layer reports when its
first picture can display. A positioned item prerolls with a smaller rate to prepare fewer frames at a cut.
The Play request stays pending until preparation completes. A later seek or a new item invalidates the
previous placement, readiness observation and preroll.

Starting a full preroll on every newly installed composition also staged playback buffers while the user was
editing. The existing preview ratchet measured 344.2 MB and 324.0 MB across two hosted attempts. The clock
now primes a new item at playback rate when a Play is pending. The usual paused placement still decodes its
still picture and Play reuses that location.

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
