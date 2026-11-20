# 2026-11-20 Play after a hover waited for the playhead's frame to be decoded again

## Symptom

Pressing Play (Space) while the pointer hovered the timeline, or right after it left, played in step but late. In
original mode on a long-GOP 4K source, the wait was 0.59 s to sound and 0.61 s to picture (M1, median), and 0.58 /
0.61 s on the hosted runner. Play with the playhead placed and nothing hovered started in 20–70 ms.

## Root cause

The hover preview scrubbed the editing player itself. `PlayerClock.peek` cancelled the playhead's placement and seeked
the one AVPlayer to the pointer's frame. A hover's end, and Play during a hover, had to place and prime the picture at
the playhead again. A zero-tolerance seek three seconds into an eight-second GOP decodes from the keyframe: about
0.6 s for the 4K fixture. Since 2026-11-19 Play held the sound until then, so the start was in step but waited.

One player cannot keep the playhead's frame and show another. Probe of 2026-11-20 on the same fixture: with the hover
on a second player, Play on the untouched editing player started 41 ms after the hover; placing the editing player
back took 0.81 s.

## Fix

The user approved a second player for the hover on 2026-11-20 (「做，多 50 MB 可以 (Recommended)」).

- `HoverPreview` owns the hover's own AVPlayer. Its item is built on the preview item's asset and video composition.
  `PlayerClock.peek` sends the hover there whenever the engine drives playback. The editing player stays placed and
  primed at the playhead. Setting `peekTime` to nil hides the hover, from `endPeek`, Play, a seek, a new item or a
  teardown.
- `HoverPreviewSurface` draws the hover picture over the preview:
  - grade and covers at the hover's time, through the preview's own classes: `PlayerLayerView` with
    `FilterStackAttachment`, and `CoverHostView`;
  - shown once the hover's first seek has landed, so no earlier frame flashes;
  - hidden directly (`alphaValue`) in the same turn as the hover's end;
  - a clear background, so an undrawn frame shows the editing picture rather than black.
- The hover item is dropped 3 s after a hover ends, so the memory is held only around a hover. The preview ratchet
  gates it as a new item of its own, `<scenario>.hover.peakMB`; every other item is unchanged.

## Verification

- **Gate, M1:** `peek-play` (Play while hovering) and the new `peek-end-play` (Play right after the hover) went from
  0.59 / 0.61 s median to sound and picture to 17–22 / 40–49 ms. They stay in step: start skew −2 to −15 ms, no
  preroll after Play.
- **Gate rules:** both scenarios now have the common budgets (130 / 180 ms median) and no preroll after Play.
  `test_compare.py` pins the recorded old launches as red, on medians, whole launches and the preroll.
- **Clock check:** `scripts/check-player-clock.sh` (`HoverChecks.swift`, a real AVPlayer on a long-GOP clip) checks:
  - the editing picture does not move while hovering;
  - Play during and right after a hover starts at once, with no native jump;
  - the hover picture is hidden by Play and by the hover's end;
  - a new preview item ends the hover, and the next hover builds on it;
  - the hover item is released after 3 s.

  With the hover sent back to the editing player, 11 of these checks failed.
- **Pictures:** `scripts/check-cover-preview-attach.sh` compares the hover view with the editing picture's layers
  (grade and blur, mosaic, two covers after being hidden). It went red with the hover's covers left ungraded.
- **Guard:** `checks/playback-start-wiring.sh` pins the routing in `peek`, the hide on `peekTime` nil, the hover end
  that leaves the editing player alone and the hover item built on the preview item.
- **Memory, M1:** the first hover over 4K costs 43 MB, over 1080p 12 MB. On the ratchet's busy scenario, 18 / 48 MB
  above the footprint before hovering, against 10 / 1 MB for the old hover. The rule and the hosted numbers are in
  [preview perf ratchet, section 15](../architecture/preview-perf-ratchet.md).

## Lessons

- **A preview that serves both a playhead and a pointer needs two pictures.** Sharing one player made every hover
  cost the next Play a full decode.
- **Build the second picture from the first one's item and drawing classes,** so grade, covers, upper tracks and
  web-motion layers cannot drift apart.
- **Price memory per state.** The approval was for memory while hovering, so the ratchet gates that state as an item
  of its own and leaves the others' "only goes down" intact.
- **Hide it directly, in the same turn** as the state that ends a hover, rather than on SwiftUI's next pass, so the
  picture underneath is what shows when Play starts it.
- The rules live in [playback start, "Hover"](../architecture/playback-start.md#hover).
