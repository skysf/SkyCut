# Saved project versions around AI rounds

> Since 2026-11-17 (to-do MCP-69, task G12). Long-term rules for the versions SkyCut saves of a project before and after each round
> of AI edits, and for going back to one in one step. The round itself ("this round", Stop, "Undo This Round") is in
> [AI interface (MCP)](ai-control-mcp.md) section 5; project files, autosave and relinking in [project files](video-edit-project-file.md).

## 1. What existed, what this adds

- **A round and "Undo This Round" (since 2026-09-27, per project since 2026-10-17)**: `AIRound` keeps the timeline as it was when
  the AI's round began (in memory). The banner's "Undo This Round" and `undo round=true` put it back as one undo step, exactly (no
  magnet, no linkage). It covers the one-step return for the **latest** round **in this run**: it is gone after SkyCut quits or the
  project closes, the next round replaces it, and the state it leaves lives only in the undo stack.
- **"Versions in a folder" (`AIVersionName`, 2026-10-17)** are something else: variant projects (`new_project version=30s` writes
  `<name> - 30s.skycut`), separate files the AI edits on purpose. Saved versions reuse only their naming form.
- **Added here**: saved versions on disk. They survive a restart, reach older rounds, keep the state that going back leaves, and
  the AI and the user are told what the version from before the round is called. On by default; no setting.

## 2. When a version is saved

| Moment | What is saved | Where |
| --- | --- | --- |
| The round's first change | the round's starting point (the snapshot taken when the round began) | `AIRound.noteChange` → `settleBeforeVersion`; for a never-saved project again in `AIRoundVersions.reporting`, after the router's `saveIfNeverSaved` gave it a file |
| The round ends: 30 s without calls (`finishRound`) or the user's Stop | the project as the round left it, if the round changed it | `AIRound.saveEndVersion`, only for the document the round began on (the user may have opened another file into the main window) |
| Before going back | the state being left | `undo version=`, the sheet's Go Back, and "Undo This Round" (banner and `undo round=true`) |

1. **Only when the project changed since its newest version.** Otherwise nothing is written and the newest version is reused — so
   when the user did nothing between two rounds, the second round's "before" version is the first round's "after" version.
   The comparison is of the timeline in **canonical form**: written and read back with the project file's own coder
   (`ProjectVersionFiles.canonical`, `VideoEditProjectIO.makeEncoder` / `makeDecoder`), so it sees exactly what a file can hold
   (dates keep whole seconds). Row heights are written into the version but not compared (decoration, not in undo).
   Generated web-motion movie URLs compare by their stored fingerprint, because cache relocation is not a timeline edit;
   `canonicalTimeline(ofFile:)` applies the same normalization. Ordinary imported media references remain exact.
2. **Never an empty timeline** (nothing to keep) and **never a project without a file** (a version belongs to a project file).
3. Writing is synchronous on the main actor (a project's own file is written off it since 2026-11-19, `ProjectFileWriter`;
   versions are not yet). If it fails (full disk), that moment has no version and the round goes
   on; the AI's result then names no version. A version goes into the local Application Support folder, but its media may
   sit on a sleeping or stuck external drive, so writing it asks the media files nothing: the media records are the
   project's last ones (`mediaRecords: .known`; a media file the project has not saved yet gets only its path and name).
   Since [subtitle and version saves touched drives on the main thread](../bugfixes/2026-11-19-subtitle-and-version-saves-touch-drives-on-main.md):
   before it, every version asked each media file for a bookmark and its size, on the main thread.

## 3. Where they live and what they are called

`~/Library/Application Support/SrtFlow/Versions/<project name> <8 hex>/<project name> - v<N> <label>.skycut`

- **A complete project file**, written by the same `VideoEditProjectIO.save` as the project (latest format version, media
  bookmarks from the project's `mediaRecords`) and read back by the same `load` (format gate, migrations by version, relinking,
  image stills). No new format, no format version bump.
  Web-motion pages, parameters and provenance are included, but their movies stay referenced in the actual project cache:
  snapshots use `VideoEditProjectIO.save(..., motionCaches: .reference)`. Normal project saves and Save As use `.carry`.
  Versions never copy movies into Application Support, so pruning the version files cannot leave large history-cache orphans.
- **Folder per project file**: the project's name (cut to 120 UTF-8 bytes) plus the first 8 hex of the SHA-256 of its standardized,
  symlink-resolved path (the identity `ProjectFileIdentity.same` uses). Two projects never share a list, even with the same name in
  one folder (`X/Trip.skycut` and `X/SkyCut/Projects/Trip.skycut` share a project home).
- **Name**: `AIVersionName.stem(name, version: "v<N> <label>")`, the `<name> - <version>` form; the label is fixed English
  (`before AI round`, `after AI round`, `before going back`) because the name is how a file is read back in any app language —
  the sheet shows the localized title. Unknown words after `v<N>` still make a version (kind unknown, "Saved version").
- **id** `v<N>`: N = newest + 1, so numbers keep counting after pruning. The AI may pass `v3`, `V3` or `3`.
- **Why Application Support and not next to the project**: per-path folders cannot collide; the user's folders get no clutter and
  `open_folder` never lists versions as media or projects; versions are an app-kept history like `SrtFlow/Recipes` and
  `SrtFlow/AudioLibrary`. The folder name is an identity name, so it stays `SrtFlow` ([product name](product-name.md)); the release
  and beta apps share it (they edit the same project files).
- **Checks and scripted runs never write into the user's folder**: `SRTFLOW_VERSIONS_ROOT` points it elsewhere; a run with the
  in-process smoke script or the performance bench (`SRTFLOW_SMOKE_SCRIPT`, `SRTFLOW_BENCH_OUT`) uses a folder of its own in the
  temporary directory.

## 4. Pruning (the disk does not fill)

- **The newest 30 per project** (by number) stay; older ones are deleted at each write.
- **Age sweep**, once per run at the first version written: every other project folder whose newest version is older than 60 days
  loses its version files, and the folder goes when that left it empty. The folder being written is never swept.
- Deleted for good, not moved to the Trash: they are copies SkyCut made; the project file is never touched. Only files whose names
  parse as versions, one level below the root, are ever deleted (notes the user left there stay).

## 5. Going back

One function for both sides, `ProjectVersionStore.goBack(to:)`:

1. The version is read with `VideoEditProjectIO.load` off the main thread (like opening a project: relinking may search folders).
2. The project must still be the same document (`documentGeneration`); otherwise nothing changes.
3. Already that version: nothing changes, no undo step.
4. The state being left is saved (`before going back`) unless it already is the newest version.
5. The version's media records go into the project's table for paths it does not know, so a file moved since is followed by its
   bookmark (the four layers ran in `load` already; the project's running relink uses the records afterwards).
6. **`restoreTimeline` in its own `AIUndoGrouping.step`**: one undo step (it lands after an await, outside any user event), restored
   as is — never through `perform`, whose magnet and linkage would change the version
   ([the same rule for "Undo This Round"](../bugfixes/2026-10-02-undo-round-repacks-v1.md)).
7. Image stills whose cache was cleared are converted again (`regenerateStills`).
8. Missing web-motion movies are rebuilt from the saved page by `WebMotionRecovery`, explicitly even for a background project
   with no preview. Going back to an otherwise identical version also starts missing-cache recovery without an undo step.

Command-Z returns to the state before going back. With the media where they were, the project equals the saved state field by
field, media references included.

## 6. The AI's contract

- **The round's first change** returns `before_round_version: {id, note}`; the note asks the AI to tell the user and says
  `undo version=<id>` goes back. Later changes of the round do not repeat it.
- **`undo version=<id>`** (parameter on the existing tool, no new tool): one undo step; the result has `undone: "version"`,
  `version`, and `saved_before_going_back` (the version holding the state it left). Already that version: `changed: false` and a note.
- **`get_status`** → `project.versions` (newest 10: `id`, `kind` = `before_ai_round` / `after_ai_round` / `before_going_back` /
  `saved`, `saved_at`) and `project.before_round_version` while the round has one.
- **Errors** ([parameter contract](mcp-edit-parameters.md)): an unknown id → `invalid_parameter` with `requested`, `allowed` (every
  id), `suggested` (this round's starting version, else the newest), `retryable: false`; no versions at all → `allowed: []` and a
  `suggestion`, no made-up id; `version` with `round=true` or `steps` → refused; unreadable file or a replaced project → a plain error.
  Nothing changes in any of them.
- **Catalog size**: the `undo` card was shortened so the whole catalog did not grow (it was at about 99,063 of 100,000 on
  2026-11-17); the long wording is the `versions` section of the guide's `undo` topic.

## 7. The user's side

- **Project menu ▸ Versions…** (disabled for a never-saved project) opens a sheet: newest first, the id, what it was saved for, the
  date and time (in the app language), and **Go Back** on each. Go Back closes the sheet and restores in one undo step; if it fails
  the project's notice says "Could not go back to v3."
- **The AI banner's details** say "Saved before this round as v3 (project menu ▸ Versions…)." — the same id the AI is told.
- The sheet reads only the project's `ProjectVersionStore` (an `ObservableObject`), never the timeline, so editing does not recompute it.

## 8. Limits

- Renaming or moving a project file starts a new list (the folder follows the path); the old versions stay until the age sweep.
- Versions stay on this Mac; they are not part of the project when it is copied elsewhere.
- Dates inside the timeline keep whole seconds in a version (the project file's format); the in-memory "Undo This Round" is exact.
- Row heights are not restored (decoration).
- A version file opened as a project (File ▸ Open) is edited in place like any project.
- A round on a never-saved project whose save failed, or one that began empty, has no "before" version; `undo round=true` still works.

## 9. Checks

- `scripts/check-project-versions.sh` (real App objects in an isolated bundle, temporary projects / media / root; shard 1):
  names, ids, folders, pruning and the age sweep on a real folder; a round of 20 edits (texts, volumes, moves, a clip removed and
  one added), the first change names v1 and only it, the round's end is v2, a second round right away reuses v2; the same state
  again and after a restart writes nothing, a round without changes writes nothing; `undo version=v1` → the project equals the
  starting point field by field (media references and records included), one Command-Z returns, redo goes back again, going back
  to the same version changes nothing; `get_status`; pruning to 30 with numbers that keep counting; a never-saved project named
  only after its save; an empty start; the errors (unknown id, `round` with `version`, no versions); two projects interleaved keep
  their own versions and going back on one leaves the other alone; `undo round=true` is exact and keeps what it left; a version
  whose media file was moved follows it.
- `checks/project-versions-wiring.sh` (scan): the router reports after `saveIfNeverSaved`, `undo` is async and hands `version` over
  first, the three save points in `AIRound`, the restore path (`restoreTimeline` in a step, no `perform`, `load`), `get_status`,
  forgetting a closed project's store, only `ProjectFileWriter` (a project's own file) and the store write project files, the menu item and its sheet.

Reverse verification (2026-11-17; each broken alone, the check run, the file restored byte for byte):

| Broken | Red |
| --- | --- |
| The router reports before `saveIfNeverSaved` | wiring: reported after the save |
| `noteChange` does not save the starting point | wiring: first change saves |
| "Undo This Round" does not keep the state it leaves | wiring: keeps the state it leaves |
| Going back through `perform` | wiring: restored as is |
| `forgetRound` keeps the store | wiring: forgets the store |
| `get_status` without versions | wiring: lists the versions |

The full-App check (same procedure; "of 86" is the check before the magnet case was added, "of 87" after):

| Broken | Red |
| --- | --- |
| `save` writes even when nothing changed | 10 of 86: the second round reuses v2, the same state again / after a restart, a round without changes, going back to the same version, undo round=true's version count, get_status |
| No pruning | 2 of 86: 33 saved keep 30; numbers keep counting |
| The folder without the path hash | 2 of 86: two projects with the same name keep separate folders, the folder starts with the name |
| The round's end saves nothing | 8 of 86: v2 at the round's end, v3 after the second round, two projects' v2, the moves project's v2, … |
| The starting point taken from the state after the first change | 15 of 87: v1 holds the starting point, one step back equals it, the never-saved project's v1, the magnet gap, two projects' starting points, the moved file, … |
| Going back through `perform` | 0 of 86 — the scenarios had the magnet off, so the magnet-gap scenario was added: 1 of 87 (V1 packed to 0, 2 instead of 0, 3) |

`scripts/render-project-versions.sh <folder>` (not in `check-all.sh`, graphical session) draws the Versions sheet with six
versions and with none, and the AI banner's details, in en / zh-Hans / es, forest and classic on dark. Without Screen Recording
permission for the shell (an agent's), `SRTFLOW_RENDER_DRAW_FALLBACK=1` draws the views with `cacheDisplay` instead of
`screencapture` (text and buttons come out right; text fields and pickers may not). The native project menu item itself cannot be
drawn off screen.

Motion/history integration is also exercised by `scripts/check-motion-placement.sh`: the async motion call reports its
before-round version, snapshots retain cache references without copying movies into history, relocation and restart create no
false changes, ordinary media URLs stay exact, restoration is one undo step, and a missing movie rebuilds in a headless project.
Reverse verification (2026-11-17): changing only the snapshot writer from `.reference` to `.carry` failed four of 109 assertions;
restoring that exact line returned all 109 to green.

## 10. Manual regression (before a release, real windows)

- [ ] On a saved project, let an AI make 20 or more edits in one round: the first result names `before_round_version`; the banner's
      details say "Saved before this round as v1"; 30 s after the last call, project menu ▸ Versions… lists v2 "After AI round" and
      v1 "Before AI round".
- [ ] Go Back to v1: preview and timeline are exactly as before the round; Command-Z returns to the AI's result.
- [ ] Quit SkyCut, reopen the project: Versions… still lists them and Go Back works.
- [ ] Two project windows edited by AI at once: each window's Versions… shows only its own.
- [ ] The sheet in English, 简体中文 and Español, forest and classic (system dark): nothing cut off, dates in the app language.
