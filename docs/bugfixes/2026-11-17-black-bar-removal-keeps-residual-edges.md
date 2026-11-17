# 2026-11-17 Black-bar removal disagreed with look and left thin edges

## Symptom

MCP-5: look reported baked-in black bars, while remove_black_bars reported a smaller bottom bar or no bars. A second timeline
look still saw a thin black strip. A fill without removal kept the source's bars without a notice.

The synthetic reproduction uses 23 / 31-pixel top / bottom bars in a 1890 by 1080 source and a file with one barred shot followed
by a full-frame shot. A source_out trim and removal in the same call analyzed the old, longer window and reported no bars.

## Root cause

- Removal decoded a 320-pixel thumbnail and then reduced it to 256; look decoded a different thumbnail, reduced it for Vision,
  and then made the 256-pixel luma. Different boundary resampling changed the measured width by a whole analysis row.
- A partially black boundary row fails the fully-black threshold. Cropping exactly the count of fully-black rows leaves that
  mixed row behind, several source pixels at the old analysis resolution.
- AIClipTools planned framing before applying the call's source window to its probe subject. The 0.25-second decode tolerance
  could also select a nearby frame outside a short window. Sampling an existing trimmed clip was already supported; the missing
  case was changing the source window and framing together.
- fit=fill had no black-bar probe unless removal was explicitly requested.

## Fix

Look and removal measure the decoded frame at the same 1280-pixel long side, independently of Vision's thumbnail. The generic
256-pixel luma default stays unchanged for other consumers. Removal includes one analysis pixel beyond a detected boundary;
the reported measurement stays separate from the actual crop. No allowance is added to an absent or uncertain edge.

The planner uses the edit's existing source-window validation before probing, and removal requests exact-frame decoding.
Per-edge minimum voting remains conservative across shots. A fill-only request reports source bars and a warning without
automatically removing them. All changes stay inside the existing plan / commit and one-step undo path.

## Verification

- Before the production fix, scripts/check-parameter-limits.sh executed 75 assertions and failed six: complete thin-bar crop,
  agreement with look's bottom measurement, no residual timeline bars, the fill-only notice, and detection / rendering after
  a simultaneous source-window edit. The first cold build was interrupted by a concurrently modified unrelated input; that
  build failure is not counted as regression evidence.
- BlackBarAppChecks uses real AIClipTools and AILookTool calls in the isolated check App. It also checks one undo restores the
  source window and framing, a mixed-shot window keeps the minimum rather than cropping a full-frame shot, and a notice does
  not silently remove bars.
- BlackBarChecks in scripts/check-mcp.sh covers the one-pixel allowance, including zero and uncertain edges.
- With the fix, scripts/check-parameter-limits.sh passed all 75 assertions. Literal reverse verification temporarily restored
  the old thumbnail / crop / source-window / notice behavior while retaining the new return type: the same six runtime
  assertions failed again, with exit code 1. The three temporarily changed production files were then restored byte for byte.

## Lessons

Use the same image and measurement resolution for a diagnosis and its corrective tool. A source-window edit must be prepared
before any image analysis based on that window. Pixel-boundary uncertainty belongs in the corrective crop, with its scope
bounded explicitly; do not change conservative voting to a maximum and crop content from another shot.

The lasting contract and manual release check are in [Preview transforms](../architecture/preview-free-transform.md#automatic-black-bar-removal-2026-11-17).
