# 2026-11-19 Saving a project on a slow or stuck drive froze SkyCut, and Quit could hang

## Symptom

Not reported by a user: found while fixing the export folder freeze on a friend's Mac
([case](2026-11-18-export-folder-chooser-freezes-app.md), follow-up 3 there), and Master decided to fix it.

- A project file on an external drive (the friend's footage and projects live on a USB hard drive): every autosave — two
  seconds after each edit — held the main thread while the drive answered. A sleeping hard drive spinning up is seconds of
  spinning beachball; a stuck or half-unplugged drive is a frozen app.
- ⌘S, New / Open / Open Recent, closing a project window, the AI's `save_project` / `new_project` / `close_project` and the
  AI's first save of a never-saved project did the same.
- Quit saved every open project inside `applicationShouldTerminate`, on the main thread: on a stuck drive Quit never
  returned and only Force Quit ended SkyCut.

## Root cause

Proved by reading the code (before the fix):

1. `VideoEditProject.saveNow()` (main actor) ran `VideoEditProjectIO.save` inline: carrying web-motion movies, a bookmark per
   media file, the atomic JSON write, then the project file's own bookmark — every one of them a call into the drive.
   `flushAutosave`, `saveDocument(as:)` and `prepareToCloseDocument` all ended in it.
2. The 2 s autosave (`scheduleAutosave`) called `saveNow()` from a main-actor task, so it was on the main thread too.
3. `applicationShouldTerminate` called `prepareToCloseDocument()` for every project synchronously and returned
   `.terminateNow` / `.terminateCancel`: there was no way to wait for a drive without holding the main thread, and no way
   out while it did not answer. The same in `ScreenRecordingCoordinator.settleTerminationIfPossible`.

Found while writing the check: "follow a project file renamed or moved in Finder" (video-edit-project-file.md §6) only
worked until the first save after opening. The document bookmark was made once, and every atomic write gives the file a new
inode, so after the move the bookmark resolved to nothing and the save re-created a file under the old name.

## Fix

- **`ProjectFileWriter`** (new, one per project): the only place a project's own file is written. The write runs on the
  project's serial queue, never on the main thread; one write at a time, and the newest snapshot of the same file replaces
  one still waiting (a stuck drive never piles up writes). A caller waits at most a deadline (15 s, the export panel's
  deadline for a check that writes); past it the answer is "still writing" and the write goes on. Every write's real end is
  reported back (`landed`), so a late success still marks the project saved and a late failure is still said. A fresh
  document bookmark is made after every write.
- **`VideoEditProjectSaving.swift`**: `saveToFile`, `flushToFile`, `saveAs`, `saveSoon`, the autosave. Dirty marks go through
  `noteUnsavedChange`, which bumps the writer's change counter: a write clears the dirty mark only when nothing changed since
  its snapshot was taken (`adoptWritten`). A media table entry changed on the main thread during a write (a relink) wins over
  the one written. A drive that does not answer: the notice "The drive with “X” is not responding, so the project isn't saved
  yet…", the project stays dirty and open; the notice goes away when the write lands. Save As takes the new file only when it
  was written in time (§5 item 6 kept); a Save As that lands late never moves the project.
- **Closing / switching** (`VideoEditProjectDocument.swift`): `prepareToClose` (async) returns ready / refused /
  waitingForDrive; `startNewProject`, `openProject`, `OpenProjects.closeProject` / `createProject` / `resetPrimary`, the
  project window's close button (closes at once when there is nothing to write, otherwise after the save) and the AI tools
  all use it. A project whose drive does not answer is not closed or switched away from.
- **Quit** (`ProjectQuit`): `.terminateNow` when nothing needs writing or asking, otherwise `.terminateLater`. It waits 3 s
  quietly per project, then shows an alert that keeps waiting by itself — SkyCut quits as soon as the file is written — with
  "Don't Quit" and "Quit Anyway" (giving up only that project's unsaved changes). The screen-recording quit path goes through
  the same `prepareAll`, which runs once when asked twice.
- **Blocking variants for the checks**: `saveNow`, `flushAutosave`, `saveDocument(as:)`, `prepareToCloseDocument`,
  `newProject()`, `OpenProjects.close` / `newProject(savingAs:)` stay, writing on the caller's thread through the same
  writer, so ~40 check call sites in other areas did not change. Production code never calls them
  (`checks/project-file-wiring.sh`).
- The AI's screen-recording completion now saves a never-saved project right after the receipt instead of before it, so
  its job detail no longer carries `project_saved_to`; the next result names the file.
- Rules: [project file](../architecture/video-edit-project-file.md) §5 "Writing the project file off the main thread",
  [blocking reads](../architecture/blocking-media-reads.md) "Destination drives".

## Verification

- `scripts/check-project-saves.sh` (new, shard 1; 30 assertions green): a fake drive that holds each write until the check
  lets it go (never longer than 3 s, so a write on the main thread shows as a 3 s gap instead of a hang), fails, or is the
  real disk:
  - the autosave reaches the drive after 2 s with the main thread free and the project still dirty, then is saved;
  - a flush answers "not responding" at the 0.5 s deadline, main thread free, notice shown, still dirty; the late write
    marks it saved and clears the notice;
  - an edit during a write keeps the project dirty; the next write carries it;
  - three saves while one write is held become one more write, of the newest state;
  - a failing drive: notice, dirty, closing refused; a moved project file is followed and nothing appears at the old path;
  - New Project while the drive holds the write keeps the project open, unchanged and dirty (main thread free);
  - Save As late keeps the old file and a late landing does not move the project; Save As in time takes the new file;
  - the AI's `save_project` says the drive is not responding; `closesAtOnce` for saved / unsaved projects;
  - Quit: a slow drive within the quiet wait is waited for without a question, main thread free; a stuck drive is asked
    about once when Quit is asked twice, "Don't Quit" stays dirty; "Quit Anyway" quits; a write that ends while asking lets
    the quit go on, saved.
- Reverse verification (each went red, then green after restoring):
  - the write performed on the main thread → 13 red (3 s gaps, flush and switching wait for the drive, Save As, AI, Quit);
  - the dirty mark cleared without the change counter → 2 red; no coalescing → "4 writes"; a late Save As adopted → 1 red;
    Quit not single-flight → "asked 2";
  - the bookmark made only once (the code before this change) → the moved-file assertion red;
  - `project.flushAutosave()` back in `VideoEditView.onDisappear` → `checks/project-file-wiring.sh` red.
- Guards that pinned the old literal wiring were moved to the new one: `open-projects-wiring` (Quit through `ProjectQuit`,
  the window's close, `endPendingTextEditing`), `project-file-wiring` (new project), `project-versions-wiring` (the router's
  save, the only writers), `screen-recording-ai-wiring` (AI project tools), `film-production-wiring`.
- Not verified: a real sleeping or stuck USB drive, the real Quit alert and the window's close button in a running SkyCut
  (manual regression items in video-edit-project-file.md §7).

## Lessons

- A file on a user-chosen drive is the same hazard whether it is an export, a panel or the project itself: anything that
  writes there needs a queue, a deadline, and a way to tell the person without holding the main thread.
- `applicationShouldTerminate` must be able to wait: `.terminateLater` and one reply, with the waiting UI in front.
- Asynchronous writes need a change counter: "the write finished" is not "the project is saved" when someone edited during
  it.
- A rule like "follow the moved file" needs a check that saves twice before moving; one save hid that the bookmark went
  stale.
