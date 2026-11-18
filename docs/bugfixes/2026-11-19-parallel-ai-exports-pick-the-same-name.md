# 2026-11-19 Two AI exports into one folder could pick the same name, and the second replaced the first

## Symptom

Not reported by a user: review CXR2, finding R3 (P1).

- Two projects call `export_video` at the same time into the same folder with the same `name` (two sub-agents cutting two
  versions). Both calls could be answered with the same `path`. The exporter runs one export at a time, so both encodes
  finished, but the second delivery replaced the first file: both jobs reported `done` with the same path, and one film
  was gone.
- `export_subtitles` from two projects into one folder with one name: both wrote the same set of file names; the second
  replaced the first.
- Either tool also replaced a file that appeared in the folder after it had listed the folder (Finder, another app), against
  the AI contract "never overwrite, a taken name gets a number" ([AI interface](../architecture/ai-control-mcp.md) §4 item 6).

## Root cause

1. `AIToolRouter` queues calls per project, so the calls of two projects interleave at every `await`.
   `AIExportTools.export` passed `reservedOutputs` — a value copy of the set of names reserved by queued exports — into
   `AIExportDestination.output`, which then awaited the folder's listing off the main thread. Both calls took the same
   copy before either had reserved anything, got the same listing, and picked the same first free name. The second
   `reservedOutputs.insert` found the name already there; its result was ignored.
2. `ExportDelivery` moved the finished video with `replaceItemAt` when the name existed. That is right for the export panel
   after the user said Replace, but it was also the AI's path: a name taken after the listing — by the other export,
   Finder or another app — was overwritten without asking.
3. `export_subtitles` picked its names from the listing in one off-main step and wrote them in a second one through
   `SubtitleExportPlanner.writeValidated`, which also replaces. Nothing held the names between the two steps.

The previous fix to these tools ([case](2026-11-19-ai-export-folder-checked-on-main-thread.md)) moved the listing off the
main thread and so put an `await` between taking the copy and picking the name; the tests passed a fixed reserved set and
never ran two calls at once.

## Fix

- **Pick and reserve in one main-actor step** (`AIExportDestination.output`): the reservations live in
  `AIExportDestination`; after the listing comes back, nothing awaits until the name is picked against the reservations
  as they are at that moment and reserved. `export_video` gives the reservation back when the job is withdrawn, fails to
  start or ends (`AIExportDestination.release`).
- **Never replace when nobody was asked** (`ExportTarget`, `ExportDelivery`): the exporter is told either `.replacing(URL)`
  (the export panel after Replace) or `.newFile(folder, stem, extension, number)`. A new file goes through
  `ExclusivePlacement.place` (new, SrtFlowCore): the name is claimed with `open(O_CREAT | O_EXCL)`, which the file system
  answers atomically, and the video is renamed over that empty claim; a taken name moves the video on to the next number
  of its series, counting on from the number it had (`Cut 3`, not `Cut 2 2`). Onto another drive the video is first copied
  next to the target under a hidden name, so the empty claim exists only for the instant of the rename. The exporter
  reports where the file went (`finishedURL`) and what was asked (`finishedTarget`); `get_job` gives the real path and a
  `path_note` when it moved.
- **Subtitle files claim the whole set before writing** (`AISubtitleFileExport.write`): `ExclusivePlacement.claimSet`
  claims every name of the set, moving the whole set on when any name is taken; each file is written through
  `SubtitleExportPlanner.writeValidated(_:format:onto:)` (the same temporary file and read-back, then renamed onto its
  claim); claims not written are given back. `AISubtitleFiles.Series` names set n.
- `ExportFileName` gained `numbered` and `unoccupiedNumber`; `unoccupied` is unchanged.
- The export panel keeps replacing as before in this change; its own race (review finding R4) is a separate fix.
- Rules: [export settings](../architecture/export-settings.md) §5 item 6.

## Verification

- `scripts/check-export-profile.sh`, new `ExportTargetChecks` (139 assertions green):
  - two projects' `export_video` into one folder with one name, both held at a barrier inside the folder listing until both
    have listed: two names (`Twin.mp4`, `Twin 2.mp4`), both real exports done, each file read back at its own resolution
    (1280 and 854 wide);
  - a stale listing that does not show an existing `Late.mp4`: the file's bytes are untouched, the video is `Late 2.mp4`,
    and `get_job` has the `path_note`;
  - the same two cases for `export_subtitles`: two sets, each with its own project's line; a file that appeared after the
    listing kept, the set moved on;
  - `ExclusivePlacement` on real files: a claim never takes an existing file, a release removes only its own empty claim,
    a move counts on from its number, the copy path leaves nothing hidden, a set moves on together.
- Reverse verification (each went red, then green after restoring):
  - A: the pick made against a copy of the reservations taken before the listing → 2 red: both calls answered
    `Twin.mp4`, and the job whose delivery came second no longer matched its answer (it moved on to `Twin 2.mp4`);
  - B: a new file delivered with `replaceItemAt` → 2 red: the existing `Late.mp4` replaced, `get_job` said `Late.mp4`;
  - C: `export_subtitles` writing with `writeValidated(…, to:)` and no claims → 2 red: both sets named `Pair.en.srt`, the
    late file replaced.
- Scan guards: `checks/ai-work-queue-wiring.sh` item 5 (no `await` between pick and reservation, released three times,
  delivered as `.newFile`, never `.replacing`) went red with A's pick and with `.replacing` in `export_video`;
  `checks/MCP/tool-result-wiring.sh` (claims before writing, no `writeValidated(…, to:)` in `export_subtitles`) went red
  with C.
- Not verified: a real second drive for the copy path (the check forces it on one drive), and real AI clients.

## Lessons

- A value copy of shared state handed to an `async` function is a snapshot. Whatever it protects must be read and
  updated after the last `await`, in one step.
- "Never overwrite" must hold when the file is written, not only when the folder was listed: claim the name atomically
  and write onto the claim.
- A check of a race has to make the race happen: hold both calls at a barrier where the window is.
