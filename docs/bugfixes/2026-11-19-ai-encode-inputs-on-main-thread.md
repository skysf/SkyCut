# 2026-11-19 The AI encode tools looked at, read and wrote the files they were given on the main thread

## Symptom

After their output folder moved off the main thread (#504, [case](2026-11-19-drive-checks-on-main-thread.md)),
`compress_videos`, `burn_subtitles` and `convert_subtitles` still waited on a drive on the main thread for the files the AI
names, the class of the freeze a friend's Mac showed with an external drive
([case](2026-11-18-export-folder-chooser-freezes-app.md)):

- every file in `files` / `items` was looked up with `fileExists` (a relative path once per folder it was tried in,
  `AIWorkspace.resolve`) and every video's content type was read (`MediaFileTypes.isVideo`);
- `burn_subtitles` read and parsed each subtitle file (`SubtitleLoader.load`);
- `convert_subtitles` read, converted and wrote each file (`SubtitleConverter.convertedContents`, `Data.write`), up to 200
  of them in one call.

An AI call naming files on a sleeping, slow or stuck drive held SkyCut's main thread for as long as the drive took: the
timeline, the preview and the windows stopped responding, and a drive that never answered froze SkyCut for good. Found by
task J1 ("Not done") and review CXR3 (R16).

## Root cause

The fixes before this one moved what the tools *write into* (the folder, the queue's names, the encode's own file) off the
main thread, and left what they *read from* where it was: the tools are `@MainActor`, and the input checks and the subtitle
reads and writes ran inline, before and after the off-main folder step. The convert's files are small, which made their reads
and writes look harmless; on a drive that does not answer, size does not matter.

## Fix

- `AIEncodeInputs` (new) does the input side the way `AIEncodeFolder` does the folder: the paths are read on the main thread
  without a drive; which file each path is (`AIPathResolution` with the folders `AIWorkspace.resolutionFolders` gives),
  whether it is there and whether a video is a video run through `ExportDestinationProbe.run` (off the main thread, the 15 s
  deadline of export_video, at most three checks waiting on one drive). `burn_subtitles` reads its subtitle files there
  after the person allowed reading them (`AIWorkspace.confirmReading` stays on the main thread, between the look and the
  read), and `convert_subtitles` reads, converts and writes there, still never replacing a file (`.withoutOverwriting`).
- A drive that does not answer is refused with the export panel's sentence; before anything is queued for the encode tools,
  and for a conversion with "files it has not written yet may still appear when the drive answers" (the outcome is unknown,
  so it is said, not guessed).
- `ExportDestinationProbe.FileSystem` gained `read` and `writeNew` (the live calls by default) so the checks can slow or
  stop them; `SubtitleLoader.document(from:named:)` and `SubtitleConverter.convertedContents(of:named:to:)` take bytes
  already read, so the one decoding rule (`TextDecoding`) stays in one place.
- `checks/file-io-off-main-wiring.sh` forbids every drive call that was there (`FileManager.default`,
  `AIWorkspace.shared.resolve`, `MediaFileTypes.isVideo`, `SubtitleLoader.load`, `convertedContents(`, `.write(to:`,
  `Data(contentsOf:`) in `AIEncodeTools.swift`, requires the three `AIEncodeInputs` calls, and forbids `AIEncodeInputs` any
  read or write outside the probe's file system.

## Verification

- `scripts/check-export-profile.sh` → `EncodeInputsOffMainChecks`, with a recording fake drive passed as the tools' probe:
  `compress_videos` looks at the file it names through the probe, off the main thread, and refuses a file on a drive that
  never answers at its 0.5 s deadline ("The drive with “StuckIn” is not responding… Nothing was queued.", main thread free,
  nothing queued, no job); `burn_subtitles` looks at both files and reads a subtitle file that takes 1.5 s off the main
  thread (longest main-thread gap under 0.5 s); `convert_subtitles` reads a 1.5 s file and writes the new one off the main
  thread (the converted file is real WebVTT), and refuses a read that does not come back at its deadline with the "may still
  appear" sentence. 199 assertions, 0 failures.
- Reverse verification: with the three probe runs in `AIEncodeInputs` replaced by the same work done on the main thread with
  the real drive, 5 assertions failed (exit 1): the fake was never asked, and the stuck file was called missing instead of not
  responding. Restored: green. The wiring guard turned red on four rules with main's `AIEncodeTools.swift`, and on its
  `AIEncodeInputs` rule for each of `FileManager.default`, `Data(contentsOf:`, `.write(to:` and the URL form of
  `convertedContents` injected into the new file.
- Not run: a real sleeping USB drive (manual item 22 in [export settings](../architecture/export-settings.md)).

## Lessons

- "Off the main thread" for a tool means everything it touches on a drive, inputs as well as outputs: when one side of a tool
  moves, look at the other side in the same pass.
- A small file is not a fast file. The time a drive call takes depends on the drive, not on the bytes.
- A check that only measures the main thread's gaps on the real drive cannot see a fast local read done on the main thread;
  a fake drive that records which thread asked it can.

Rules: [export settings](../architecture/export-settings.md) §5 item 8, [blocking media reads](../architecture/blocking-media-reads.md)
"Destination drives", [AI interface](../architecture/ai-control-mcp.md) section 4 item 24.
