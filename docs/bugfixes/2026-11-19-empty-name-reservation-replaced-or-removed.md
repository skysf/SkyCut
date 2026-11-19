# 2026-11-19 A name reserved empty before the write could be replaced, and a failed write could remove another file

## Symptom

Not reported by a user: review CXR3, finding R3 (P1).

The writes that must never replace a file — the AI's `export_video` and `export_subtitles`, Compress / Burn In
(`ExclusivePlacement`), and a Save As or Export As nobody confirmed (`NewFileClaim`: the project's Save As, the subtitle
editor's Export As) — first reserved the final name by creating it empty (`open(O_CREAT | O_EXCL)`) and later put the
finished file there with an operation that replaces whatever is at the path:

- `ExclusivePlacement.fill` renamed the finished file onto the reserved path with `rename(2)` and never looked at the inode it
  had recorded. When Finder, a sync client reconciling the empty file, or another app replaced the empty reservation before
  delivery, that new file was overwritten. A subtitle set held all its empty names through serialization and read-back, so
  the window was long.
- The project's Save As and the subtitle editor's Export As reserved the name, then wrote with `Data.write(.atomic)`, which
  renames over whatever is there. Their failure cleanup removed any empty item at the path, also an unrelated empty file that
  had replaced the reservation.

The review reproduced both, the replacement and the deletion, with temporary probes against the production helpers.

## Root cause

Reserving the name and installing the file were two separate file-system operations. `O_EXCL` made the reservation atomic,
but nothing made the later rename conditional on the reservation still being SkyCut's, and the cleanup recognised "ours" by
"empty" instead of by identity. An empty file under the final name is also exactly what Finder and sync clients treat as a
real file.

Why the earlier fix ([parallel AI exports](2026-11-19-parallel-ai-exports-pick-the-same-name.md)) looked complete: its
checks put a file at the name before the claim, or released a claim nobody had touched. None changed the name after the
claim and before the rename.

## Fix

- **`ExclusiveInstall`** (new, SrtFlowCore): the one step that gives a complete private file its name, failing when the name is
  taken: `renamex_np(RENAME_EXCL)`; on a drive without it, `link` and then removing the private name; on a drive with neither,
  the name made with `open(O_CREAT | O_EXCL)` and the bytes copied in through that descriptor. Measured on disk images
  (macOS 26.5): APFS and HFS+ have the exclusive rename; FAT32 gets it from the system's own check; exFAT refuses both the
  exclusive rename and hard links with `ENOTSUP`, so it takes the copy. Taking a name back (a set) and every removal compare
  device and inode, read once the file holds its bytes: FAT and exFAT give an empty file a temporary number that changes when
  it first gets data (measured −3, then 7).
- **`ExclusivePlacement`**: no name is reserved empty any more. `create(url, writing:)` (an exact name; nil = taken),
  `createSet(from:_:writing:)` (every file of the set is written first, then the set is installed under one number; a set
  that meets a taken name takes back what it installed and moves on), `place` (on the same drive the file itself takes the
  name; onto another drive a hidden copy next to the target, or on a drive that can't install without copying, one copy
  straight into an `O_EXCL` file). `scratch` / `discard` stay as Compress / Burn In use them.
- **Callers**: `NewFileClaim.write` (the subtitle editor) and `ProjectFileWriter` (the project's Save As: the project file is
  written under a private name in the same folder, so its media paths and carried web-motion movies are the same; a file
  already at the name is seen first, so nothing is carried next to it); `SubtitleExportPlanner.writeNewSet` for
  `AISubtitleFileExport`.
- Rules: [export settings](../architecture/export-settings.md) §5 item 9 (new); §5 item 6,
  [system file windows](../architecture/system-file-windows.md) rule 9 and [project file](../architecture/video-edit-project-file.md)
  §5 item 5 now point to it.

## Verification

- `SrtFlowCoreChecks`, new `ExclusivePlacementChecks` (real folders): a free name, a taken name, **a file saved at the name
  by "another app" while SkyCut writes** (never replaced, the answer is "taken"), **an empty file that appears at the name
  before a failed write** (still there), a write that fails before making anything; a set with one name taken from the start,
  **a set whose second or first name is taken while it is written** (the late file keeps its bytes, the name already given is
  taken back, the set is complete under number 2); a numbered series counting on from its number; a copy onto "another
  drive"; `discard` never removing a file that replaced the scratch; nothing private left behind. All of it four times: with
  the exclusive rename, with the hard link and the `O_EXCL` copy forced (`ExclusiveInstall.stepsForChecks`), and on a real
  exFAT disk image made and attached by the check (it fails, not skips, when `hdiutil` can't). 1161 core checks green.
- Reverse verification (each red, then green after restoring):
  - A: the old design put back inside `create` / `createSet` (reserve empty, write, rename over the reservation, remove an
    empty name on failure) → 16 red: the late file replaced and the empty file removed, under every step and on exFAT, and
    both set races;
  - B: the install's first step as a plain `rename` → 14 red: taken names replaced, the series and the sets wrong.
  - The first exFAT run also caught a real defect in the new code: the copy recorded the file's number while it was empty, so
    a set could not take back a copy (fixed by reading it after the copy).
- `checks/file-io-off-main-wiring.sh` (new lines: no plain rename, `moveItem` or `replaceItemAt` in the two placement files, the
  exclusive rename as the first step, no `O_EXCL` reservation in `NewFileClaim`, which goes through `ExclusivePlacement.create`,
  and the project's Save As through it) → 3 red with a plain rename in the install and an `O_EXCL` line in `NewFileClaim`.
- App level, unchanged and green: `scripts/check-project-saves.sh` (61 assertions: Save As for every helper answer, Replace,
  closing an untitled project, the AI's saves, the subtitle editor's writes), `scripts/check-export-profile.sh` (179: two
  parallel `export_video` / `export_subtitles`, a stale listing, real Compress encodes delivered through `place`).
- Not verified: network shares (the hard-link step runs only forced on APFS), real sync clients.

## Lessons

- An exclusive create protects only the moment of creation. Whatever happens at the name afterwards is safe only if the step
  that finally puts the file there is conditional too: write privately, then install with one operation that fails when the
  name exists.
- Recognise your own file by identity (device and inode), never by a property such as "empty"; on FAT and exFAT read that
  identity only after the bytes are in.
- A check for "never replace" has to change the name in the window between reserving or staging and installing, not only
  before it. Run file-system rules on the file systems users export to: an exFAT image takes a second to make.
