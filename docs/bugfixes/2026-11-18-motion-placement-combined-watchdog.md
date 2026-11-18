# 2026-11-18 Motion placement groups shared one outer watchdog

## Symptom

PR #470's first CI run failed only the motion-placement check. Its core checks started at 07:44:02 UTC, and the official-template
stage started at 07:46:27 after about 145 seconds of successful earlier work. The single 240-second outer watchdog killed the
combined process at 07:48:02, leaving only about 95 seconds for all official renders. No assertion failure preceded the timeout;
the other four CI shards passed.

## Root cause

The original App-linked fixture launched one process under one 240-second watchdog. Adding three complete official pages,
independent parameter renders, portraits, reuse and localized-label checks put another complete suite inside the same remaining
budget. Local runs completed quickly enough to hide the CI-specific exhaustion. This was a test-driver budget error, not evidence
that a renderer/page timeout or an assertion should be weakened.

## Fix

The driver in `scripts/check-motion-placement.sh` always launches `core` and `official` sequentially in separate processes, each
with its own unchanged 240-second limit and project root. It attempts both groups after assertion failures, startup failures or a
timeout, aggregates failed groups and exits nonzero if any failed. `checks/MotionPlacement/Main.swift` requires an explicit valid
group argument, runs exactly that group's existing checks and clears isolated defaults before and after the run. Each process
retains job and keep-awake cleanup assertions: core 197 plus official 167 is 364, preserving the prior 362 and duplicating only
those two lifecycle checks. Official template/default/repeat, independent parameter, portrait, placement and label stage logs
identify future stalls without changing the tested renders.

## Verification

The motion wiring guard requires the mandatory two-group driver, isolated roots, both Swift routes, the 240-second bound and
failure aggregation. It failed against the old single-process script before the driver was changed.

- `/bin/bash scripts/check-local.sh motion-placement` passed all scan guards, core 197 and official 167 assertions.
  Both mandatory processes completed; the whole placement script took 77 seconds on the local M1. No render, frame,
  page check or assertion was removed, and each process retained the 240-second watchdog.
- Omitting `official` from the new driver loop made the wiring guard exit 1. Restoring the exact script returned the
  guard to exit 0; `/bin/bash -n scripts/check-motion-placement.sh` also passed.
- Evidence: `/tmp/g26-c-ci-failed.log`, `/tmp/g26-c-group-driver-before.log`,
  `/tmp/g26-c-group-driver-omission-reverse.log`, `/tmp/g26-c-group-driver-wiring.log` and
  `/tmp/g26-c-split-check-local.log`. CI still has to pass on the corrected head before merging.

## Lessons

An outer integration-suite watchdog must bound the work it was sized for. Keep separately growing suites in mandatory bounded
processes, attempt all groups and aggregate failures; do not enlarge page/helper limits or silently skip a group. Keep the driver
and Swift routing contract pinned together. The durable test contract is in [Motion presets](../architecture/motion-presets.md#9-original-official-web-templates-2026-11-18).
