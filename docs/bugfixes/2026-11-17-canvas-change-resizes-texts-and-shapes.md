# 2026-11-17 Changing the canvas stretches rectangles and resizes texts and shapes out of proportion

## Symptom

Left over from the canvas fix (#445, G15 report follow-up 6: "texts, shapes and subtitle layouts on a canvas change were not
examined"; no user report). Measured with the production geometry on a 16:9 project switched to 9:16 (`set_canvas ratio=9:16`, the
editor's canvas menu, or an auto canvas following a new first clip):

- A 0.3 × 0.22 rectangle (576 × 238 px, 2.4:1) became 324 × 422 px (0.8:1): **stretched** by the same 3.16 the clips had. Blur and
  mosaic covers the same.
- A ring of 384 px with an 8 px stroke became 216 px with a 14 px stroke: the circle shrank to 0.56× while its stroke grew 1.78×. A
  line kept its angle but shrank the same way while its stroke thickened.
- Every text grew 1.78× in pixels (font 96 → 171 px) while the frame got 0.56× as wide and the wrap width (80% of the frame) went
  from 1536 to 864 px: a one-line title became a block of several lines — the "9:16 numbers are 1.78× too big" of the style cards
  ([case](2026-09-29-recipe-sizes-too-big-on-vertical.md)), produced by the switch itself. The reverse switch made texts 0.56× as big.

set_canvas said nothing about texts or shapes.

## Root cause

Texts and shapes store their sizes against two different edges of the canvas, and nothing re-expressed them when its shape changed:

- pixels of a 1080-**high** frame: font size, stroke, shadow, plate, letter spacing; a shape's line width and cover strength
  (rendered × frame height / 1080);
- fractions of the frame's **width**: a shape's width (a line's length, a circle's diameter); fractions of its **height**: a
  rectangle's height.

On a canvas of the same shape (720p ↔ 4K) all of these keep their proportions, which is what the 1080p base was designed for
([画面文字](../architecture/text-overlays.md)「尺寸都以 1080p 为基准」). On another shape each edge scales differently, so the parts
of one overlay drift apart. #445 fixed the same thing for clips' placements and left texts and shapes out of scope.

## Fix

- `OverlayReframe` (new, `Sources/SrtFlow/OverlayReframe.swift`), called by `CanvasReframe.keepShapes` (end of `perform`, after the
  magnet), so every path that changes the canvas's shape gets it: every text and shape the edit did not size itself keeps its centre
  (x, y on the frame) and its size against the frame's **short side** — all its lengths are multiplied by one factor, so nothing is
  stretched and its parts keep their proportions. Every preset frame is 1080 on its short side, so a preset switch keeps the pixels
  (16:9 → 9:16: font 96 → 54, rectangle 0.3 × 0.22 → 0.533 × 0.124, line width 6 → 3.375). Switching back restores the numbers
  (unless a text value hits its range). A text's wrap width keeps its share of the frame's width: like x and y it is where the text
  sits, not the size of the letters, and a line that no longer fits wraps.
- Why the short side: it is the only size that makes a switch and its reverse cancel out while never stretching (each edge alone
  makes one direction 1.78× too big, as above), and it lands near what the style cards measured for 9:16 (big text 90–110 on
  16:9 becomes 51–62; the cards say 44–52 there, the HUD text 28–36 becomes 16–20, exactly the cards' 9:16 range). Fitting the old
  frame inside the new one instead would shrink everything again on the way back.
- `set_canvas` lists texts and shapes in `reframed` and adds `off_frame` (texts and shapes that sat inside the old frame and stick
  out of the new one, `AICanvasReframe`), with a note; the guide's set_canvas `shape` section says the same.
- Rule written down in [Preview free transform](../architecture/preview-free-transform.md) ("A canvas change keeps every clip's
  shape"), linked from [画面文字](../architecture/text-overlays.md) and [画面上的形状](../architecture/shapes.md).

## Verification

- `scripts/check-mcp.sh` → `checks/MCP/CanvasOverlayChecks.swift`, production calls (`CanvasReframe.keepShapes`,
  `TextOverlay.pixelScale`, `ShapeAnnotation.frame(in:)` / `strokeWidth(in:)`, `TextRenderer.layoutFrame`, `AICanvasReframe.fields`):
  on 16:9 → 9:16 the title's letters, stroke, plate, shadow and letter spacing keep their pixels and it keeps x, y and wrap share; the
  rectangle, ring, line and blur keep their pixels, strokes and strength; back to 16:9 every number returns; 16:9 → 4:3 leaves texts
  alone; auto 4K → phone keeps the share of the short side; a text the edit sized itself is left alone; a same-shape change touches
  nothing; the reply lists the reframed items and `off_frame` (a 1152 px bar, an 8-line column going 9:16 → 16:9) and nothing else.
- **Reverse verification** (2026-11-17): with `keepShapes` not calling `OverlayReframe`, 19 of the 8,208 MCP checks fail (every size,
  stroke and the reply); with the reply ignoring texts and shapes, 4 fail. Restored: all pass.

## Lessons

- A "unit" that is defined against one edge of the frame (1080 high) is only shape-independent within one aspect ratio; any stored
  length needs a rule for when the frame changes shape, and every part of one thing must follow the same factor.
- When a choice must survive a round trip (switch and switch back), check the reverse direction before picking the factor.

## Follow-up: automatic preset wraps

The wrap-fraction rule above still applies to ordinary and manually wrapped text. A native preset's automatic snug
width is now remeasured after scaling and clamping the style so it continues to hug the words; see the
[preset wrap case](2026-11-17-canvas-preset-wrap-width.md).
