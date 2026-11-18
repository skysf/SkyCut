# 2026-11-19 The AI's export tools touched the export folder on the main thread

## Symptom

Not reported by a user: found while fixing the export panel's folder freeze
([case](2026-11-18-export-folder-chooser-freezes-app.md), follow-up 4 there), and Master decided to fix it the same way.

- When the AI's `export_video` was asked to export into a folder on a sleeping, slow or stuck external drive, SkyCut's
  main thread waited on that drive: a spinning beachball for as long as the drive took to answer, or for good if it never
  did. The same for `export_subtitles` (found while fixing `export_video`: same folder, same code shape).
- A folder SkyCut can't write into — on a read-only NTFS drive, or without permission — was accepted. `export_video` encoded
  the whole film and only failed when the finished video was moved there; the AI saw a failed job minutes later instead of
  a clear answer at once.

## Root cause

Proved by reading the code (before the fix):

1. `AIExportTools.export` (main actor) chose the file with `ExportFileName.unoccupied`, whose `exists` closure was
   `FileManager.default.fileExists` for every candidate name, then called `FileManager.default.createDirectory` — both on
   the main thread, both against the destination drive.
2. Finding the folder touched the drive too: the default folder asks whether the old `SrtFlow` folder is there
   (`AIWorkspace.outputFolder` → `DefaultFolder.aiFolder`), and a relative `path` may be tried against two folders
   (`AIWorkspace.resolve` → `AIPathResolution`), each with `fileExists`.
3. Nothing checked that the folder could be written into before the export started; the first write was the delivery
   after the encode (`ExportDelivery`).
4. `AISubtitleFileExport.export` did the same (`createDirectory`, `fileExists` per name) and then wrote and read back the
   subtitle files (`SubtitleExportPlanner.writeValidated`), all on the main thread.

These are the same class of hazard as items 2–4 of the export panel's case: a file-system call on a user-chosen folder can
block for seconds (a USB hard drive spinning up) or never return (a stuck or half-unplugged drive).

## Fix

- **`AIExportDestination`** (new): export_video's arguments are read on the main thread without touching a drive
  (`Request`); everything that asks the drive — which folder a relative path means, whether the old `SrtFlow` folder is
  there, making the folder with its parents, the export panel's look-and-write check (a folder, not on a read-only drive,
  a hidden test file can be written) and the listing for taken names — runs inside `ExportDestinationProbe.run`: on GCD,
  never the main thread, with the export panel's deadline for a check that writes (15 s), and the same per-drive cap of
  three outstanding checks. The name is reserved the moment it is chosen (before, an `await` sat between choosing it and
  reserving it).
- A folder that can't be used is refused **before any job starts**, with the export panel's own sentence in English
  (`ExportDestinationText.message(…, L10n: { $0 })`; the en table's keys are its text) plus the folder and "Nothing was
  exported." Making the folder on a read-only drive is said as a read-only drive (`ExportDestinationProbe.problem(creating:)`).
- **`ExportDestinationProbe`**: the deadline-and-cap machinery is now `run(on:deadline:timedOut:_:)`, which `inspect` and
  the AI tools share; the file-system seam gained `createFolder`.
- **`AISubtitleFileExport`** is `async` now: its folder goes through the same preparation (`AIExportDestination.prepareFolder`)
  and its files are written in a second `run` with the same deadline. If the drive stops answering while writing, the AI is
  told the files may still appear, so it checks before writing them again.
- `AIWorkspace` keeps one implementation of the two rules and exposes the parts that need no drive
  (`resolutionFolders()`, `outputFolder(_:in:isFolder:)`).
- Rules: [export settings](../architecture/export-settings.md) §8 item 8,
  [blocking reads](../architecture/blocking-media-reads.md) "Destination drives".

## Verification

- `scripts/check-export-profile.sh`, new `AIExportFolderChecks` (103 assertions green, 87 before this change):
  - real folders: a missing folder (two levels) is made; a name already in the folder, or reserved by a queued export, gets
    a number; no `.SrtFlow-` test file is left; without `path` the default `<home>/SkyCut/Exports` is made; a `chmod 555`
    folder is refused through `export_video` with the panel's "can't write into" sentence;
  - a fake drive that never answers, through `export_video`: "not responding" at the 0.5 s deadline (not when the drive
    wakes), main-thread gap under 0.5 s, no job started and the exporter idle;
  - a fake read-only drive: the NTFS sentence; the `EROFS` / `EACCES` mapping of a failed `createDirectory`;
  - `export_subtitles`: a missing folder made, a taken name numbered (`Talk.en.srt`, `Talk 2.en.srt`), a stuck drive
    answered at the deadline with the main thread free, a read-only drive said.
- Reverse verification (each went red, then green after restoring):
  - A: export_video's drive work run synchronously on the main thread → 4 red (main thread held 16 s, the answer came only
    when the fake drive woke, and the stuck call went on to start an export);
  - B: the folder not made and no write test → 5 red (missing folder, numbering, default folder, the locked folder accepted
    and its export started);
  - C: export_subtitles' folder work on the main thread → 2 red (16 s gap; the wrong sentence);
  - the scan guard: a `FileManager.default` call back in `AIExportTools.swift` → `checks/project-file-wiring.sh` red.
- Not verified: a real external drive that is asleep or read-only, driven by a real AI client (manual regression item 18
  in export-settings.md).

## Lessons

- The AI's tools are a second way into the same folders the panels use: when a panel is fixed for a class of hazard, look
  for the tool that does the same job (`export_video` next to the export panel, `export_subtitles` next to the panel's
  subtitle files).
- An error the AI gets minutes later from a failed job is worse than the same sentence at once: check what can be checked
  before the long job starts.
