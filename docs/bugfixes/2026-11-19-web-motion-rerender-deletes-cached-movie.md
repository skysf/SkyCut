# 2026-11-19 A same-fingerprint web-motion re-render could delete the movie a clip was using

## Symptom

The inspector's Re-render can be clicked without changing anything, and the cache renders a movie again whenever its
receipt is missing. Both render to the same file name (`motion-<fingerprint>.mov`) that the clip, its undo history and the
project already use. Once the helper passed, SkyCut removed that movie and then moved the new one in. When the move failed —
a full, slow or unplugged drive, a folder that changed — the movie was gone while the clip and every undo step still
pointed at it. Even when the move worked, a Save As running on the project's writer queue between the two steps found no
movie and carried nothing beside the new project. A render whose system identity no longer matched (checked only after the
move) had already replaced the movie before it was refused. The existing failure check made the page itself fail, so it
never reached this step. Found by review CXR2 (R13).

## Root cause

- `WebMotionRenderer.render` installed a passed movie with `removeItem` then `moveItem`: two steps with nothing at the path
  in between, and no way back if the second failed.
- `WebMotionCache.render` compared the renderer's system identity and wrote the receipt only after the movie was in place.
- The inspector always rendered with `force: true`, so an unchanged Re-render replaced a movie whose checked receipt said it
  was already exactly that render.
- These file operations ran in Swift's cooperative pool, beside a folder that may be on a slow drive.

## Fix

- `WebMotionCacheFiles` (new): one serial queue for the cache folder's files, and the install — one `rename(2)` of the
  staged movie over the old one, so a reader sees the old movie or the new one, never none, and a failed install leaves the
  old one where it was.
- `WebMotionRenderer.render(_:watch:verify:)`: after the helper's checks pass, `verify` runs on that queue before anything
  is replaced; then the install. The staged movie is removed on every path that does not install it.
- `WebMotionCache.render`: the system-identity check and the receipt write are its `verify`, so a mismatch or an unwritable
  receipt keeps the previous movie and receipt. Its receipt reads, folder creation and sidecars run on the same queue.
- The inspector's Re-render no longer forces: an unchanged source reuses its checked movie (same fingerprint, same frames)
  and starts no helper. `force` stays for the checks that compare two real renders; `WebMotionActions.place` lost its
  unused `force`.
- Show Page in Finder writes its sidecars on the same queue.

## Verification

`scripts/check-motion-placement.sh`, core group (`CacheCommit.swift`), on a real placed clip:

- unchanged Re-render: succeeds, the marker helper never starts, same movie byte for byte;
- receipt gone + install failing after the helper passed (`WebMotionCacheFiles.beforeInstallForChecks` throws): the render
  fails with "could not be moved into place", the clip's movie is byte-identical and still probes as the motion, no staged file;
- receipt gone + a fake helper that passes every check with another system identity and stages a non-movie: refused, movie
  and receipt untouched, no staged file;
- receipt gone + a Save As (`VideoEditProjectIO.save`, the production carry) run right before the install: the copy's
  project points at its carried movie, which exists, and both it and the clip's movie probe as the motion.

Reverse verification: with the old code (remove then move, the identity check and receipt after the move, the inspector
forcing) and only the check seam added between the remove and the move, 6 of 234 core checks went red — the unchanged
Re-render started the (marker) renderer, the failed install and the other-identity render both lost the clip's movie, and
the Save As carried nothing. With the fix: 234 of 234.

## Lessons

- Replacing a file that something may be reading is one atomic rename of a staged file beside it — never "remove, then
  move". Every check that can refuse the new file runs before the rename.
- A cache key that pins the inputs makes "render again" redundant: reuse the checked file instead of forcing.
- A failure check that fails before the step under test proves nothing about that step: inject the failure after the
  helper passed.

Rules: [web-motion renderer §15](../architecture/web-motion-renderer.md), [blocking media reads, "Destination drives"](../architecture/blocking-media-reads.md).
