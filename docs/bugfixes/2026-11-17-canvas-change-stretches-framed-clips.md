# 2026-11-17 Changing the canvas silently stretches clips framed for the old shape

## Symptom

Found by walking the editing knowledge cards in SkyCut 0.18.66 over MCP (P5 walkthrough, to-do 4). On a 9:16 canvas,
`edit_clip clip_id=553d35e6 fit=fill focus_x=0.62` filled the frame with a 16:9 source. Then `set_canvas ratio=16:9` answered
`{"fps":24,"height":1080,"ratio":"16:9","width":1920}` with no warning, `get_timeline` showed `"stretched": true`, scale 3.16, and
`look` showed the face squashed wide. `edit_clip fit=fill` repaired it.

The canvas menu in the editor goes through the same `setCanvasRatio`, so it stretched the same way; so did an auto canvas that turns
another shape when a different clip becomes the first on V1 (delete, move, file swap). Clips in the default layout were fine.

## Root cause

A clip's explicit framing (`ClipPlacement`: centre, width and height) and its position / size keyframes are fractions of the canvas,
width of the width and height of the height. Nothing re-expressed them when the canvas changed shape, so the same fractions mapped to a
frame of another shape: the 9:16 fill (1.04 × 1.00 of a 1080 × 1920 canvas) became 1.04 × 1.00 of 1920 × 1080, 3.16 times wider than
the cropped picture. Only the default layout (placement nil) is computed from the canvas each time, which is why default clips kept
their shape and the guide's "clips keep their layout" looked true.

## Fix

- `CanvasReframe.keepShapes` (new, `Sources/SrtFlow/CanvasReframe.swift`), run at the end of `VideoEditProject.perform` after the
  magnet: when an edit changes the canvas's shape, every picture clip whose framing that edit did not set keeps its centre and its size
  relative to the default layout, per axis — the x, y and scale that get_timeline and the inspector show. Size keyframes get the same
  factors. Nothing is re-cropped; switching back restores the numbers exactly. Every way of changing the canvas passes through `perform`.
- Chosen over re-filling: the default layout already keeps a clip's whole picture on a new canvas (contain, letterbox) and SkyCut
  never crops on its own; a re-fill would have to guess the window and can bring back what a crop removed (black bars, a watermark).
- `set_canvas` says what happened (`AICanvasReframe`): `reframed` (clips whose numbers were redone) and `no_longer_fill` (picture
  clips that covered the old frame and not this one) with a note to use edit_clips fit=fill; the guide's set_canvas `shape` section
  says the same.
- `VideoEditProject.swift` may only shrink: `looksLikeAudio`'s extension list moved to `MediaFileTypes.isAudio` (1202 lines).
- Rule written down in [Preview free transform](../architecture/preview-free-transform.md) ("A canvas change keeps every clip's
  shape"), with a manual regression item for the editor's canvas menu.

## Verification

- `scripts/check-mcp.sh` → `checks/MCP/CanvasReframeChecks.swift` with the production functions (`AIFrameFit.fill` with the
  walkthrough's focus, `CanvasReframe.keepShapes`, `AIFrameFit.describe`, `AICanvasReframe.fields`): after 16:9 the clip is not
  stretched, x / y / scale read the same, the crop is the same, it no longer fills and the reply lists it in both fields; back to 9:16
  restores the placement exactly; a corner picture stays in its corner at the same scale; size keyframes keep the picture's shape;
  default-layout clips are untouched; a clip the same edit frames is left alone; an auto canvas that turns tall after deleting the
  first clip keeps an overlay's shape; a same-shape change reframes nothing; fps alone reports nothing.
- `checks/MCP/canvas-wiring.sh`: perform runs `CanvasReframe.keepShapes` once, after `MainMagnet.settle`; set_canvas builds its reply
  with `AICanvasReframe.fields`.
- **Reverse verification** (2026-11-17): with `keepShapes` returning early, 12 of the 23 CanvasReframeChecks fail (stretched, scale,
  the reply, the corner picture, the keyframes, the auto canvas); removing the call from perform or the reply from set_canvas turns
  the wiring scan red. Restored: all pass.

## Lessons

- Values stored relative to something that can change (the canvas) need a rule for when it changes; "the default is recomputed"
  only covers the default.
- When picking between two fixes, prefer the one that matches how the same thing already behaves (here: the default layout on a new
  canvas) and that never shows what the user removed; tell the AI the consequences instead of guessing for it.
