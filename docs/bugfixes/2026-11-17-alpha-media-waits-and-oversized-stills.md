# 2026-11-17 Every transparent still cost ~107 MB and showed late; a straight-alpha clip held the whole preview

## Symptoms

- **Transparent stills** (MCP-76, the web-motion experiment of 2026-11-16): each transparent PNG put on an upper track was
  converted into a 60-second premultiplied ProRes 4444 in `~/Library/Caches/SrtFlow/StillClips/`, about **107 MB** each, and was
  **invisible until the background conversion finished**. A 4-second, 96-frame PNG title sequence came to about 10 GB, so PNG
  sequences were unusable as a fallback for alpha video.
- **Straight-alpha video** (left over from #430): the first preview after placing a long straight-alpha clip waited while its
  premultiplied copy was written — and not only that clip: nothing else in the preview updated until the copy was done.

## Root cause

1. **Every image becomes a 60-second, 2 fps clip (120 frames)** so it can go through the video pipeline unchanged (image clips
   can be up to 60 s; split, trim, speed, transitions, keyframes just work — [freeze frame](../architecture/freeze-frame.md) §1).
   The image is decoded once and `loop` repeats it 119 times. For opaque images the H.264 encoder stores the repeats as skip
   frames (~100 KB in all). **Transparent images are ProRes 4444 (2026-10-03), which is intra-only: the 120 identical frames were
   stored 120 times** — 0.9–3.7 MB per 1080p frame × 120 = 107–441 MB, and 3.5–5.6 s per image (measured below). "Decode once" had been
   optimised (2026-08-08); "store once" was never a question until the codec changed.
2. **A placeholder is skipped by the preview until its file lands**: AVFoundation cannot open a PNG as a video track, so the
   builder skips `needsStillConversion` clips; `convertStillClip` swaps the file in and rebuilds when ffmpeg is done. With 3–6 s
   per image the wait was visible for one still and huge for a sequence: dropping files and the "+" button converted **one image
   after another** (96 × 3 s ≈ 5 minutes until the last frame showed), while the AI's `add_clips` started **all 96 at once** (96
   ProRes encoders on 8 cores and several GB of memory).
3. **The preview build awaited the straight source's copy**: `CompositionSource.track` called `AlphaSourceCopies.url`, which
   converts on a miss (read BGRA → premultiply → write ProRes 4444, for the whole clip). The build is one task for the whole
   timeline, so one long straight clip held every rebuild until its copy existed.

## Fix

Long-term rules: [freeze frame / still pipeline](../architecture/freeze-frame.md) §4a3 and [optimized media](../architecture/optimized-media.md)
rule 8c. What changed:

- **One encoded frame, shared by 120 samples**: `StillImageClipFactory.alphaConversionArguments` encodes one frame lasting the
  whole still (output rate `1/60`); `StillFrameSharing.shareSingleFrame` (new, pure Foundation) rewrites the movie's sample table —
  `stts` 120 × 0.5 s, `stsc` one sample per chunk, `stsz` constant, `stco` 120 times the same offset — before the file lands.
  Readers see the old file exactly: same 120 frames at 2 fps (the one encoded frame is byte-identical to each of the old file's
  frames). An unknown layout throws `Unsupported`, leaves the file alone, and the factory writes every frame (`everyFrame: true`).
  Not done: one 60-second sample (ffmpeg's `trim` would drop the frame of a split image's right half; AVFoundation's
  `minFrameDuration` would be 60 s for the transition hold). No cache name bump: old 120-frame files decode the same.
- **Placeholders convert together**: `StillClipBatch.convert` (new) for `addImages`, file drops and pastes; the factory runs at
  most `ConversionSlots.width` conversions at once (4 on this 8-core Mac) for every caller, the AI included.
- **The preview doesn't wait for a premultiplied copy**: `OptimizedMediaLookup.readyAlphaCopiesOnly` (set only by the
  coordinator's `lookup(for:)`, in both modes) makes `CompositionSource.track` take the copy only if it is on disk
  (`AlphaSourceCopies.readyURL`) and otherwise insert the original at once. After each rebuild the coordinator asks
  `CompositionSource.missingAlphaCopies`, makes those copies in the background and swaps them in by the proxies' rule (only while
  stopped). Export prerender and the AI's look still wait for the copy.
- Follow-up (same day): stills made before this fix kept their 120 copies until macOS cleared the cache; since then they are
  rewritten to one frame in place at launch (`StillCacheSweep`, [still pipeline](../architecture/freeze-frame.md) 4a3).

## Verification

Measured on this M1 (8 cores, other sessions compiling — absolute times are noisy; sizes are exact). Harness: scratch program
built from the `check-video-fade.sh` source list, production factory and builder; "before" runs the old pipeline (matte +
the every-frame arguments, which are exactly the old command).

| What | Before | After |
| --- | --- | --- |
| One 1920×1080 transparent title PNG (text + glow + gradient, 0.85 MB): file until it shows, size | 3.58 s; ProRes 143.0 MB + matte 0.28 MB | 0.40 s; ProRes 1.19 MB + matte 0.28 MB |
| Worst case, a textured 1080p PNG (1.43 MB) | 5.63 s; 441.2 MB | 0.44 s; 3.68 MB |
| The MCP-76 report's own titles | ~107 MB each | about one frame (~0.9 MB) |
| 96-frame 1080p title sequence (a moving title, every frame different) | ≈ 304 s one after another, ≈ 12.4 GB (old pipeline on 4 of the frames: 3.17 s, 129.5 MB each) | 119.5 MB in all (1.24 MB a frame with its matte); 37 s one after another (0.39 s each), 31.4 s converted together |
| Straight-alpha ProRes 4444, 10 s of 1080p: preview build on a cold cache | 2.36 s (waits for the copy) | 0.005 s (original at once); copy 3.0 s in the background, swapped in while stopped |
| The same, 60 s of 1080p | 10.13 s | 0.003 s; copy 10.2 s in the background |

The load average was 27–62 during these runs (six sessions compiling), so the times are high and converting together gained
little over one at a time (31 vs 37 s); on a quiet machine the four slots run four conversions side by side. Time until a still
shows = its conversion plus one preview rebuild (120 ms debounce + build).

Checks:

- `scripts/check-still-clip-encode.sh` → `SharedFrame.swift` (new): the arguments encode one frame; after sharing ffmpeg counts
  120 frames and AVFoundation sees 60 s at 2 fps with 0.5 s frames; six export-style trims (`trim` → `setpts` → `fps=30`, incl. the
  edges 0.2–0.4 s, 55.2–60 s, 59.9–60 s) give **identical ffmpeg frame checksums** to writing every frame, and AVFoundation decodes
  identical times and pixels; the shared file is one frame + 476 bytes, the every-frame one 120×; six layouts the rewrite must
  refuse (every frame written, already shared, moov in front, cut off, a count that does not divide, the H.264 matte) are
  refused and byte-for-byte untouched; six factory conversions at once all land as shared stills. `Alpha.swift` now shares the
  frame before its pixel checks.
- `scripts/check-video-fade.sh` → `AlphaVideoNoWait.swift` (new) for the straight ProRes 4444 and HEVC fixtures on a cold cache:
  the preview build neither makes nor waits for the copy, draws the clip at once (transparent and opaque bands right, the 50 %
  band too bright: the original); `missingAlphaCopies` names exactly that source and nothing once the copy exists; then the
  preview matches the reference; the exact build (export prerender, AI look) still waits and matches. The existing #430 probes
  (`AlphaStill.swift`, `AlphaVideo.swift`: preview and export against the reference, 0–4 levels) all pass with the shared still.
- Wiring: `checks/project-file-wiring.sh` (frame sharing + fallback, conversion slots, `StillClipBatch` at the three callers and
  no `for … await convertStillClip` loop, the preview-only `readyURL`), `checks/optimized-media-wiring.sh` (only the coordinator
  sets the flag, both modes; prepare before the mode check; copies made via `AlphaSourceCopies`; swapped by
  `requestSwapIfIdle(force: true)`; `reset()` clears).

Reverse verification (each fix taken out on its own, the check went red, then restored):

- Factory back to writing every frame (the old command, no sharing): `SharedFrame.swift` 6 red — every factory still 43.7 MB
  instead of one frame (85/91) — and `checks/project-file-wiring.sh` red.
- Preview build back to awaiting the copy (the flag ignored): `AlphaVideoNoWait.swift` 4 red for the ProRes and HEVC straight
  fixtures (the build made the copy; the 50 % band was already right) and `checks/project-file-wiring.sh` red.
- Drop import back to a `for … await convertStillClip` loop: `checks/project-file-wiring.sh` red twice (no `StillClipBatch.convert`;
  the loop detector names the line).
- Coordinator without `prepareAlphaCopies`, without the swap request after a made copy, with `reset()` not clearing, or the flag
  set in `VideoEditPrerender`: `checks/optimized-media-wiring.sh` red each time (exit 1).

Restored: `scripts/check-still-clip-encode.sh` 91/91, `scripts/check-video-fade.sh` 216/216 (no SKIP on this Mac), all scan guards
green.

## Lessons

- **An intra-only codec stores every repeated frame.** "Decode once, repeat with a filter" is not "store once"; repetition that
  must stay cheap belongs in the container's sample table. Look at the bytes on disk, not only at the encode time.
- **Repeat as samples, not as one long sample**: a reader that trims by timestamps (ffmpeg `trim`) or asks for the frame
  duration (AVFoundation `minFrameDuration`) treats one 60-second frame very differently from 120 half-second ones.
- **A per-clip wait inside a whole-timeline build is a whole-preview wait.** Preview-only substitutes follow one rule — use it
  if ready, show the original meanwhile, swap while stopped (optimized media had it already) — and only the paths that must
  match the export may wait.
- **Batch work started by one gesture should neither queue in a line nor start all at once**: convert together, bounded in the
  one place every caller goes through.
