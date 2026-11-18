# 2026-11-18 Automatic canvas changes suppress linked moves and deletions

## Symptom

With auto canvas and linkage enabled, delete the first landscape V1 clip and ripple the following portrait clip to zero.
Its title, shape and explicitly framed V2 clip remain at their old times, and a title over the deleted host survives.
The linkage report incorrectly says nothing moved or was deleted.

## Root cause

`VideoEditProject.perform` ran `CanvasReframe.keepShapes` before `TimelineLinkage.follow`. Reframing changed placement,
text style and shape geometry. Linkage's rule 5 compares complete values to avoid moving objects the edit already handled;
these internal geometry changes therefore made untouched attachments look user-edited. Separate geometry-only tests
omitted linkage and could not detect this interaction.

## Fix

Settle the main magnet, follow linkage, then reframe before assigning track colors. Linkage changes timing, leaving the
framing fields used by `CanvasReframe` and `OverlayReframe` intact, so both timing and geometry contracts hold.
No linkage equality rules or user-edited-object exemptions change.

## Verification

- Reproduced on main `afc6355e` through the real App `perform` in `CanvasLinkageChecks`: six failing assertions across
  magnet on/off (attachment times, deleted title, linkage report). The fixture uses synthetic portrait metadata without rendering it.
- `checks/MCP/canvas-wiring.sh` fails with the original order. Reverse verification restores the old order temporarily,
  confirms its nonzero failure, then restores the fix.
- `scripts/check-local.sh parameter-limits mcp timeline-snap` covers the real completion/undo paths and existing geometry
  and linkage contracts. The new checks include linkage off, shape/text/V2 geometry preservation and one-step undo/redo.
- Real editor gestures and preview/export pixels are not claimed by these model/commit checks; the existing manual canvas
  and linkage regression lists still apply before a release.

## Lessons

An internal normalization step can invalidate another step's change detection even when both functions pass in isolation.
Test final state and reports through the actual commit path. The lasting order is documented in
[linkage](../architecture/timeline-linkage.md) and [canvas reframing](../architecture/preview-free-transform.md).
