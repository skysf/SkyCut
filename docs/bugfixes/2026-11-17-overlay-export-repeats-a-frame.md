# 2026-11-17 Exported text and shape animations repeat a frame now and then

## Symptom

Found by task G4 (motion presets) while comparing preview and export frame by frame: in an exported film an animated text
or shape now and then shows the same picture on two frames in a row and catches up on the next one. The "frame reveal"
preset at 30 fps (frame from 0.5 s, title from 0.6 s): frames 24 and 25 identical, frame 26 caught up, for the title and
the frame alike; frames 15–20 lined up. The preview did not do it. In a moving title it reads as a stutter.

Measuring every frame (`scripts/check-text-render.sh` group 20) showed more than the repeat, all of it "an exported frame
that is not the frame for its own time":

- repeats at 24, 30 and 60 fps when a section starts on the frame grid (title from 0.5 s: frames 25 and 28 at 24 fps;
  25, 31, 35 at 30 fps; 50, 62, 70 at 60 fps);
- the whole entrance a frame late when it starts more than half a frame past the grid (a shape from 3.36 s, every fps);
- after crossfades on the main track, every third frame repeated (30 fps, a title from 9.5 s: frames 290, 293 … 305);
- a still square starting exactly on a frame (7.2 s, 30 and 60 fps, after cuts) missing its first frame;
- the middle still of a wiping title drawn before the wipe had finished (30 fps: the plate's right edge, 4 px of 318,
  missing for the whole middle).

## Root cause

An animated overlay is exported as sections (entrance PNG sequence / middle still / exit PNG sequence, `OverlayExportFile`).
Four things decided which picture an output frame got, and each could be off by one frame:

1. **Drawing times floored with floating-point noise.** Frame k of a section was drawn for
   `TextAnimator.quantize(from + k / fps)`, a plain `floor(time × fps) / fps`. `0.5 + 10 / 30` is 0.8333333333333333 and
   times 30 that is 24.999999999999996, so frame k = 10 was drawn as frame 24 again: the repeat G4 saw. Even exact frame
   times break it: 123 / 30 = 4.1 and 4.1 × 30 = 122.99999999999999. The preview and the AI's look use the same
   `quantize`, so stopped on such a frame they drew the overlays a frame behind too.
2. **Placement rounded the other way.** The sequence was placed with `-itsoffset <from>`; ffmpeg rounds that to the
   sequence's 1/fps grid to the nearest frame, while the drawing used the frame below. A start more than half a frame
   past the grid (3.36 s × 30 = 100.8) put frame 100's picture on output frame 101, and so on through the section.
3. **Output frames are not exactly on the grid.** After `concat` and `xfade` the main video's timestamps are AVTB
   (microseconds) and drift: at 24 fps up to 3 µs late after several cuts, at 30 fps up to 0.67 µs early after a
   crossfade. `overlay` picks the last overlay frame at or before the output frame; an overlay frame exactly on the grid
   (rounded to the nearest microsecond) is after an output frame that came 0.67 µs early, so the one before was used —
   every third frame at 30 fps, where the grid times have a .67 µs fraction.
4. **Section edges compared in seconds.** `enable='gte(t,start)*lt(t,end)'` with t = 7200000 × 1e-6 = 7.199999999999999
   for the output frame at 7.2 s: a section starting on the grid lost its first frame (or an end on the grid got one more).

Plus, for text only: the middle still was drawn for `quantize(middleStart)`, the frame **below** the end of the entrance,
so a linear entrance (wipe) was a few percent short for the whole middle.

Why it hid so long: frame-count and seam checks (group 19) measured brightness on plateaus or one probe frame per second;
the export checks' overlays start on round seconds, often on a single main clip (no microsecond drift), and the existing
"preview = export" checks allowed ±1 frame. A pure-ffmpeg reproduction (an overlay sequence that writes its own frame
number as a barcode, the production graph shape with concat and xfade, ten sections over about 17 s) showed 24–56 wrong
frames per run at 24, 25, 30 and 60 fps with the old placement, 0 with the new one.

## Fix

One rule in one place — every frame of an overlay section is counted in output frame numbers (`OverlayExportFile`):

- `FrameGrid` (new, `Sources/SrtFlowCore/FrameGrid.swift`): time ↔ frame number with a 1e-6-frame tolerance for
  floating-point noise. `TextAnimator.quantize` now uses it, so the preview, the AI's look and the export agree on
  exact frame times.
- `OverlayExportFile.frameTime(k, sectionStart:grid:)`: the k-th PNG of a section is drawn for the section's k-th output
  frame (first frame at or after the start), exactly on the grid. `TextOverlayExport` and `ShapeOverlayExport` draw by it;
  stills (a still overlay, the middle of an animated one) are drawn for the section's first output frame.
- `OverlayExportFile.placement`: no more `-itsoffset`; frame N of every stream (still, sequence, loop) gets
  `settb=1/(2·fps),setpts=2*N±(2·first−1)` — half a frame before its output frame, integers only. Microsecond drift either
  way can no longer flip which PNG an output frame picks.
- `OverlayExportFile.enableWindow`: on from half a frame before the section's first output frame, off from half a frame
  before the first frame at or after its end (still left-closed, right-open).

The PNG counts and the "two extra frames at the end" stay as they were (the sequence starts at the section's first output
frame, so `ceil(span × fps) + 2` frames reach more than a frame past the end). The call site in `VideoEditExportGraph`
did not change. The long-term rules are in [画面文字](../architecture/text-overlays.md)「Frames on the grid」,
[画面上的形状](../architecture/shapes.md) section 3 and [工程帧率](../architecture/project-frame-rate.md) constraint 7.

## Verification

- New `scripts/check-text-render.sh` group 20 (`checks/TextRender/MovingFrames.swift`): two wiping titles (white plate,
  box hugging the words) from 0.5 s and 9.5 s, a wiping rectangle from 3.36 s, a still square from 7.2 s, over seven main
  clips with cuts and two crossfades, exported at 24 / 30 / 60 fps through the real `VideoEditExportGraph.plan()` and
  ffmpeg. Every frame's lit width in three strips must equal what the preview's renderers draw for that frame's own time
  (±2 px; a frame off by one is 4–21 px), and no frame may repeat the one before while it moves. Plus the `FrameGrid`
  contract at 24 / 25 / 30 / 60 fps.
- Before the fix (main at 5abca0d): 14 of 24 export checks red, the frames listed under Symptom. After: 37 / 37, every
  frame within 1 px (0 px on all but 9 of about 6,100 strip-frames).
- Reverse verification, one part of the fix taken out at a time (each alone turns the guard red, everything else green):
  `quantize` back to a plain floor → 30 fps frame 123 and 60 fps frames 245–246 late; drawing `from + k / fps` → the
  off-grid shape a frame late at every fps and the titles' exits late at 30 fps; overlay frames exactly on the grid →
  every third frame repeated after the crossfades (30 fps, 290 … 305); `enable` in raw seconds → the square's first
  frame missing (30 fps frame 216, 60 fps frame 432); the middle still at the frame below → both titles 4 px short
  for the whole middle at 30 fps; `FrameGrid` without its tolerance → the grid checks and the export red at 25 / 30 / 60.
- The other export checks of overlays still pass (shape render, export profile: the still PNG is decoded once; seam
  frames, group 19).

## Lessons

- A frame number is never `floor(time × fps)`: exact frame times and sums of them land a hair below the integer.
  Count in frames (`FrameGrid`), and convert to seconds once.
- Two sides that must meet on a frame (drawing and placing, an `enable` edge and an output frame) must count from the same
  integer, not each round a time its own way (`-itsoffset` rounded to nearest, the drawing floored).
- Never put anything ffmpeg compares with an output frame exactly on the grid: after `concat` / `xfade` the output frames
  drift microseconds either way. Half a frame off the grid is safe in both directions.
- "Preview = export" checks with a ±1 frame tolerance cannot see a repeated frame. Measure every frame against the
  renderer at that frame's own time, with motion large enough per frame (here ≥ 4 px) to tell neighbours apart.
