# 2026-11-19 Compress / Burn In overwrote one result with another and could delete a file that was not the job's

## Symptom

Not reported by a user: found by task I2 while fixing the export targets
([parallel AI exports](2026-11-19-parallel-ai-exports-pick-the-same-name.md),
[export panel](2026-11-19-export-panel-checks-one-folder-writes-another.md)), outside its lane.

- With an output folder set on the Compress Video or Burn In Subtitles page, two queued inputs with the same file name
  from different folders (`a/clip.mp4`, `b/clip.mp4`) were both named `clip_compressed.mp4`. Both encodes ran; the second
  overwrote the first. Both rows said finished and "Show in Finder" opened the same file. Choosing an output folder after
  queueing (`refreshOutputPaths`) did the same.
- A file that appeared at a queued item's name before it was written (Finder, another app, an AI `compress_videos` into
  the same folder) was overwritten when the item ran.
- A job that failed or was cancelled deleted whatever was at its output name by then: the first item's finished file when
  two items shared a name, or a file that had appeared there.

## Root cause

1. **The page's name pick ignored the queue.** `EncodeQueue.add(urls:)` and `refreshOutputPaths` named each item with
   `proposedOutputURL`, which asked only the drive (`fileExists`) and avoided the input itself. Items still waiting or
   running had not written anything yet, so their names looked free. (The AI's `compress_videos` / `burn_subtitles` did
   check the queue, in a second copy of the naming rule, `AIEncodeOptions.outputs`; the page's adds did not.)
2. **ffmpeg wrote straight onto the name.** The queue passed the planned name as ffmpeg's output with `-y`, so whatever
   was there when the job started — the other item's result, a file that appeared — was overwritten without asking. The
   folder rule "a taken name gets a number, never overwrite" ([export settings](../architecture/export-settings.md) §5
   item 5) held only at the moment the item was queued.
3. **Cleanup removed the name, not the job's file.** `removePartialOutput(at: item.outputURL)` ran after every failure
   and cancel. The file at that name was the job's only if the job had written it and nobody else had; with 1 or 2 it
   was someone else's.

## Fix

- **One naming rule, reserved per item** (`EncodeQueue.target`): an item's name is the first of
  `<input name><suffix>.mp4`, `… 2.mp4`… in its folder that is not on the drive, not the input, and not planned by any
  other item still to be written (waiting, probing, running), compared the way macOS volumes compare names
  (`ExportDestinationReport.fold`). The item holds it until it ends. The page's adds, `refreshOutputPaths` (each waiting
  item named again against the others) and the AI's adds (`add(_:in:settings:burnIn:)`) all use it; the AI's own copy of
  the rule for these two tools is gone (`AIEncodeOptions.outputs` now names only `convert_subtitles`' files).
- **The job writes only its own file** (new `EncodeJob`): it claims a hidden scratch file next to the target
  (`ExclusivePlacement.scratch`, `O_CREAT | O_EXCL`, so it was nobody's before), and ffmpeg writes only that file — its
  `-y` can only overwrite the job's own claim. On success the file is handed over as `ExportTarget.newFile` through
  `ExportDelivery` → `ExclusivePlacement.place` (I2's path, reused): a name taken since it was planned moves the file on
  to the next number and is never replaced. The row shows the real file (`EncodeItem.deliveredURL`); `compress_videos` /
  `burn_subtitles`' `get_job` reports it with a `path_note`, the same words as `export_video`'s.
- **Cleanup only removes the job's own file** (`ExclusivePlacement.discard`: only while the file at the claim is still the
  one the job created — same device and inode). The job touches the folder only off the main thread. A cancel lands
  wherever the job is, also before ffmpeg starts (the old `currentProcess?.cancel()` was lost while no process existed).
- **Quitting during an encode** (`EncodeJob.stopAllForQuit`, from `applicationWillTerminate`): ffmpeg is stopped and the
  job's own file removed at once. Measured on 2026-11-19: an ffmpeg whose progress pipe's reader goes away keeps encoding
  and exits 0, so without this a quit would leave ffmpeg finishing a hidden file nobody sees (before the fix it finished
  the planned name).
- Rules: [export settings](../architecture/export-settings.md) §5 item 8; [blocking media reads](../architecture/blocking-media-reads.md)
  "Destination drives"; [AI interface](../architecture/ai-control-mcp.md) §4 item 24.

## Verification

- `scripts/check-export-profile.sh`, new `EncodeQueueChecks` (real encodes of small made-up videos; 172 assertions green
  with the rest of the script):
  - two inputs named `clip.mp4` from two folders into one folder: named `clip_compressed.mp4` and `clip_compressed 2.mp4`,
    both encoded, each read back at its own width (320 and 480); choosing a folder after queueing names them apart too;
  - a file written at the planned name after queueing: its bytes untouched, the encode is `late_compressed 2.mp4` and the
    row shows it;
  - an input made unreadable after it was probed: the job fails, the file that appeared at its name is untouched, no file
    of the job's own is left;
  - a `veryslow` encode cancelled while ffmpeg runs: cancelled, the file at its name untouched, nothing of its own left;
  - quitting (`stopAllForQuit`) while ffmpeg writes: the job's own file is gone when the call returns, the folder ends empty;
  - `compress_videos` with a file written at the answered name: kept; `get_job` gives `clip_compressed 2.mp4` and a
    `path_note` saying nothing was replaced;
  - no hidden file is left in any of the folders.
- Reproduced first: the check against main (65be46ae), before the quit item was added (it calls the new hook) — 9 red: one name twice (twice), the first result read back
  as the second's video (480 wide), the late file replaced and the row still at the planned name, the failed and the
  cancelled job deleted the file at their name, `compress_videos` replaced the file and `get_job` gave the planned path.
- Reverse verification (each red, then green after restoring): A no reservation in the pick → 2 red (both names; the
  delivery still kept the files apart); B delivered with `.replacing` → 4 red; C cleanup removing the planned name
  instead of the job's own file → 4 red; D ffmpeg writing onto the planned name → 7 red; E quitting only cancels → 1 red.
- Scan guard `checks/file-io-off-main-wiring.sh` (new section): the job's ffmpeg writes its claim, delivery through
  `ExportDelivery` to the target, cleanup only through `discard` off the main thread, no `FileManager` in the job, the
  queue gives ffmpeg no output path and removes nothing but the burn-in workspace, the quit hook. Each of the six broken
  in turn went red.
- Not verified: a real second drive, a real quit of the app (the check calls the quit hook directly), the pages in a real
  window ([export settings](../architecture/export-settings.md) manual items 20–21).

## Lessons

- A reservation protects a name only if every path that picks names checks every writer still to come: the AI's adds
  checked the queue, the page's did not — two copies of one rule had drifted.
- "Never overwrite" must hold when the file is written, not when the name was picked: write into a file of your own and
  rename onto an exclusive claim.
- Cleanup removes what the job created, identified by what it holds (its claim), not by a name someone else can occupy.
- A child process outlives the app that started it: decide what happens to it at quit.
