# 2026-11-18 Native preset reapplication loses numeric titles

## Symptom

A number converted to Frame Reveal or Focus Pull could become blank or reveal ignored backing words when the same preset was
reapplied, another preset was selected, or `small_text` triggered an implicit reapplication. Partial number edits could reset
unmentioned roll fields. Selecting a small member and converting that group to Title + Counter incorrectly demanded `number.to`
even though its title already carried the full number.

## Root cause

`MotionPresetGroups.spec(from:)` recovered a number only from a dedicated counter member. A Frame Reveal / Focus Pull numeric
title instead stores it on the anchor. The reconstruction also read the anchor's backing `text`, although a non-nil number is
the displayed content and the backing words are ignored. The builder intentionally uses a number as the title only when the
specification has no title words, so recovering only the number would still expose nonempty backing words.

`AIMotionPresetEdit.reapply` checked a dedicated counter or the addressed text for an existing number. When the addressed text
was a small member, it overlooked the anchor's number and refused the operation before shared reconstruction ran.

## Fix

Recover the dedicated counter's complete `NumberRoll`, falling back to the anchor's roll. Normalize a numeric anchor's title
words to empty, matching the existing lone-number conversion. AI preflight resolves the same group's anchor even when a small
member was addressed. Preset construction, partial-number merging, same-call style/animation precedence and undo remain shared.

## Verification

`checks/MCP/MotionPresetNumberChecks.swift` drives the actual `AIOverlayEdits.text` path with Count and Odometer rolls. It compares
every roll field across same/cross-preset changes, repeated and implicit reapplication, hidden nonempty backing words, partial
suffix changes, small-member counter conversion and explicit animations. It also retains ordinary counter behavior and verifies
that a missing required title refuses atomically. Requested preset kinds, small-line words/placement and both directions of a
Frame Reveal / Focus Pull round trip are asserted, preventing a no-op implementation from passing preservation checks.

Native arm64, one compiler at a time:

| Run | Actual result | Log |
| --- | --- | --- |
| Unfixed production with the initial numeric regression set | 256 of 9,758 MCP assertions failed | `/tmp/g26-r3-before-fix.log` |
| Fixed production with the complete regression set | All 10,218 passed | `/tmp/g26-r3-fixed.log` |
| Remove only numeric-anchor roll recovery | 204 of 9,814 failed | `/tmp/g26-r3-reverse-recovery.log` |
| Remove only numeric-anchor backing-word normalization | 150 of 10,218 failed | `/tmp/g26-r3-reverse-normalization.log` |
| Remove only the anchor fallback in AI number preflight | 8 of 10,194 failed | `/tmp/g26-r3-reverse-precheck.log` |
| Restored `scripts/check-local.sh mcp` | All scan guards and all 10,218 MCP assertions passed | `/tmp/g26-r3-final-local.log` |

The initial red run predates the additional requested-kind and small-line positive assertions; the complete set ran in every
fixed/reverse run. Different assertion totals in failing runs reflect later repeated operations refusing after the content was
lost. Every reverse restored the exact production bytes in `finally`. Actual MCP assertion summaries and the targeted errors
were inspected for all three reversals; no compile or scan failure was counted as proof.

Final validation passed `/bin/bash scripts/check-local.sh mcp`, including all repository scan guards. The first sandboxed attempt
was refused by macOS's nested SwiftPM manifest sandbox; the same checks ran with narrowly scoped command escalation.

## Lessons

A preset specification must recover the displayed content source, not just the backing words or the member the caller selected.
Copy structured values whole before applying partial changes. The permanent contract is in
[motion presets](../architecture/motion-presets.md#二只能这样做).
