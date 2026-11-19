# 2026-11-19 The subtitle editor's saves and the AI round's saved versions still waited on a user's drive on the main thread

## Symptom

Found by code review CXR2 (R12, P2), not reported by a user. Two ordinary saves were left out when project files, export
folders and the open / save windows stopped waiting on user drives on the main thread
([project save](2026-11-19-project-save-blocks-on-slow-drive.md), [export folder](2026-11-18-export-folder-chooser-freezes-app.md)):

- The subtitle editor's Export As to an external drive that just woke up and then stopped answering: the save window had
  already answered (its watcher was done), and the `@MainActor` callback wrote the file synchronously — SkyCut froze for as
  long as the drive took. Its in-place Save used the same write.
- The first change of an AI round saves the project as it was before the round (`AIRound.settleBeforeVersion` →
  `ProjectVersionStore.save`), synchronously on the main thread. The version file goes into the local Application Support
  folder, yet the save re-made a media record for every clip — `MediaBookmarkCache.bookmark` stats the file before it
  looks at its cache, then the size is read — so a project whose media sits on a sleeping external drive froze SkyCut on the
  AI's first edit (and at the round's end, and before going back), even with the project file on the internal disk.

## Root cause

1. `SubtitleEditPanel.write` called `Data.write(to:)` inline in the save window's completion and in Save; nothing moved it
   off the main thread when the windows became non-modal (the window was the hazard looked at, not the write after it).
2. Saved versions reuse `VideoEditProjectIO.save` for the format, and that function asks each media file for a fresh
   record (`MediaRecord.init(url:projectDirectory:previous:)`: bookmark, size, symlink-resolved relative path). That is
   right off the main thread (`ProjectFileWriter`), wrong on it. The versions doc said "writing is synchronous on the main
   actor" and thought only of the version file's own folder.

## Fix

- **`SubtitleFileSave`**: the bytes are made from the document on the main thread (the same serialization), the write runs
  on its serial queue (atomic, replacing only when allowed, `NewFileClaim`), and the caller waits at most 15 s. Past it the
  editor says "The drive with “X” is not responding…" (an existing string) and the write goes on. Every write reports its
  real end to the request that asked (`landed`): the editor marks the document saved only if, when the write lands, the
  panel still shows that document unchanged — an edit made meanwhile, or another document, stays unsaved.
- **Saved versions**: `VideoEditProjectIO.save(..., mediaRecords: .known)` takes each media record from what the project
  last wrote (`MediaRecord(known:for:)`: bookmark and size as recorded, no relative path — it was relative to the project's
  folder); a media file the project has not saved yet gets only its path and name. Nothing asks a media file anything;
  version numbers and the before / after order are unchanged because the version is still written in place.
- `MediaRecord.lookUp` (the bookmark and size a fresh record asks for) is a seam for the check.
- Rules: [blocking media reads](../architecture/blocking-media-reads.md) "Destination drives";
  [saved versions](../architecture/project-versions.md) §2 item 3.

## Verification

- `scripts/check-project-saves.sh`, new `OffMainWriteChecks` (7 assertions; 61 in all, green):
  - a subtitle write held by the drive: "not responding" at the 0.5 s deadline, the main thread free throughout, and the
    write that lands afterwards still tells its request (the file holds it);
  - two subtitle writes at once, one into a folder that does not exist: each request hears its own end;
  - a version of a project whose media answers each question in a second: saved, no question asked on the main thread,
    main thread free, and the version still names its media.
- Reverse verification: the subtitle write on the main queue and versions with fresh media records → exactly 3 red ("not
  responding" after 3.0 s, a 2.97 s gap, a version that asked once with a 1.0 s gap); dropping `.known` from the version
  store → `checks/file-io-off-main-wiring.sh` red.
- Not verified: a real sleeping USB drive for the subtitle editor and for an AI round on a project with external media
  (manual item in system-file-windows.md).

## Lessons

- Making the window non-modal moves only the wait for the answer: the write that follows the answer is a second wait on the
  same drive and needs the same treatment.
- A shared write function brings its disk questions along: the version file was local, but the media records it built
  were not. When a write runs on the main thread, list every file it touches, not only the one it writes.
