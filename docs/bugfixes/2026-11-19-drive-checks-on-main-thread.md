# 2026-11-19 Web-motion recovery and Compress / Burn In still asked the drive on the main thread

## Symptom

Two places left after the export-folder fixes (#478, #482–#485, #497) still waited on a drive on the main thread, the class of
the freeze a friend's Mac showed with an external drive (`docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md`):

- Web-motion recovery asked `fileExists` for every motion clip's movie on the main thread, and not only when a project opened:
  `revalidateMediaLocations` starts it on every preview rebuild (every edit) and every app activation. A project on a sleeping,
  slow or stuck drive with motion clips froze SkyCut for as long as the drive took, edit after edit. Found by task I4 (#494).
- Compress / Burn In picked an item's output name with a `fileExists` per candidate on the main thread (page and AI), read the
  finished file's size there too, and `compress_videos` / `burn_subtitles` / `convert_subtitles` made their output folder with
  `createDirectory` on the main thread (and resolved a relative `folder` with `fileExists` there). Adding videos with an output
  folder on a sleeping drive froze the page; an AI call into such a folder held the main thread before anything was queued,
  and a read-only or unwritable folder was only found out when the encode was delivered. Found by task I6 (#500).

## Root cause

Both predate the "Destination drives" rule (blocking-media-reads.md): the code asked the drive where it needed the answer, on
the main actor. The web-motion cache's own file work had moved onto `WebMotionCacheFiles.queue` (#494), but recovery's checks
had not ("not on it yet" in web-motion-renderer.md §15). The encode naming was rewritten for correctness in #500 (never two items
with one name, never replacing), and kept its `fileExists` hint on the main thread, "as before".

## Fix

- `WebMotionRecovery` snapshots the motion clips on the main thread and asks the drive which movies are there on
  `WebMotionCacheFiles.queue` (`MediaReadQueue.run`, the rule shared with the project load as
  `WebMotionProjectFiles.cache(for:projectURL:exists:)`). The answer is applied only to clips that are still what was looked at,
  as before as a document repair without undo; a motion clip that appeared or changed during the run is looked at again in a new
  run (also off the main thread), instead of the old main-thread `fileExists` in the task's `defer`.
- `EncodeQueue` names an item at once against the other items and its input only, then again once its folder's names are back
  from `ExportDestinationProbe` (off the main thread, the export panel's 5 s look deadline, at most three checks waiting on one
  drive): `EncodeOutputFolder`. Items that started, ended or moved to another folder meanwhile, and folders that are missing or
  do not answer, keep their names; the encode never replaces anything anyway (EncodeJob), so a later name only moves the file
  on. The finished file's size is read through the probe too.
- `compress_videos`, `burn_subtitles` and `convert_subtitles` read `folder` in one place, `AIEncodeFolder`: resolved, made,
  checked (a folder, not read-only, writable) and listed through the probe with export_video's 15 s deadline, refused with the
  export panel's sentence before anything is queued or written; the queue names the AI's items against that listing, so the
  reply already has the right numbers. convert_subtitles is now asynchronous (its router line awaits it).
- `checks/file-io-off-main-wiring.sh` forbids `FileManager.default` / `refreshWebMotionCaches(` in WebMotionRecovery,
  `fileExists` / `byteSize` / listing in EncodeQueue and `FileManager.default` in EncodeOutputFolder / AIEncodeFolder, and
  requires the queue / probe calls; `scripts/check-mcp.sh` pins AIEncodeFolder as the one reader of `folder`.

## Verification

- `scripts/check-motion-placement.sh` → `RecoveryOffMain`: a drive whose first three answers take 1.2 s each (seam
  `WebMotionRecovery.existsForChecks`); `revalidateMediaLocations` → no question on the main thread, longest main-thread gap
  under 0.5 s, the deleted movie comes back as a document repair of the same pixels without an undo step.
- `scripts/check-export-profile.sh` → `EncodeOffMainChecks`: a taken name in the output folder is passed once the listing is
  back (adding, and choosing another folder); a drive that never answers (fake probe) leaves `add` immediate and the main thread
  free, the name as picked; `compress_videos` names past a taken file before it answers, and refuses a stuck drive at its
  deadline ("not responding", main thread free) and a read-only one ("NTFS") with nothing queued and no job.
- Reverse verification: the guard turned red on all six rules it adds for main's files (and on `FileManager.default` added to
  the two new files); the behaviour checks went red with the drive question moved back onto the main thread (see the PR).

## Lessons

- "Not on it yet" in a doc is a known freeze waiting for a drive: when one call site of a class moves off the main thread, sweep
  its siblings in the same area (here: the cache's own queue already existed).
- A check that runs on every rebuild is a hot path for drive latency, not a one-off at open.
- What remains on the main thread in these tools: `compress_videos` / `burn_subtitles` / `convert_subtitles` still ask
  `fileExists` for the input files the AI names (`files`), and convert_subtitles reads and writes its small subtitle files there
  (`.withoutOverwriting`); recorded in export-settings.md §5 item 8 and ai-control-mcp.md section 4 item 24.

Rules: [blocking media reads](../architecture/blocking-media-reads.md) "Destination drives",
[export settings](../architecture/export-settings.md) §5 item 8, [web-motion renderer](../architecture/web-motion-renderer.md) §15.
