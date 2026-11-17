# 2026-11-17 Upper video, covers and grades switch on the wrong export frame

## Symptom

An upper-track video, blur/mosaic cover or grade whose start/end is exactly on a project frame can miss its first or
last frame, or remain for a frame after its end. Upper video can also repeat the previous moving frame after a
crossfade. The native preview and AI look can disagree with export at those edges.
An additional caller audit found that timeline look's raw Double-to-CMTime conversion requested one native tick before
some exact frames at 30 / 60 fps. The look tolerance can hide the request error, so the request itself is checked too.

Task G23 follows the remaining raw-second windows identified in [the text/shape case](2026-11-17-overlay-export-repeats-a-frame.md).
The synthetic reproduction uses cuts and crossfades on V1, ordinary and prerendered moving video on V2, blur and mosaic
over a checkerboard, and a black/white grade over red. All windows start and end on exact frames at 24 / 30 / 60 fps.

## Root cause

- `VideoEditExportGraph`, `VideoEditCoverExport` and `VideoEditGradeExport` gated the layers with
  `between(t, fmt(start), fmt(end))`. `between` includes its end, unlike preview's open end. `fmt` rounds seconds to
  three decimal places: frame 76 at 24 fps is 3.166666… s, rounded to 3.167 s, already after the frame it should include.
  After `concat`/`xfade`, the AVTB timestamps also sit microseconds before/after the grid; even an exact-looking 7.2 s
  comparison can miss its first frame.
- Both ordinary upper video and prerendered fill + matte used `setpts=PTS+fmt(start)/TB`. Rounding/truncation and
  framesync could select the preceding frame when the main frame arrived just before the grid. `eof_action=pass` could
  remove the layer when the last output frame arrived just after the secondary stream's last timestamp.
- Preview/AI cover and grade selection still compared raw seconds. Adding start + duration can place an exact end a
  few ulps beyond the end frame (at 24 fps, frame 362's time + 1 s), leaving the effect on for another frame there too.
- `AIFrameComposer` converted its requested time with raw `CMTime(seconds:preferredTimescale:600)`, independently of
  the existing nearest-tick native request policy. A 100,000-frame sweep found 5,461 requests one tick early at each
  of 30 / 60 fps (first indices 11, 22, 44, 73, 88, 131, 146, 161); at 24 fps there were none.

## Fix

- All three export windows reuse `OverlayExportFile.enableWindow`: count edges through `FrameGrid`, switch on/off
  half a frame before the corresponding frame, with a closed start and open end.
- Both upper-video paths reuse `OverlayExportFile.placement` and its two tail frames (cloned with `tpad`), keeping the
  right source frame available across AVTB drift and EOF. Covers keep the main stream's timestamps: they are a split
  of that same frame, so their streams must not be shifted.
- `FrameGrid.contains(_:from:to:)` gives preview/AI cover and grade selection that same frame window. It is used by
  `activeFilters(at:)`, `CoverStack` and `AIFrameComposer`; the cover callers are pinned by `project-file-wiring.sh`.
- Text/shape export code is reused unchanged. The earlier case's measured error range is corrected to 4–21 px.
- Timeline look reuses `NativeSourceFrameSampler.requestedTime`, including its finite-value and nearest-1/600 rules.
  No sampler implementation is duplicated or changed; look's half-frame tolerance and composition times are unchanged.
  Video is first quantized to the containing project frame through the existing `TextAnimator.quantize` / `FrameGrid`,
  matching its cover, grade and animated overlays even for look times between frames.

The lasting rules are in [project frame rate](../architecture/project-frame-rate.md) constraint 7,
[preview transforms](../architecture/preview-free-transform.md), [covers](../architecture/cover-blur-mosaic.md) and
[filters](../architecture/filters.md).

## Verification

- `scripts/check-export-frame-rate.sh`, `checks/ExportFrameRate/LayerWindows.swift`: the real production `plan()` and
  ffmpeg at 24 / 30 / 60 fps, six one-second windows over cuts/crossfades. Every frame is checked for the first/last
  included frame and both outside neighbours. Every active frame of ordinary and fill + matte upper video is compared
  with the native preview composition (also used by AI look): a black/white edge moves 12 px per frame, with a 2 px
  tolerance, so color conversion cannot masquerade as a timing error. Preview/AI filter and cover stacks are checked
  against an independent integer-frame oracle, including the floating-point end case.
- The same scene also runs the generator with timeline look's half-frame tolerance and the actual shared request
  policy, comparing requests three quarters into every frame with exact-time preview. A window at 131/30 s exercises
  the formerly early first/end requests. An independent 100,000-frame sweep per rate (exact and fractional times)
  requires every native request to equal the rational containing-frame time;
  `project-file-wiring.sh` pins the actual `AIFrameComposer` caller to this tested policy.
- Initial reverse verification restored the seven pre-fix production files together, retaining the original five-window checks: **26 of 113
  export checks failed**, including all four bands at each project rate. At 24 fps the cover/grade first frame 76 was
  missing and end frame 100 was extra; at 30 fps frames 95/216 were missing and 125/246/315 were extra; at 60 fps
  frames 190/432 were missing and 250/492/630 were extra. Moving upper video at 30 fps repeated the previous frame at
  290, 293, 296… after the crossfade; its last frame also disappeared in ordinary and fill + matte paths at 24/60 fps.
  Preview/AI stacks kept an extra frame at 24 fps frame 386. The read-side wiring guard rejected the old selection too.
  All seven fixed production files were then restored with SHA-256 equality.
- Native-request reverse verification restored the old conversion in the shared request seam and the timeline-look
  caller: **7 of 119 checks failed**, including two request-grid sweeps and real look images a frame behind at 30 fps
  (ordinary frames 292/307, fill + matte 367/382) and 60 fps (including the last fill + matte frame 779). The moving
  edge was 12 px behind preview. The caller wiring guard failed too. Sampler and look were restored with SHA-256 equality;
  the sampler file is unchanged in the final diff.
- Relevant local validation: scan guards, export frame rate, cover export, filters, core checks and the isolated
  cover-preview attachment check. A live MCP look request and user footage are not used by this check.

## Lessons

- A layer window is a set of output frame numbers, not a floating-point interval compared independently by each pipe.
- Moving `enable` edges is insufficient for a secondary video stream: place its frames consistently and keep EOF past
  the last frame the output needs. A split of the main stream already has the right frame and must keep its timestamps.
- Check every boundary frame and every moving frame against an independent native rendering. Round-second probes and
  a one-frame tolerance cannot detect these failures.
- Use the frame-window rule on the read side too; fixing export alone can leave the preview/AI end frame wrong.
