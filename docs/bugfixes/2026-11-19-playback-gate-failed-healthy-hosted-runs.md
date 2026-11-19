# 2026-11-19 The playback-start gate failed healthy builds on hosted runners

## Symptom

After #517 recalibrated the hosted playback-start budgets (an estimated 3% of healthy runs red), the "Playback start
benchmark" step kept failing pull requests that did not touch playback, main's own run included. Every such PR paid a
re-run of shard 1. Of the 23 hosted attempts of main's code between #517's merge and 17:40 UTC that day, 6 failed
the step:

- main's run 44575112140, PR #515 (twice): "No audio timeline sample at first picture" in one launch's replay from the
  end or warm start, which fails the run without confirmation. PR #515 also lost a third attempt when that error
  stopped a launch;
- PR #522 (no production code): cold open after confirmation, 3 of 8 launches within the per-launch budgets, onset
  separation median 174 ms against 170, one-second offset median 38 against 34;
- PR #513: warm start's first sound, median 140 ms against 130 after confirmation.

The fix for the resume and hover freeze added a fifth failure type on its own runs: "Timed out waiting for paused
picture at 10.0" while staging the rebuilt-item scenario, in 2 of 5 launches.

## Root cause

1. **The audio lookup had no tolerance for slivers.** The benchmark's audio probe records one block per render
   quantum, from the block's first audible sample, with the device's host timestamp. Consecutive blocks can leave a
   sliver between them (a later first audible sample, timestamp jitter). A first picture that landed in one had no
   sound to compare with, and the launch failed as a structural error, which skips confirmation.
2. **Staging waits were 5 s.** The hosted virtual Mac (three cores) runs the benchmark at a load average of 20–50,
   and decodes 4K in software: a paused placement two seconds into the fixture's 8-second GOP took over 5 s there.
3. **The budgets came from too few hosted runs.** #517's estimate rested on 55 launches in 11 runs. Across 25 hosted
   attempts the cold open's five-launch medians reached 230 ms onset separation and 208 ms start skew on a slow
   host, warm start's first sound 174 ms, the 4K tail's first picture 374 ms and replay from the end's start skew 67 ms.
   The budgets were 170, 145, 130, 180 and 48 ms. The confirmation launches run cleaner (the slow host's cold open:
   174 / 141 ms over eight), but several median budgets sat below even those.

## Fix

- `PlaybackStartAudioTimeline` (new, from the probe): a moment up to 5 ms past a block reads that block; a longer gap
  is missing sound and still fails, now with the gap's size in the message.
- `PlaybackStartBench.wait`: staging waits get 20 s. Play keeps its own 5 s deadline.
- `checks/PlaybackStart/budgets.json`, recalibrated from all 25 attempts (22 of main's code, 3 of this branch) under
  one rule: the first five launches of a slow host may fail, the eight with confirmation must pass. Each median budget
  sits above every healthy eight-launch median with a margin and below the recorded hosted failure confirmed with
  three healthy launches. The list and the reasoning are in
  [playback start](../architecture/playback-start.md#ci-and-budget-changes).
- `compare.py` also rejects a worst-skew budget below the start-skew budget (the worst skew includes the first frame).

## Verification

- Replaying the scoring on the 25 hosted attempts (confirmation from each run's own repeats): 24 pass, 17 in the first
  five launches; the last needs a confirmation its run never made. With the earlier budgets, bench defects left out,
  19 of 22 passed.
- `checks/PlaybackStart/test_compare.py` pins the slowest healthy cold open (PR #522's eight launches: its first five
  fail, all eight pass), the recorded hosted failure (red in the first five and with three healthy confirmation
  launches), the M1 freezes and a 350 ms delay at Play (red), and the budget-file rules.
- `scripts/check-player-clock.sh` (`AudioTimelineChecks.swift`): a sliver between blocks reads the block before it, a
  long gap reads nothing and reports its size. With the old lookup the sliver check fails.
- The final code's local M1 gate passes the new budgets and the strict profile.

## Lessons

- Before trusting a flake rate, replay the gate on every hosted run since it changed: the estimate from one batch
  was 3%, the record 26%.
- A structural error skips confirmation, so a defect in the bench's own measurement fails runs outright. Make the
  measurement tolerate the runner's noise, and report what it saw when it still cannot measure.
- Compare medians over the eight confirmed launches, not only the first five: confirmation launches run cleaner, and
  a budget between healthy eight-launch medians and the recorded failure separates them.
- The rules are in [playback start](../architecture/playback-start.md).
