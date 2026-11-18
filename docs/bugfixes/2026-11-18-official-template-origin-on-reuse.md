# 2026-11-18 AI project-template reuse loses the official origin

## Symptom

An official template placed and edited through AI could be reused with its `project:<UUID>`
library entry. The new clip rendered correctly, but switching UI language left its default name
and parameter labels in the previous language. Reusing the same entry through the UI retained
the official identity and localized those defaults.

## Root cause

`AIMotionRequest` always replaced `record.templateID` with the requested lookup ID. The library
already returned the complete stored source, including its `official:...` origin, but the AI
parser changed that origin to `project:...`. `OfficialWebMotionLabels` correctly only recognizes
official origins and exact default strings, so it then treated those strings as authored labels.
The UI's shared placement path did not overwrite the origin, causing the two entry points to differ.

## Fix

A template request assigns its lookup ID only when the resolved source has no existing origin.
This preserves official metadata and any earlier source identity, while a custom page with no
origin still receives its project-template ID. Explicit new page input still constructs a fresh
record with no inherited official identity. Custom names, labels and parameter values stay verbatim.
The existing optional field and file format are unchanged.

## Verification

The real App-linked placement check calls `set_motion` to reuse the edited official clip, then
checks independent clip identity, unchanged parameters, official origin and Spanish default
name/field labels. Before the fix, it exits 1 with five failures out of 352 assertions: origin,
name and the three fields. The custom nil-origin fallback assertion already passes before the fix.
Log: `/tmp/g26-c-origin-before.log`.

After the fix, `/bin/bash scripts/check-local.sh motion-placement localization-coverage` passes
all scan guards, 352 real motion assertions and 1313 localization keys. Reverse verification
temporarily restores the unconditional assignment: the full check exits 1 with the same five
failures out of 352. The exact fixed source is restored in `finally`, and all 352 assertions
pass again. Logs: `/tmp/g26-c-verified-check-local.log`, `/tmp/g26-c-origin-reverse.log` and
`/tmp/g26-c-origin-restored.log`.

## Lessons

Keep the ID used to find a source separate from the source's saved origin. Reusing or copying a
page must preserve the metadata that controls its default UI behavior. The permanent contract
is in [stored motion](../architecture/web-motion-renderer.md#15-stored-motion-and-the-ai-call-mcp-74-2026-11-17).
