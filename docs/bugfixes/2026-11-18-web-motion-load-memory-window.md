# 2026-11-18 Web-motion memory accounting missed pages that had not finished loading

## Symptom

A page could allocate and retain memory during its top-level script or `motion.ready` while the parent's render budget
counted only the helper and previously reported WebKit processes. A new WebContent process was invisible until loading
and ready both succeeded. The load timeout and machine-critical-pressure stop still existed; the defect was missing
per-render memory accounting during that bounded interval.

## Root cause

`HelperRun` reported each page's PIDs after `PageWorker.load` and `finishLoading` returned. A stalled ready promise could
therefore prevent its own PID from being reported. The parent also discarded a PID whose first identity lookup failed,
even though a newly discovered process could become identifiable on the next watch tick.

The first continuous-discovery attempt also queried `WKWebView`'s testing network PID getter before a new view's first
load. On macOS 26.5.2, the positive-render crash stack was `HelperRun.loadPages` → `PageProcessTracker.sample` →
`Lockdown.processIdentifiers` → `-[WKWebView(WKTesting) _networkProcessIdentifier]`. The private selector existed but its
page/data-store precondition did not, so `responds(to:)` did not make an early call safe. The configured data store's
existence-checked getter avoids that assertion without launching a process. Each view keeps its own existing
nonpersistent store and process-pool configuration. See [WebKit's data-store implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.mm).

Retrying required two additional safeguards: the first report's monotonic receipt time must bound process birth so a
later recycled PID cannot become owned, and a canceled watch must finish its in-flight resolver before teardown takes
its final identity snapshot. Repeated cumulative reports must not move that birth ceiling forward.

## Fix

- `PageProcessTracker` samples the live retained-page collection before and throughout calibration/load/ready and frame
  work. It deduplicates positive PIDs and reports only changes, including replacement processes. `HelperReport.beforeFinish`
  performs its final scan and stops it before the terminal result; existing exit cleanup and test linger keep their order.
- WebContent and GPU discovery remains early. Networking is sampled from the configured store only when its
  `_networkProcessExists` check succeeds; the unsafe pre-load view getter is not polled.
- The parent remembers each raw PID's first `mach_absolute_time` receipt, retries unresolved identities before real live
  footprint reads, and retains every safely pinned identity for teardown. A bounded lookup reads BSD identity first, then
  requires a positive `ri_proc_start_abstime` no later than that original receipt. Ordinary teardown identity/equality is
  unchanged. The native timer cancel handler is awaited before final pinning and the teardown snapshot.
- Narrow test hooks observe actual footprint inputs and inject an identity lookup failure. They do not fabricate bytes,
  discover processes globally, or change the network lock, page clock, alpha pipeline, or renderer pixel version.

## Verification

The pre-fix `load-memory` group produced 10 failures out of 29 assertions. Both actual-helper probes confirmed one
32 MiB allocation in the exact first-view WebContent, but neither process entered live budget sampling; both reached the
four-second load timeout. The one-event identity fixture missed retry/live accounting, and a real post-cutoff child was
incorrectly accepted into ownership. Every synthetic child was cleaned up by an independently retained matching identity.

The first fixed run passed all 29 assertions, but those negative fixtures stopped the first single view during ready and
never reached ordinary worker creation. The broader local run then failed four normal/alpha checks with signal 5 and
stopped both App placement suites: immediate discovery on a new, not-yet-loaded worker reached the unsafe network getter.
After the existence-checked data-store lookup, the same positive paths and bounded negatives passed together (101/101).
The 29/29 negative result alone was insufficient to validate this earlier attempt.

Independent reversals then produced the following actual runtime failures:

| Protection temporarily removed | Failures out of 29 |
| --- | --- |
| Live retained-page discovery | 4: both real load/ready pages missed accounting and the budget deadline |
| Watch-tick identity retry, keeping final teardown retry | 1: only the live-sampling latch failed, despite a populated final history |
| Monotonic process-birth cutoff | 2: the post-cutoff child became readable as owned and entered live accounting |
| Immutable first receipt | 1: the repeated PID report moved the ceiling |

The repeated-report fixture waits for the first parent reader's acknowledgement before sending again, forcing distinct
pipe receipts rather than assuming a fixed delay. Every temporary production edit was restored exactly. The local
selection excludes the existing 600 MiB frame-memory hog and never changes real system memory pressure.

Final native validation passed with
`SRTFLOW_WEB_MOTION_CHECKS=pure,normal,alpha,load-memory /usr/bin/arch -arm64 /bin/bash scripts/check-local.sh web-motion motion-placement`:
all scan guards, 101/101 selected renderer assertions, and 364/364 real App placement assertions (197 core + 167 official).
The final green log is `/tmp/g26-r7-check-local-final.log`; the earlier failed positive-render run remains separately in
`/tmp/g26-r7-check-local.log`.

## Lessons

Resource accounting cannot depend on the resource first finishing unhealthy work. Discovery and identity acquisition are
separate steps: keep retryable raw reports, but never treat an unverified PID as ownership. A teardown-only retry does not
prove live budget coverage, so its regression must latch the actual watch input while the helper still runs.

The long-term discovery, terminal-event and retry rules are in the [renderer contract](../architecture/web-motion-renderer.md#6-memory).
