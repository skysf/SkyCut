# 2026-11-19 main stopped building: two merged PRs each added a `sound` to inspect_video

## Symptom

After #476 (the sound strip under look / inspect_video sheets) and #481 (second-tier sound checks in the delivery report)
were both merged on 2026-11-18, main stopped building: `AIInspectionTool.swift:154: invalid redeclaration of 'sound'`, and
`scripts/check-mcp.sh --scans-only` failed ("inspect_video must draw the frames its report measured"). Main's CI shard 1
failed, and every open PR's CI would fail the same way.

## Root cause

Each PR was green against the main it was tested on; neither saw the other. In `AIInspectionTool.inspect`, #481 added
`let sound = try await AIDeliverySound.prepare(…)` (passed on as `sound: sound))` to `AIDeliveryChecks.run`), and #476 added
`let sound = … AISoundStripMeasure.inspection(…)` further down in the same scope (handed to `AILookTool.finish(…, sound: sound)`).
#476's guard (`checks/MCP/look-sound-wiring.sh`) counted the text `sound: sound)` expecting exactly one — #481's line matched it
too.

## Fix

The strip under the evidence sheet is now `strip` (`AILookTool.finish(…, sound: strip)`), and the guard counts `sound: strip)`.
No behaviour changes.

## Verification

- `swift build --arch arm64 --product SrtFlow` succeeds; `scripts/check-mcp.sh --scans-only` is green.
- Before the fix (main at `f82b2f4d`) both were red; CI runs the rest (`scripts/check-video-inspection.sh`, `check-look-jobs.sh`).

## Lessons

- Two PRs merged minutes apart can clash although each was green: when main moved after a PR's CI ran, merge main in and
  check at least the build and the scan guards before merging (AGENTS.md "合并与分支").
- A guard that counts a short text (`sound: sound)`) can be matched by someone else's line: count a name that only the thing
  you mean can have.
