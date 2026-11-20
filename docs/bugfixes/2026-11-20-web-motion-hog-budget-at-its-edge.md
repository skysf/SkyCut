# 2026-11-20 The web-motion hog check sat at the edge of its budget

## Symptom

Main's run of 2026-11-19 22:13 UTC (44626496956, shard 4) went red in `scripts/check-web-motion.sh`: "a page eating 128 MB
a frame is killed (SIGKILL) past its budget: nil". The watch's peak was 509 MB, and the 1.7 s render finished and was
accepted, so nothing was killed. The same code passed the PR's own run.

How often (GitHub run data, every checks run since a5e710fe, the last change to the watch or its checks, 11-18 10:02 UTC):

- web-motion ran 108 times (17 on main) and failed twice.
- This case failed once. The other failure (a PR, 11-18 20:29) was the load-memory group's "ready" sampling seeing
  0 MiB, a different case.

## Root cause

The check's 600 MB budget sat right where the hog's footprint lands on a hosted runner.

- 106 green runs killed the hog at 601–970 MB (median 642), and 25 of them within 20 MB of the budget.
- The footprint the watch reads goes up in jumps of hundreds of MB (locally the first sample over a 320 MB budget was
  529–626 MB). On the failing runner it stopped at 509 MB until the short render ended.
- Nothing in SkyCut changed between the green PR run and main's red one. The budget had no margin for how a shared
  runner's memory reading behaves.

## Fix

`checks/WebMotion/MemoryChecks.swift`: the hog's budget is `hogBudget`, 320 MB.

- That is two 128 MB allocations above a normal render (45–80 MB), and 190 MB under the failing run's peak, which would
  have been killed under it.
- The case still uses a real page, a real helper, a real kill and the same 50 ms watch.

## Verification

- With 320 MB, the memory group passed three runs in a row on an M1, killed at 529–626 MB after about 1 s. With
  600 MB, the same Mac killed at 813 MB after 2.5 s.
- Same rule as #517, a real regression still goes red. Each of these, put into the product one at a time, turns the
  case red:
  - the budget ignored (both budget comparisons in `WebMotionMemoryPolicy.verdict`): the render finishes, `nil`;
  - SkyCut never kills (`stop()` skipped in `WebMotionHelperProcess`): no SIGKILL;
  - the WebKit processes left uncounted (only the helper's pid sampled): `nil`.

## Lessons

- A memory budget a check sets for itself needs a margin against the platform's readings, not against the arithmetic
  of the page. Look at where the green runs land: if a quarter sit within a few percent of the line, the next red run
  is the runner, not the product.
- The rule in [web-motion renderer](../architecture/web-motion-renderer.md) ("Measured") now records both budgets'
  numbers. The reverse-check table there still holds for the hog.
