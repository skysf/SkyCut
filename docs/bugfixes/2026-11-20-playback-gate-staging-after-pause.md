# 2026-11-20 The playback gate's staging timed out after a pause it issued a millisecond earlier

## Symptom

`scripts/check-playback-start.sh` sometimes failed before measuring anything. The bench reported:

> fresh-item: Timed out waiting for paused picture at 10.0

It happened 8 times on 2026-11-19/20:

- hosted: twice in one of E2's runs and once in PR #531's run 44626955792, which sent #531 back from the merge slot;
- local: three gate launches, one warm-up and one launch outside the gate.

Each time it came right after the `cut` scenario, and the trial wait ran out after 20 s.

Once a related failure appeared: `play-seek`'s Play before the click never started ("Timed out waiting for playback
before the click"). The next scenario, `near-end`, then failed too: "Timed out getting playback at 21.0s".

## Root cause

1. **Each scenario touched the playhead a millisecond after the previous measurement's pause.** `measure` ends with
   `pause()`, and the next scenario's staging seeked at once. Every timeout was a seek to 10.0 issued about 1 ms after
   pausing a playing player.

   A traced failing launch (local gate, 2026-11-20) compared with a passing one:

   | | Seek finished | Preroll finished | Frame at 10.0 |
   | --- | --- | --- | --- |
   | Failing launch | 9 ms | 16 ms | Never vended to the bench's video output; it held the 6.067 s frame vended at the seek's completion |
   | Normal launch | 14 ms | 531 ms | Vended |

   In the failing launch, a second seek to the same time finished in 6 ms with a 1 ms preroll and changed nothing. The
   next scenario's seek elsewhere worked.

   It did not reproduce outside the gate: 0 of 20 rounds with a standalone player, 0 of 28 repeated `cut` →
   `fresh-item` transitions in one launch, and 0 of 10 launches with fresh fixture media. The gate itself hit it in
   about 1 of 10 launches. So the trigger also depends on load and timing.

   A person never seeks a millisecond after pausing. Whether the preview layer also kept the old frame was not
   settled: a layer check (`displayedPixelBuffer()` against reference frames) never caught a failure in three gate
   runs.
2. **A failed trial kept its pending Play.** The next scenario's Play toggled that leftover request into a pause, so it
   failed too.

## Fix

- **Settle between scenarios** (`PlaybackStartScenarios.settle`). Before staging each scenario the bench:
  1. pauses, which also clears a failed trial's pending Play;
  2. waits until the item's timebase has stopped and no placement runs (at most 5 s);
  3. waits 250 ms more, the gap a person leaves before the next action.

  The measured actions are unchanged.
- **`fresh-item` no longer waits for the old item's paused picture.** The rebuild replaces that item. It now waits for
  the clock's placement, then rebuilds and requires the rebuilt item's paused picture at 10.0 as before.
- **Staging timeouts state the player's state:** playhead, timebase, rate, item status, placement, last picture.
- **Strict onset recalibrated (local profile only):** 70 ms instead of 60. Since #531 the first sound is the playhead's
  own sample, no longer one quantum (11.6 ms) late. An M1 cold open whose first advancing picture lands on the second
  frame is in step (start skew −2 to −19 ms) at onset gaps of 47–64 ms, and it failed 60 ms in 2 of 5 launches twice.
  The skew limits (45 ms) are unchanged, and `test_compare.py` still fails the recorded idle starts and clicks while
  playing.

## Verification

The original timeout never reproduced on demand: it needed the whole gate sequence under some load, about 1 launch in
22 (8 of 178 launches with the full sequence on 2026-11-19/20: 3 of 42 hosted, 5 of 136 local). So the fix was
verified by injection, both ways, plus gate runs.

- **Stuck old picture** (local build, uncommitted): the bench's probe stops seeing frames from the current item when
  `fresh-item` begins, as in the traced failure, and sees a newly attached item again.
  - Old staging: `fresh-item` fails with "Timed out waiting for paused picture at 10.0", the gate's error.
  - New staging: `fresh-item` passes and measures Play on the rebuilt item (114 ms to first sound).
- **Failed trial** (local build, uncommitted): `play-seek` throws after its first Play.
  - Without the fix: `near-end` fails with "Timed out getting playback at 21.0s", the cascade seen in the gate.
  - With the fix: `near-end` and the rest pass.
- **Local gate after the fix:** 3 runs (18 launches with warm-ups), no trial error. The worst cold-open onset gap was
  62.1 ms, in step (start skew 17 ms); it passes the new 70 ms strict limit and would have failed the old 60 ms.
- **Guard:** `checks/playback-start-wiring.sh` fails without the settle call, with `fresh-item` waiting for the old
  picture again, with a settle that does not pause, and with one that does not wait for the stop.
- **`test_compare.py`:** an in-step cold open at a 64 ms onset gap passes the strict profile; the recorded failures
  stay red.

## Lessons

- **Separate staged steps the way a person would.** A bench that acts within a millisecond of its own pause tests a race
  no user meets, and flakes on it.
- **A staging step should wait only for what the measurement needs.**
- **A failed trial must not leave state for the next one.** Reset before each scenario.
- **Let a staging timeout say what the player was doing,** so the next hosted occurrence can be read without a rerun.
- **Recalibrate a limit when a fix moves what it measures.** Here the first sound moved one quantum earlier.
- The rules live in [playback start](../architecture/playback-start.md).
