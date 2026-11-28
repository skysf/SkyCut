# App updates: SkyCut updates itself, quietly

> Since 2026-11-27. SkyCut checks for a new release, downloads and verifies it in the background, and installs it when the
> person quits (or at once with Restart and Update). Written in SkyCut, no Sparkle or other third-party code. Read this
> before changing anything in `Sources/SrtFlow/AppUpdate/`, the update feed or its release steps, the quit path's install,
> or the toolbar pill. Signing and notarization: [签名与系统权限](code-signing-and-permissions.md). The release steps:
> [构建与打包](../build/build-and-packaging.md)「公开下载发布」.

The user's decisions (2026-11-26/27): written in-house (「1: 自己写」); check automatically, download in the background, show a
small toolbar button, install at quit (「按2来」); nothing pops up by itself (「不弹，尽量不要打扰用户」); no forced update, Sky
Studio's `min_version` untouched (0.18.68 has no updater; its users download from the website); 3–5 lines of notes per
release, the Chinese approved by the user, English and Spanish written by the AI. The approved mockup and wording are in
the brief (`impl-briefs/U1-app-updates.md`, local only).

## 1. The feed

One JSON file, `https://skylu.ai/updates/skycut.json` (the personal site; served with a no-cache rule for `/updates/*`,
published at release in the same PR that moves `/download/skycut`). The addresses are written once, in `AppUpdateFeed`.

| Field | Contract |
| --- | --- |
| `schema` | the integer 1 |
| `bundle_id` | `com.srtflow.SrtFlow` (a feed for anything else is refused) |
| `version` | the release, plain `x.y.z` (1–6 digits each, no leading zeros) |
| `build` | CFBundleVersion of the app in the DMG |
| `minimum_macos` | LSMinimumSystemVersion of that app (`15.0`) |
| `dmg_url` | the DMG's immutable object, https on `downloads.skylu.ai`, never the `/download/skycut` redirect |
| `dmg_size`, `dmg_sha256` | the DMG's exact size (≤ 1 GiB) and lowercase SHA-256 |
| `notes` | `{"zh-Hans": [...], "en": [...], "es": [...]}`: 1–8 one-line notes (≤ 300 characters) per language; `en` required, every other language falls back to it |

- **Strict**: a feed over 64 KB, not JSON, or with any field missing or malformed is no feed. The check fails silently.
  Unknown fields are ignored, so a later feed can add some.
- **Never offered**: a version not newer than the running one (no downgrade, no reinstall of the same version) or one
  needing a newer macOS.
- **Withdrawing a release** (rolling the feed back to the current version is how a bad release is pulled). Only a valid
  feed naming an older version pulls it: a feed removed or broken is a check that can't reach or read the feed, and a copy
  already staged then installs at the next quit (below). What a valid older feed does and doesn't do:
  - it stops new downloads: a check that finds nothing newer than the running version removes a staged copy and a kept
    download; a feed naming another release replaces them;
  - a copy already staged on a Mac is removed at that Mac's next check, but installs at a quit that comes first. Within a
    run that can be up to a day (the next check). After a launch it can't: a copy an earlier run staged is neither shown
    nor installed until this launch's first check has confirmed the feed still names it, or failed to reach the feed
    (`AppUpdateState.unconfirmed`; offline Macs still update);
  - a Mac that already installed the bad release keeps it: only a fixed, higher version cures it. No downgrade, ever.
- **Test hook**: `defaults write com.srtflow.SrtFlow SrtFlow.update.feedURL <url>` (https anywhere, or http on 127.0.0.1 /
  localhost / ::1 only; anything else is ignored, production used). The DMG may then also come from the hook's own origin.
  Signature, notarization and every other check stay the same. While it is set, Settings › General › Software Update shows
  one line with its address («Test update feed: …»), so a hook left behind never turns updates off silently.
  `defaults delete com.srtflow.SrtFlow SrtFlow.update.feedURL` removes it.

## 2. Who updates

One pure rule, `AppUpdateEligibility.decide` (like `MoveToApplicationsOffer.decide`):

- **Updates itself**: the release app only (bundle id `com.srtflow.SrtFlow`, signed by team 26TVX3S9FR as
  `scripts/signing/common.sh` pins it, a plain `x.y.z` version), running from a folder this user can write, the bundle
  writable too, on a volume that swaps atomically, with Application Support on the same volume.
- **Only told** (the New Version pill, Open Download Page): such an app on the installer disk or translocated (#559's move
  offer handles those first), anywhere inside Desktop, Documents, Downloads, iCloud Drive or third-party cloud storage
  (`Library/CloudStorage`) (privacy-protected folders: the swap would ask for access from inside the quit, or fail at every
  quit after Don't Allow; reached through `/System/Volumes/Data` too), or in a place it can't replace itself. Never asks
  for administrator rights. A copy that only tells never touches the Updates folder: no file effect runs for it (another
  copy of SkyCut, one that installs, may be using the folder).
- **Never checks** (no menu item, no Settings section): SkyCut Beta, ad-hoc and source builds (`SKYCUT_ALLOW_ADHOC`), local
  builds' versions, `dist/`, `.build`, `/tmp` and scratch folders, a copy running from inside the Updates folder (a staged
  copy started by its path, also spelled through `/System/Volumes/Data`, an image mounted there: it never checks,
  downloads, installs or cleans up), and scripted runs
  (`CI` or `SRTFLOW_*` in the environment: checks, smokes, E2E) unless the test hook points at loopback.
  `SRTFLOW_AI_LAUNCH` (Claude or Codex opening SkyCut) is a normal launch.

## 3. Checking, and what the requests carry

About a minute after launch, then every 24 hours while SkyCut runs; plus SkyCut › Check for Updates… and the Settings button.
Never on the launch path: `AppUpdater.start()` reads the launch's facts off the main thread (`AppUpdateLaunch`).
Offline or any failure: nothing is said and the next check tries again (the Settings status line says the last check
failed).

The requests are plain GETs from an ephemeral session: no cookies, cache or credentials, a generic `User-Agent: SkyCut`, no
account, key, machine id or any other identifier. Redirects are refused (the feed and the DMG are served directly). The
check records every request on its loopback server and fails on any header beyond Host, User-Agent (`SkyCut`), Accept
(`*/*`), Accept-Language, Accept-Encoding, Connection, Cache-Control (`no-cache`) and Priority, and on any query string.
The website's privacy page states this check in its Mac app section (`privacySections` in `website/content/*.js`), so a
change here changes that page too.

## 4. Downloading and verifying

With auto install on (or after Download and Install), in the background (`AppUpdatePipeline`):

1. A copy of this release an earlier run staged is taken as it is. Otherwise, a finished download of its DMG kept from an
   earlier run (a quit during staging, say) is used if its size and SHA-256 still match the feed; one that doesn't is
   removed. Downloads of other DMGs are removed. The kept file's check reports progress 1 as it begins
   (`keptDownloadMatches(…, checking:)`): the check window says «Verifying…» while the whole file is hashed, and only a
   new download that follows a failed check shows its own percent.
2. Else the DMG goes to `Application Support/SrtFlow/Updates/downloads/` (identity-class name,
   [产品名与代码名](product-name.md)). Never more bytes than the feed says; then the size and SHA-256 must match.
3. Every byte is in (the transfer's last report, or a kept file's check): the progress is 1. The image is attached
   read-only with `-nobrowse` at a private mount point (Finder doesn't show it), the app at its top (the running app's
   bundle id) copied into a folder of its own under `staged.noindex/` (`.noindex`: Spotlight never lists the staged
   copy), the download quarantine cleared.
4. The copy is verified (`AppUpdateVerifier`): its Info.plist names the running app's bundle id and exactly the feed's
   version (newer than the running one) and build; its signature passes strictly against the **running** app's designated
   requirement with `notarized` in the same requirement (`AppBundleSignature.notarizedRequirement`); and Gatekeeper accepts
   it as «Notarized Developer ID» (`spctl --assess`; a Mac with assessments turned off can only say "accepted", the
   notarized requirement still applies).
5. Only a verified copy takes the version's place, `staged.noindex/<version>/`, with its record `staged.json`; the image
   is detached, older staged copies removed. The DMG stays until the update is installed, the feed names another DMG or
   nothing newer, or it fails its check (then it is removed). Any failure leaves no staged copy of its own.

**A DMG that keeps failing is not downloaded again and again** (`AppUpdateRetryRecord`, `Updates/retry.json`, kept across
launches): when a download completes and then fails its check (size, SHA-256) or its staging (the image, the copy, the
verification), the DMG's SHA-256 is recorded. An automatic check doesn't fetch that DMG again within 24 hours of its last
failure, and never after three, until the feed names another DMG. A check the person starts (the menu or Settings) always
fetches it, and its failure counts too. A download that didn't complete (offline, a server error) isn't counted; any
successful staging removes the record. Nothing new is shown.

hdiutil, copying, hashing and signature checks block a thread: they run on `AppUpdateWork`'s queue, never the Swift
concurrency pool ([阻塞的媒体读取](blocking-media-reads.md)).

## 5. Installing: the app is never missing

At **every** quit while an update is staged and ready (`applicationWillTerminate`, after the quit flow saved and asked
about every project, after the Compress / Burn In stop), and so on Restart and Update. A copy an earlier run staged is
ready only once this launch's first check confirmed it or failed to reach the feed (§1). This replaces the person's app, so:

1. Only the stager's own copy: `<Updates>/staged.noindex/<version>/<name>.app`, the path resolved, no link on the way
   (`AppUpdateFiles.stagedCopy`). A record naming anything else is refused and dropped; nothing it names is touched.
2. What is at the destination now is read again (its Info.plist): if the app there can't be read (moved, renamed,
   unreadable), the staged copy stays for the next quit; if it already is the staged version or newer (put there by hand or
   another tool), the staged copy is dropped. Never a downgrade.
3. The staged copy is checked again, offline (signature with `notarized`, Info.plist): a copy damaged or changed since it
   was staged is removed and never goes in. A problem with the running app itself (its bundle or signature unreadable:
   `AppUpdateRunningAppError`) is not the copy's fault: the copy stays for the next quit.
4. No other process may run the app from the bundle (`RunningBundleProbe`, this process excepted; helpers don't count):
   never two instances.
5. The marker `installed.json` is written first, so even a kill right after the swap shows Updated next time.
6. **One atomic swap**: `renamex_np(staged, destination, RENAME_SWAP)` on the same volume. The destination names the whole
   old app until that instant and the whole new app from it on. Nothing else ever moves, copies or replaces anything onto
   the destination (`checks/app-update-wiring.sh`).
7. Only then the replaced copy (now at the staged path) goes to the Trash (if it can't, the next launch tries again), and
   the downloaded DMG is removed.

Any failure before the swap leaves the old app where it was and (but for a broken or refused copy) the update staged for
the next quit; a swap across volumes or onto a missing destination fails without changing anything. A quit during logout or
shutdown can at worst skip it. An AI client's `skycut-mcp` running from the old bundle keeps working (a rename under it; it
opens the app at the same path next, as #559 measured). **The updater removes nothing outside its Updates folder**, except
the replaced app going to the Trash. Every deletion, the download's own file included, is in `AppUpdateFiles.swift`
(`remove`; `removeEmptyFolder` for an image's empty mount point; `checks/app-update-wiring.sh` pins it):

- it refuses a path that leads outside once links are resolved (the Data volume's spelling is the same place as the plain
  one), and removes a link itself, never what it points to;
- it never goes through the Updates folder itself when that is a link (made by hand): nothing is removed, staged or
  installed there, and a launch reads nothing there. A link above it (Application Support moved to another disk) is
  followed as any path is;
- it is one step for anyone watching: the item is first renamed into `removing.noindex/` in one call, then deleted there,
  so another SkyCut never finds half a bundle at the path it knew (its swap of a staged path that is gone fails and leaves
  its app). What a crash or a deletion that failed halfway leaves there is emptied at the next launch.

## 6. Restart and Update

- Nothing running: SkyCut quits through the normal quit flow (unsaved projects are asked about; Cancel there cancels the
  restart: `ProjectQuit.quitCancelled`), installs, and a small shell that outlives it (`AppUpdateRelaunch`) waits for this
  process to exit, then opens the app at the same path with `open` and the path alone (the new version, or the old one if the
  install didn't go in), but only while that path still holds an app: after a move or a rename it opens nothing. The
  projects that were open are opened again (the main window's in the main window, the others in their windows; only within
  10 minutes).
- Something running: no hard restart. The popover lists what it waits for and SkyCut restarts by itself once all of it has
  finished (checked every second); Cancel Restart stops waiting. It waits for: exports; the AI's round on any open project
  (and the AI's running jobs on it); the Compress / Burn In queue; subtitle generation and translation; Sky Studio tasks still
  running, which a restart would cut off (a paid result still on its way is lost to the timeline: SkyCut doesn't take over
  earlier cloud tasks at launch, [Sky Studio 的任务](sky-studio-jobs.md)). **Not** for the voice library's design / enroll
  orders: SkyStudioVoiceLibraryOrders follows those across restarts. A screen recording blocks it (the note line): it
  restarts once the recording has stopped and settled.

## 7. What the person sees: nothing pops up by itself

- Checking and downloading: nothing.
- Downloaded and verified: **Update** (filled) in the right toolbar group of every workbench window (the editor's: between
  the AI badge and the cloud tasks, as the mockup shows; the tools' pages: before Settings). It stays until installed and
  never opens by itself. Its popover: title, current version, what's new, the green note, Later / Restart and Update, the
  small print.
- Auto install off, or a copy that can't update itself: **New Version** (outlined). Off: Download and Install, then its
  progress in the popover, then as above. Can't: the can't-install popover with Open Download Page
  (`https://skylu.ai/download/skycut`).
- First launch after an update: **Updated**; clicking shows the notes and, only when Connect AI has a client set up, the AI
  line. It goes away once looked at, or at the next launch.
- App menu (`AppUpdateMenuEntry`):
  - SkyCut › Check for Updates… (after About): it checks and opens the check window (below);
  - greyed «Checking for Updates…» while any check runs: a second choice never starts a second check;
  - «Downloading Update (29%)…» while a download runs: it shows the check window on that download, without a check;
  - once ready, Restart and Update to %@…, which opens the pill's popover in the active window.
- **The check window** (UPD1, 2026-11-28). The user found the menu's check silent for seconds, 「好像卡死一样」. They chose a
  small window that never blocks, then asked to watch the download in it. Only the menu's check has a window, and it is the
  **only** window the updater opens.
  - **What it is** (`AppUpdateCheckWindow`): a utility panel, never modal.
    - It floats above SkyCut's own windows and is off screen while SkyCut isn't active, so it is never above other apps.
    - It moves aside by its title bar or background. The first time in a run it opens at the side
      (`AppUpdateCheckPlacement`): its top-right corner 12 pt inside the top-right of SkyCut's main window, just below
      the toolbar near the Update pill, whole on the visible screen (no main window: the screen's top-right). Never the
      middle of the screen, where SkyCut's questions come up. Then where the person left it, for the run.
    - SkyCut keeps working while it waits.
  - **When** (`AppUpdateCheckFlow`, pure):
    - an answer within 0.5 s opens the window straight on it;
    - otherwise it opens checking after 0.5 s: a spinner, «Checking for updates…», the running version, Cancel;
    - the checking state stays at least 0.5 s before the answer replaces it, in place;
    - Try Again shows checking at once.
  - **What it says** (`AppUpdateCheckContent`): up to date (OK); couldn't check (Cancel / Try Again); a newer version with
    what's new, then followed live from the updater's state (`AppUpdateCheckDisplay`). The progress is
    `AppUpdateState.progress`, the same value as the pill, Settings and get_status; the window never asks the network.
    - Downloading: «Downloading 29%», «12.3 MB / 42.4 MB», a bar. Then «Verifying…» once every byte is in. A kept
      download reports 1 as its check begins (§4), so it shows «Verifying…» while its SHA-256 is computed and through the
      staging, never «Downloading 0%». Only a new download after a failed check shows its percent.
    - Ready: the pill popover's ready text (Later / Restart and Update, the filled one). If the restart waits for running
      work, the popover's waiting list and Cancel Restart.
    - The download didn't finish (Later / Try Again). Try Again downloads again after Download and Install's download, and
      checks again after the automatic one.
    - Auto install off: Later / Download and Install, which keeps the window on the download.
    - A copy that can't update itself: Later / Open Download Page.
    - Up to date, once a later check withdraws the release (the newest found is gone: `AppUpdateState.lastFound`), also
      with auto install off and nothing downloaded.
    - What's new scrolls past 200 pt (a feed may hold 8 notes of 300 characters), so the buttons always stay on screen.
    - Every button has an instant tooltip; the filled one shows its Return key cap. While the schedule or Settings shares
      the check, Cancel's tooltip says it only closes the window («Close this panel»).
  - **Its words** are the old alerts' and the popovers' keys. The failed download has its own note («The download didn't
    finish.»): the popover's «… Try again later.» would contradict the Try Again button below it.
  - **Cancel** (while checking) closes the window. It stops the request (`AppUpdater.cancelCheck`) only when the window's
    own check is its only requester. A check the schedule or Settings also asked for goes on, unanswered by the window:
    Settings still gets its answer and a newer version still downloads. A cancelled check is never a failed one and
    settles nothing (§1).
  - **Closing.** The close button, OK, Later and Escape only close or hide the window. A check goes on and its answer never
    brings the window back. **A download is never stopped by the window**; while one runs, the menu item brings the window
    back on it.
  - **A quit closes it first** (SMK74). The window floats above SkyCut's windows, and SkyCut's questions are `NSAlert`s of
    normal level in the middle of the screen: one left up covered the quit question's buttons. So any quit (⌘Q, the menu,
    Restart and Update from the pill or the window) takes it off screen as its first step (`closeForQuit()`, the first
    line of `applicationShouldTerminate`, before a screen recording's or any project's question). A window chosen but not
    yet on screen never comes up. Restart and Update in the window closes it before it asks for the restart. If the quit
    is cancelled the window stays closed, and the menu brings it back.
  - **The keyboard.** It never takes the keyboard: it only comes on screen (`orderFront`), and becomes key when the person
    clicks it. Then Return clicks the filled button, and Escape is the close button in every state (it hides, never cancels).
    When the answer arrives or the download moves on, it never comes forward.
  - **Its size.** A taller state grows it downward. A window moved low on the screen is lifted just enough to stay whole on
    it.
  - **No modal loop anywhere.** AppUpdater's `.openCheckWindow` and `.answer` effects reach the window through
    `RunLoop.main.perform`, its timers are run-loop timers, and it starts no task. An exception under a modal loop inside a
    task crashed 0.18.70 ([case](../bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md),
    [system file windows](system-file-windows.md) rule 10).
- Settings › General › Software Update: the version, the status line (with a small spinner in front while any check runs),
  Check for Updates (answers in the status line; disabled while a check or a download runs), the switch «Download and
  install updates automatically» (default on, `SrtFlow.update.automatic.v1`) and its caption, which follows the switch.
  Turning it off stops a background download; a copy already staged then no longer installs by itself (Download and
  Install takes it at once). While the test hook is set, one more line under the status line: «Test update feed:
  <address>» (§1).

Views subscribe to `AppUpdater` only (never a project or the player clock), the check window's root too; every popover and
the window's hosting view have `.appLanguage()`; tooltips are `instantHelp`; colours are `AppThemePalette`'s.

**Who reads the state** (since 2026-11-27, MCP-85): the toolbar pill and its popovers, the app menu, the check window,
Settings' status line, and a connected AI through get_status's `app_update` (`AppUpdater.statusReport` →
`AppUpdateStatusReport`, pure; the fields and states: [AI 接口（MCP）](ai-control-mcp.md) section 4 item 69). get_status reads the state as it is on the main actor and
says what the pill and Settings say (a copy an earlier run staged stays unseen until this launch's first check, there too),
and one thing more: a newer release a check found stays `available` after its automatic download failed or the retry record
held its DMG back (`AppUpdateState.lastFound`, read by nothing but the report and the check window). The hints quote the App's buttons in its
language.
Reading it never starts a check, a download or an install, and nothing lets the AI install, restart or quit SkyCut: it
passes on the hint, the user's own steps. Its guide topic tells it to mention updates only when the user asks or a newer
version may fix what they hit, once (the quiet rule above).

## 8. Files

`Application Support/SrtFlow/Updates/`: `downloads/` (a finished download, kept until installed, §4),
`staged.noindex/<version>/` (the verified copy; after the swap, the old app until it is trashed), `removing.noindex/` (what
is being deleted, §5), `staged.json`, `installed.json` (read once by the next launch, then removed), `retry.json`
(`AppUpdateRetryRecord`, §4), `mount-*` (image mount points; a killed run's are detached at the next launch, a link there is
removed itself and what it points to never detached). The new version reads the marker the old version wrote: its
format (`AppUpdateInstalledNote`) is part of the contract. UserDefaults: `SrtFlow.update.automatic.v1`,
`SrtFlow.update.lastUpToDate.v1`, `SrtFlow.update.reopen.v1`, the test hook `SrtFlow.update.feedURL`.

**At launch** (`AppUpdateLaunchFiles`), and only for a copy that installs (`decision == .updates`: a copy that only tells,
never updates, or runs from inside the Updates folder touches nothing there; nor does any copy while the Updates folder
itself is a link): the marker is read once; images a killed run left attached are detached; `removing.noindex/` is
emptied; in `staged.noindex/`, an app older than the running one, in the folder of a newer version
(where a swap leaves the copy it replaced when the installer couldn't trash it), goes to the Trash. The staged copy the
record names, newer than the running app, stays. Anything else is our own download and is deleted, never sent to the
Trash: a copy not newer than the running app (installed by hand or by #559's move), one no record names, an unfinished
`incoming-…` folder, a link. The bundle this process runs from is never touched. In `downloads/`, a DMG of a release newer
than the running one stays; the rest goes.

## 9. Checks and guards

- `scripts/check-app-update.sh` (check-all): the feed's parser (every field wrong on its own), versions, who updates, the
  state machine (with the retry record and the unconfirmed staged copy), what a restart waits for, the status line; the
  menu check's window (`CheckWindowChecks`, UPD1):
  - only the menu's check opens it, at once;
  - the 0.5 s fast path and the 0.5 s minimum, Try Again;
  - Cancel stops only the check, and only when nothing else asked for it: never a download, never a failed check,
    nothing settled; a check the schedule or Settings shares goes on (Settings gets its answer, the download starts);
  - closing only hides, and an answer never brings the window back;
  - reopening on a running download;
  - what it draws, from the updater's state alone (the progress, verifying, ready, a restart waiting, both failed
    downloads, the switch turned off, a newer release, a withdrawn one: up to date, also before any download and for a
    copy that only tells), and the whole percents;
  - the pipeline's progress, read when each report comes and when the staging's verification runs (`PipelineChecks`): a
    fresh download's at 1 by the verification; a kept download's 1 from the start of its check, with the file still
    there, through the verification; a same-size damaged one «Verifying…» while its old bytes are checked, then the new
    download up to 1;
  - the menu item (greyed while any check runs, the percent while a download runs);
  - a quit in the grace period closes a window not yet shown, which then never comes up (SMK74);
  - the first place (`AppUpdateCheckPlacement`): the main window's top-right below its toolbar, the screen's without one,
    clamped whole onto the visible screen, never the middle (SMK74).

  Then, against a loopback server and scratch folders: fetch, download (wrong SHA-256, wrong size either way, redirect,
  cancelled, and which of them count), staging from real images, the pipeline (kept downloads, staged copies, what
  counts), the verifier's steps on their own (Gatekeeper alone, the running app unreadable), get_status's `app_update`
  (every state against hand-written JSON, which wins when two hold, notes and hints only where they belong, then through
  the state machine's own transitions), a killed run's image, the install (order, refusals, the stager's own copy only,
  no downgrade, cross-volume), 24 loops of atomic swaps killed with SIGKILL at random
  instants (after every kill both paths hold a whole, valid app), what a launch reads and cleans, and the relaunch shell
  (with a recorder for `/usr/bin/open`); the Updates folder's own rules (a link at its root never followed, deletions in
  one step, the Data volume's spelling, a sibling folder). Every request's headers against the allow-list, `Accept: */*`
  exactly, and no query string (§3). FeedWriter on fixture values. The shell wrapper `scripts/write-update-feed.sh` on a
  scratch image: relative arguments from another folder, and its mount (`scripts/update-feed/mount.sh`) failing right after
  the attach with nothing left attached.
- `checks/app-update-wiring.sh` (check-all): one feed address, the swap only through `renamex_np` with `RENAME_SWAP`,
  deletions only inside the Updates folder and the Trash only for the replaced app, the wiring at start / quit / menu /
  Settings / both toolbars, the quit-cancel hook, blocking work on its queue, no administrator rights, the release team,
  identity-class keys, no network in the check, and the coordinator the check doesn't compile: the probe without helpers,
  the production verifier at quit and when staging, `decision == .updates` before an install and before the launch reads
  the folder, the relaunch shell (this pid, `/usr/bin/open`, never `-n`), the test hook line in Settings; file effects only
  for a copy that installs; the schedule's origin, the retry record at launch, the real home folder, the cadence, a
  cancelled download's silence, the record matched to the offer (review FBU2); get_status's one `app_update` line, and the
  report only mapping a state it is given (Foundation only, no check, download, install or restart). Deletion calls
  (`removeItem`, `unlink`, `rmdir`, `recycle`) only in `AppUpdateFiles.swift`. Section 10, the check window (UPD1, code only,
  read across lines with comments and string literals not counted):
  - **Never modal.** No `runModal` or `NSAlert` in the updater.
  - **Opened and answered only from the run loop.** `.openCheckWindow` and `.answer` are each one
    `RunLoop.main.perform { MainActor.assumeIsolated { … } }` call right after their `case`, never a `Task` or a dispatch
    block. The menu's download item is the only `showDownload`, and it starts no check.
  - **Nothing in the window reaches further.** It starts no task or dispatch block, and never touches a download, the
    network or the state machine. Closing only hides; Cancel goes through `AppUpdater.cancelCheck`, which only sends
    `.checkCancelled`, and `.stopCheck` cancels only the check's own task. A cancelled check's task reports nothing.
  - **It draws the updater's state.** `AppUpdateCheckDisplay.make` reads `updater.state`. `open()` goes through the flow,
    and its ticks are run-loop timers.
  - **The menu item is `AppUpdateMenuEntry`'s,** with its greyed and download titles. One check at a time: a check started
    while one runs joins it.
  - **It never takes the keyboard.** `present()` only calls `orderFront`, and the window has no `makeKeyAndOrderFront`,
    `makeKey`, `orderFrontRegardless` or `activate`. Escape is `perform(.dismiss)`, the close button.
  - **Tooltips and Return.** Every button is a `secondaryButton` (`.instantHelp`) or a `defaultButton` (Return,
    `.instantHelp(…, shortcut: .defaultAction)`). Restart and Update is a `defaultButton`.
  - **What's new is capped.** The window passes `maxHeight: Self.notesMaxHeight`, and `AppUpdateNotes` scrolls past it.
  - **A quit closes it first** (SMK74). `closeForQuit()` is the first statement of `applicationShouldTerminate`, its only
    call. Restart and Update closes the window before `requestRestart()`. The first place comes from
    `AppUpdateCheckPlacement.origin`.
- Reverse-verified on 2026-11-27 (#565): replacing the swap with two renames turns the kill loop red (the destination missing
  after kills); removing the cancellation check or the incoming staging folder turns their cases red; each wiring line
  removed turns the guard red. Again for the fixes before the first release (U1b, two rounds): each new case and guard line
  was red with its fix undone; the tables are in the PR. get_status's `app_update` (U2): a renamed state, `checking` ahead
  of `just_updated`, the restart flag dropped, notes while downloading, the switch reported for every copy and the moving
  hint dropped each turn the status cases red; removing get_status's line, or a check started from the report or from
  `statusReport`, turns the guard red.
- Reverse-verified for the check window (UPD1, 2026-11-28): 25 sabotages, each red, 11 in the check and 14 in the guard.
  - **Opening.** The menu's check opening no window; `open()` not run from the run loop, or bypassing the flow.
  - **Timing.** No grace period; a quick answer ignored; no minimum for the checking state.
  - **The menu item.** Not greyed (in the pure entry, and enabled in the view); the download item without its percent; a
    second check started while one runs.
  - **Closing and Cancel.** Closing that stops the check (in the flow, and the close button cancelling); Cancel stopping
    the download too (in the state machine, and the window reaching `downloadTask`); Cancel not stopping the check; a
    cancelled check reporting.
  - **The display.** The progress not the updater's (pure, and the window drawing another state).
  - **Reopening.** Reopening that starts a check, or shows nothing.
  - **The run loop.** The answer shown inside a `Task` or through `DispatchQueue.main.async`; a modal alert or a `Task` in
    the window; a second `show` call.
- Again for review CXU1's fixes (round 2): 9 sabotages, each red, 3 in the check and 6 in the guard:
  - in the check: Cancel stopping a check Settings shares; a kept download reporting no progress; a withdrawn release
    still offered;
  - in the guard: the first show taking the keyboard; a button without its tooltip; the window's notes not capped, or
    `AppUpdateNotes` not scrolling; Escape cancelling while checking; Restart and Update without Return.
- Round 3 (review CXU2): 3 sabotages in the check, each red. The kept file's «Verifying…» report moved after staging,
  moved to just after the kept file's check, or removed.
- Round 4 (smoke SMK74): 6 sabotages, each red:
  - in the guard: Restart and Update leaving the window up; a quit leaving it up, or closing it only after the
    recording's question; the first place back in the middle;
  - in the check: a window in its grace period coming up over the question; the placement rule back to the middle.
- `scripts/render-app-updates.sh <folder>` (graphical session, not in check-all): the pill states, popovers, the check
  window in each state (the production panel, Classic in light and dark too), the menu item's titles and the Settings
  section in zh-Hans / en / es. It also prints how the check window's frame changes when it grows: its top edge kept in the
  middle of the screen, the window lifted when it was moved low.

## 10. Manual regression (before a release that changes the updater)

No check reaches a real notarized pair of builds, Gatekeeper on a real download, or `/Applications`. The two-build test
(ops runs it on the user's Mac after merge):

1. Build A = the current main as a release (`VERSION=x.y.z scripts/build-app.sh`), installed as `/Applications/SkyCut.app`.
   Build B = the same source with a higher version (`VERSION=x.y.(z+1)`), notarized, not installed.
2. Serve a test feed for B from a folder holding B's DMG: `python3 -m http.server 8123 --bind 127.0.0.1` there, and
   `scripts/write-update-feed.sh --test-feed http://127.0.0.1:8123/skycut.json dist/SkyCut-<B>-arm64.dmg
   http://127.0.0.1:8123/SkyCut-<B>-arm64.dmg notes.json <that folder>/skycut.json` (checked as the app checks a feed from
   that hook; without `--test-feed` only an immutable https URL on `downloads.skylu.ai` is accepted).
3. `defaults write com.srtflow.SrtFlow SrtFlow.update.feedURL http://127.0.0.1:8123/skycut.json`, open A.
4. Within about a minute: no window; the Update pill appears when B is downloaded and verified. The popover shows B's notes
   in the in-app language. (The menu's Check for Updates… answers with a window: step 19.)
5. Quit A normally: B replaces it; no password asked; `/Applications/SkyCut.app` never disappears in Finder.
6. Open SkyCut: About says B; the Updated pill (no popover by itself); its notes; the AI line only with Connect AI set up.
   Screen recording, microphone, Downloads, Finder automation and the keychain are not asked again.
7. Restart and Update: with an export running, the popover lists it and SkyCut restarts by itself when it ends; with an
   unsaved project, the save question appears and Cancel keeps SkyCut running; afterwards the open projects come back.
8. With Claude or Codex connected and SkyCut quitting into the update: the AI's next call works (the helper reopens the new
   app).
9. Settings: the switch off → a newer test feed shows New Version, nothing downloads until Download and Install; a copy in
   a folder this user can't write shows the can't-install popover and Open Download Page. While the hook is set, the
   «Test update feed: …» line shows its address.
10. Staging without Full Disk Access or Removable Volumes permission for SkyCut: no permission prompt while B is staged (the
    image is attached at a mount point under Application Support). Once on macOS 15 too: no macOS 15 Mac is at hand
    (2026-11-27), so this stays open until one is.
11. Quit A with Wi-Fi off, B staged: the offline check at quit passes, B goes in, the staged copy isn't thrown away.
12. After the update, open SkyCut from the Dock and by double-clicking a project: B opens, one instance, never a copy from
    the Trash or the Updates folder.
13. With B staged and A running, double-click a project in Finder: it opens in A (the staged copy is never started).
14. A wrong SHA-256 in the test feed: B downloads once, nothing is shown, no Update pill; an automatic check doesn't
    download it again for a day (quit and reopen A: no second download), SkyCut › Check for Updates… does (U1's limit:
    `Updates/retry.json` counts it).
15. B stays staged across a launch only when A ends without its normal quit (a force quit or a crash; the test sends
    SIGKILL to A once B is staged): a normal quit with B staged installs it. Then open A and quit within 30 s (before its
    first check): A stays, B is still staged (`staged.noindex/`), and the next quit after a check installs it.
16. With B staged by an earlier run (as in 15), roll the test feed back to A's version, then open A: once its first check
    ran (about a minute), B is gone from `staged.noindex/` and nothing is shown; a quit then leaves A.
17. With B staged by an earlier run (as in 15), stop the test server, then open A: after about a minute the Update pill
    shows (the feed can't be reached), and quitting installs B.
18. Quit A right after B finished downloading (while it is being staged): at the next launch B is staged from the kept DMG,
    with no second download in the test server's log.
19. SkyCut › Check for Updates… with B offered. Added 2026-11-27, after it crashed 0.18.70 and 0.18.71
    ([case](../bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md)); a non-modal window since UPD1.
    - The check window opens: straight on the answer, or checking first. It says B is available and follows its download.
    - While it is up, move the pointer between it, the main window and a project window several times, then click its button
      with the mouse. SkyCut keeps running, and the Update pill appears once B is staged.
    - Do the same with auto install off: Later, then again with Download and Install (the same window then shows the
      download). Then with the feed rolled back to A's version: up to date.
    - Then `log show --last 15m --predicate 'process == "SkyCut" AND eventMessage CONTAINS "PointerWatcher"'` prints nothing.
20. A slow network (UPD1). In the test feed's folder, serve it from a loopback server that answers after 5 s, instead of
    step 2's server:
    `python3 -c 'import http.server as h,time;h.ThreadingHTTPServer(("127.0.0.1",8123),type("S",(h.SimpleHTTPRequestHandler,),{"do_GET":lambda s:(time.sleep(5),h.SimpleHTTPRequestHandler.do_GET(s))})).serve_forever()'`
    Choose Check for Updates…:
    - within about half a second the window shows «Checking for updates…» with a spinner and Cancel;
    - the menu item reads «Checking for Updates…», greyed;
    - Settings › General › Software Update shows a spinner in front of its status line.
    Cancel closes the window, and choosing the item again starts a new check. Do it once more and close the window with its
    close button instead: when the answer arrives no window comes back, and with B offered the pill still appears.
    With the window on «Couldn't check», click Settings' Check for Updates, then the window's Try Again, then Cancel:
    Settings still shows its answer, and with B offered the Update pill appears.
21. Moving it aside (UPD1). With the slow feed, drag the window by its title bar to a corner of the screen and keep working:
    - click the timeline and play with Space, select clips, open Settings;
    - choosing the item leaves the keyboard in the editor (Space plays at once), and so does everything after;
    - the window stays above SkyCut's windows; click it, and Escape hides it (the check goes on);
    - when the answer arrives it changes in place;
    - switch to another app: the window hides; come back: it is there;
    - moved near the bottom of the screen, it stays whole when a taller answer arrives;
    - the first time in a run it opens at the top-right of the main window, below the toolbar;
    - with the window up and an unsaved project, quit with ⌘Q: the window goes away before the question, whose Save /
      Don't Save / Cancel the mouse reaches. Cancel: the window stays closed, and the menu brings it back. The same with
      Restart and Update in the window, and from the pill.
22. A download watched to the end (UPD1). With B offered and auto install on, choose Check for Updates…:
    - the window shows «Downloading n%» and «x MB / y MB» rising with the bar, then «Verifying…», then «SkyCut B is ready»
      with Later / Restart and Update;
    - again from A, close the window mid-download: the download finishes and the Update pill appears;
    - meanwhile the menu item reads «Downloading Update (n%)…», and choosing it brings the window back on the download
      with no new feed request in the test server's log;
    - with a wrong SHA-256 in the test feed: «The download didn't finish.» with Try Again, which checks and downloads
      again;
    - with auto install off, a complete DMG kept (a quit during the staging after Download and Install, as in step 18),
      open A, choose Check for Updates… and click Download and Install: «Verifying…» at once while the file is hashed,
      never «Downloading 0%», then ready;
    - with auto install off, roll the feed back to A's version while the window offers B (nothing downloaded), and let a
      check run (Settings' button): the window turns to up to date;
    - B's feed with 8 notes of 300 characters: what's new scrolls, the buttons stay on screen.
23. Clean up: `defaults delete com.srtflow.SrtFlow SrtFlow.update.feedURL`; the replaced build is in the Trash.

Last run on 2026-11-27, 0.18.69 → 0.18.70 (the release record: [构建与打包](../build/build-and-packaging.md)「公开下载发布」).
Every step a script could observe passed (files, the test server's log, SkyCut's log, the process list, the window
server's window list); step 6 was confirmed by the user (About 0.18.70, the Updated pill with the four notes).

The first real update, 0.18.70 → 0.18.71 on the user's Mac (2026-11-27, read from SkyCut's log, the Updates folder and
the Trash; the release record has the times). It covered the check, download, verification, staging and swap from the
public feed, and most likely Restart and Update's relaunch: `open` started 0.18.71 0.13 s after 0.18.70 exited, with no AI
helper active. The menu's Check for Updates… crashed 0.18.70 and 0.18.71; 0.18.72 fixes it, and step 19 tests it. Still
for a person: Restart and Update while an export runs and with an unsaved project (step 7), the Settings switch (step 9),
a quit with Wi-Fi off (step 11), the Dock click of step 12, and the Update pill and its popovers (steps 4 and 17).
