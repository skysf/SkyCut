# 2026-11-20 The merge slot tested two pull requests at once

## Symptom

On 2026-11-19 the slot dispatched #532's test run (44622932657) at 21:51:25 UTC, and then #531's (44623440524) at 21:54:33
while #532's was still running. #531 had the older label; its own check-all turned green at 21:53:27.

- Two full test runs competed for the five macOS runners.
- #532's test finished first and green, but every pass now stopped at #531's running test, so #532 couldn't merge until
  #531's test ended (here #531's ended red, and #532 merged at 22:13).
- Had #531's ended green, #531 would have merged first, and #532's finished test would have been stale and run again.

The slot exists so that one pull request at a time is tested and merged.

## Root cause

`Slot.serve` started every pass again from the oldest label and stopped at the first pull request that was "testing".
That pass order holds the slot only while the pull request under test is also the oldest waiting one. When an older
pull request's own check was still running, the slot moved on to a younger one and dispatched its test. Once the older
pull request's check turned green, the next pass reached it first, built its test merge and dispatched a second test.

The checks didn't catch it. `FakeGitHub.overlaps` records a test dispatched while another one runs, but every scenario's
slot test ended at the next poll. No scenario had an older head turn green while a younger PR's test was still running.

## Fix

`scripts/merge-slot.py`: `Slot.holder()` picks the one pull request that may move, and `serve` advances only it while
it holds.

- A pull request holds the slot while a `merge-slot/pr-<N>` run of it is queued or in progress.
- It also holds for ten minutes after that run ends, so a green test merges next and a red one sends its pull request back.
- It also holds for ten minutes after this job dispatched its test: GitHub lists a dispatched run a little later.
- Of several holders (left by a slot from before the fix), the earliest test holds.
- The runs are read from GitHub every pass, so the workflow's next job (the script stops after 320 minutes, the cron
  restarts it) holds the same pull request.

## Verification

- `checks/MergeSlot/MergeSlotChecks.py`, with the fake's new slow tests (`slow_tests`: 12 polls, longer than the
  ten-minute window, like a real 13–16-minute run) and late listing (`list_delay`):
  - an older pull request turning green during a younger one's test (the 11-19 sequence);
  - the workflow's next job arriving mid-test;
  - two tests left running by a slot from before the fix.
- Before the fix the first two record overlapping tests (red). With it: no overlap, and the pull request tested first
  merges first.
- Reverse verification, without bytecode caching: red with main's `merge-slot.py`, and red for each mutation: `serve`
  ignoring the holder, `holder()` ignoring running runs, tests that just ended, or its own dispatches, and the latest
  test holding instead of the earliest.
- 184 cases green.

## Lessons

- A queue's order has to say who is being served, not only who is first; when the first one isn't ready, the next one
  can't be allowed to start a second service.
- A fake whose work ends at the next poll hides every bug that needs two things going at once. Give it durations like the
  real ones (here longer than the ten-minute window) and the platform's delays.
- Mutation runs that rewrite a Python file in place can run a stale `__pycache__` when a mutation keeps the file's size and
  the restore lands in the same second: run them with `PYTHONDONTWRITEBYTECODE=1`.
- The rule lives in [build doc "Merge slot"](../build/build-and-packaging.md) ("One at a time").
