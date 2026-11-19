# 2026-11-19 E2E deadlines, fixture isolation, and test bundle cleanup

## Symptom

PR #507's graphical shard failed while looking for “Export to.” Its MCP reference cut had already completed.
The E2E launcher also left test state in the login home, golden regeneration could absorb a delivery regression,
and failed motion placement checks left their app bundles on disk and in LaunchServices.

## Root cause

The GUI used a four-second OCR wait, sampled the row and its icon separately, and let an inspector re-render take
only 20 seconds. The MCP fixture stopped polling after 60 seconds even though its 18-frame render allows 96 seconds
in the helper alone. Deadline failures lacked the last phase and the visible controls.
Under load, the reference cut also exhausted the App's separate ten-second budget for inline source cut scanning.
The fixture required a reminder in the immediate answer even when the App correctly deferred the scan.

The App used login-home bridge and provider paths for the staged identity. The GUI inherited renderer overrides.
On current macOS, the preferences daemon can write a per-bundle plist in the real home even with a fixed fixture
home. AppKit's ignore-state argument sent new restoration state to the login session's temporary directory.

Golden regeneration replaced the baseline and skipped the mix/export workflow. Only the baseline comparison
required the delivered 960 Hz level. The bundle traps either removed files without unregistering them or retained
the entire bundle on failure.

## Fix

- Poll windows and jobs within phase-specific budgets. Locate the row and icon in one drawing. Report the last
  job or GUI operation, App output, and available window evidence when a wait fails. Relay suite output line by
  line, because a CI job that hits its own time limit kills the launcher before it can print a buffered log.
- Finish the cut-bearing source scan before placing reference media. Keep the exact `add_clips` reminder assertion.
- Share the clean E2E supervisor and block writes into the login home. Use in-process preferences, disable
  AppKit restoration for the fixture and keep the socket and provider marker beside the staged bundle.
- Run both MCP workflows for candidate generation. Decode the exported AAC and compare the 960 Hz cut with
  the original narration and flanking tones. Write a candidate and unified diff for separate review.
- Use the shared exit cleanup in the test bundle builders. Stop ongoing smoke sessions with their own cleanup
  command. Retain motion placement evidence outside the bundle after failure.

## Verification

`check-e2e.sh` runs the deadline, isolation, golden candidate and audio oracle probes and the real MCP workflows.
`check-e2e-gui.sh` renders and operates the real controls with the staged helper. A temporary six-second delay
before mounting the export row failed with the old four-second wait and passed with the new wait. Reinstating
the 60 s polling deadline, baseline overwrite, and a bypassed delivery oracle each made their focused probe fail.
Removing the scan wait also reproduced the missing source reminder in the focused MCP fixture check.
On a shared Mac, a real inspection completed in 66.4 s and the 180 s watchdog fired during active video encoding.
The watchdog is 300 s for the suite. The CI shard still has its 30-minute limit.
The first full CI run hit that shard limit just after the GUI suite started, and the buffered launcher showed nothing of it.
Restoring the buffered launcher made the live-output probe fail: no output while the suite was still running.
The login-home guard detected the real preference leak before the in-process preference fix.
`checks/test-app-cleanup.sh` exercises success and failure with a scratch bundle and rejected the original
`check-motion-placement.sh` trap when temporarily restored.
It also checks that a DMG detach failure still removes the separately staged fixture app.

## Lessons

Keep test waits in step with the [renderer limits](../architecture/web-motion-renderer.md#5-time-limits).
Check the [bridge paths](../architecture/ai-control-mcp.md) and daemon-owned state when changing test identities.
Treat candidate results as evidence for review. Follow the [bundle lifecycle](../build/build-and-packaging.md#installed-copies-on-the-developer-mac)
whenever a harness stages an app.
