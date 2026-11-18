# 2026-11-17 Inspection check mistakes a pending job for a failure

## Symptom

PR #465's CI run 44037867737 failed `video-inspection` twice before its first analysis assertion:
`Production inspection: running, still running`, with `elapsed_seconds:30`. The other shard-1
checks, including 197 motion-placement assertions, passed. The unchanged inspection check passed
165 assertions locally, with its first real inspection taking 16 seconds; retrying CI alone did
not solve the failure.

## Root cause

The main inspection harness called `AIJobs.wait(for:seconds:30)` once and immediately required
`.done`. This API deliberately caps one client wait at 30 seconds; reaching that boundary means
the client should query the job again, not that the inspection failed. The existing delivery
harness already polls while a job is running. The main harness had not followed that contract.

## Fix

`VideoInspectionChecks.waitForTerminalJob` now applies the same bounded, four-wait policy to the
main harness's inspection jobs. It stops at any terminal state and preserves every result,
coverage, evidence, cancellation and nonediting assertion. A still-running job after the bound
still fails. The shell's 480-second outer deadline is unchanged.

Only the isolated check client changes; production inspection, delivery checks, job timing and
the CI workflow remain unchanged. A `job-polling` case exercises controlled pending observations
and the real job registry, without injecting any analysis result into the actual inspection.

## Verification

The `SRTFLOW_INSPECTION_CASE=job-polling` run of `scripts/check-video-inspection.sh` passes seven
assertions: a pending reply followed by each terminal status (done, failed, cancelled), no further
polling after a terminal result, and a job that never completes within the bounded polls.

Reverse verification replaces the bounded loop with one poll. The same isolated check exits 1,
with four failures out of seven: all three pending-to-terminal observations and the exhausted
poll bound. The fixed source is restored byte for byte afterward. Logs are
`/tmp/g26-inspection-polling-positive.log` and `/tmp/g26-inspection-polling-reverse.log`.

After restoration, `/bin/bash scripts/check-local.sh video-inspection docs-index-drift` passes
all scan guards, 172 inspection assertions (the original 165 plus seven polling assertions),
and documentation indexes. The complete real inspection check takes 210 seconds locally;
the 480-second outer deadline is unchanged. Log: `/tmp/g26-inspection-polling-check-local.log`.

## Lessons

A per-request wait window is not the operation's completion deadline. A check client must
observe a terminal result before making result assertions, and retain a separate overall bound.
The permanent contract lives in
[finished-video inspection](../architecture/finished-video-inspection.md).
