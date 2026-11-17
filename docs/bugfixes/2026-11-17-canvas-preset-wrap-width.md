# 2026-11-17 A canvas change narrows preset text boxes and loses their snug width

## Symptom

Add a native motion preset with a short title on 16:9, then change the canvas to 9:16. The letters keep their pixel
size, but the wrap box narrows with the frame and can split the title, small text or counter into extra lines.
Typing afterwards no longer grows the box automatically. A 16:9 → 4:3 change can alter only the wrap width, which
`set_canvas` previously did not include in `reframed`.

## Root cause

`OverlayReframe` preserved every text's `boxWidth` as a fraction of frame width. This is right for ordinary and
manually wrapped text, but a preset's automatic snug width is derived from its typeset words. Its font and tracking
were re-expressed while that derived width was not. `MotionPresetGroups.update` then no longer recognized it as snug.
Scaling the fraction alone would also change the measured margin and lose that recognition.

The other preset dimensions already use fields covered by the reframe: font size, tracking, stroke, shadow and plate
lengths use 1080-high pixels; frame/rule widths and rectangle heights use canvas fractions. Design padding and rule
lengths are materialized into those shape dimensions. Centres remain normalized positions under the existing canvas
contract; timing, animation ratios and number content are independent of the canvas.

## Fix

- `OverlayReframe` recognizes an existing preset's old snug width, scales its style, clamps it through the existing
  model rule, then remeasures the width with `MotionPresetLayout.snugBoxWidth` on the new canvas. It measures the
  actual stored font and tracking, including when either reaches a range limit.
- Ordinary and manually set wrap widths keep their frame fraction. An item explicitly sized in the same edit is
  left as that edit set it. Each member keeps its own normalized centre; the group is not rearranged over manual
  offsets. No new persisted field or format version is needed.
- `AICanvasReframe` includes a text whose only change is its wrap width. Its note and the `set_canvas` guide explain
  the preset exception instead of promising that every `box_width` stays.
- The lasting rule is in [Preview free transform](../architecture/preview-free-transform.md),
  [Motion presets](../architecture/motion-presets.md) and [Text overlays](../architecture/text-overlays.md).

## Verification

`CanvasPresetChecks` runs through the existing MCP check entry point and uses the production preset builder,
typesetter, `CanvasReframe.keepShapes` and `AICanvasReframe.fields`:

- All three native presets: 16:9 → 9:16 → 16:9 and auto 4K → 720 × 1280 → 4K. Fitting words stay on one line, automatic
  wraps remain snug, lengths retain their share of the short side, numeric values return within floating-point
  tolerance, and identities, centres, timing, animations, number content and the rest of the timeline return unchanged.
- Typing longer words after switching still grows the snug box; ordinary/manual widths survive both directions;
  sizing explicitly in the same edit is respected.
- A width-only change at 4:3 is reported, with the exception explained. A minimum-font clamp is measured from the
  final style rather than the smaller, unclamped font.

At main base `4d2d7104`, with the original production files, 32 of 8,817 MCP checks fail, all in the new preset cases: titles become two lines,
counters three, later typing does not restore the snug width, and width-only reporting and the minimum-font case fail.
With the fix, all 8,817 pass. Local entry point: `scripts/check-local.sh mcp docs-index-drift`; the PR's full CI is
recorded in the task report.

Reverse verification restores each original production file separately: reverting `OverlayReframe` makes 32 of 8,817
checks fail again; reverting only `AICanvasReframe` makes the two width-only reporting assertions fail. Both fixes
are then restored byte for byte before the final local check.

## Lessons

A field derived from pixel geometry needs its own canvas rule even when stored as a frame fraction. Recompute
automatic geometry from final clamped values, and keep manual choices separate. A round trip alone can miss a broken
intermediate layout: also check the narrow canvas and the next edit there.
