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
- **Withdrawing a release**: a check that finds nothing newer than the running version removes a staged copy (it never
  installs); a feed naming another release replaces it. Rolling the feed back to the current version is how a bad release
  is pulled.
- **Test hook**: `defaults write com.srtflow.SrtFlow SrtFlow.update.feedURL <url>` (https anywhere, or http on 127.0.0.1 /
  localhost / ::1 only; anything else is ignored, production used). The DMG may then also come from the hook's own origin.
  Signature, notarization and every other check stay the same. `defaults delete com.srtflow.SrtFlow SrtFlow.update.feedURL`
  removes it.

## 2. Who updates

One pure rule, `AppUpdateEligibility.decide` (like `MoveToApplicationsOffer.decide`):

- **Updates itself**: the release app only (bundle id `com.srtflow.SrtFlow`, signed by team 26TVX3S9FR as
  `scripts/signing/common.sh` pins it, a plain `x.y.z` version), running from a folder this user can write, the bundle
  writable too, on a volume that swaps atomically, with Application Support on the same volume.
- **Only told** (the New Version pill, Open Download Page): such an app on the installer disk or translocated (#559's move
  offer handles those first), or in a place it can't replace itself. Never asks for administrator rights.
- **Never checks** (no menu item, no Settings section): SkyCut Beta, ad-hoc and source builds (`SKYCUT_ALLOW_ADHOC`), local
  builds' versions, `dist/`, `.build`, `/tmp` and scratch folders, and scripted runs (`CI` or `SRTFLOW_*` in the environment:
  checks, smokes, E2E) unless the test hook points at loopback. `SRTFLOW_AI_LAUNCH` (Claude or Codex opening SkyCut) is a
  normal launch.

## 3. Checking, and what the requests carry

About a minute after launch, then every 24 hours while SkyCut runs; plus SkyCut › Check for Updates… and the Settings button.
Never on the launch path: `AppUpdater.start()` reads the launch's facts off the main thread (`AppUpdateLaunch`).
Offline or any failure: nothing is said and the next check tries again (the Settings status line says the last check
failed).

The requests are plain GETs from an ephemeral session: no cookies, cache or credentials, a generic `User-Agent: SkyCut`, no
account, key, machine id or any other identifier. Redirects are refused (the feed and the DMG are served directly).

## 4. Downloading and verifying

With auto install on (or after Download and Install), in the background:

1. The DMG goes to `Application Support/SrtFlow/Updates/downloads/` (identity-class name, [产品名与代码名](product-name.md)).
   Never more bytes than the feed says; then the size and SHA-256 must match.
2. The image is attached read-only with `-nobrowse` at a private mount point (Finder doesn't show it), the app at its top
   (the running app's bundle id) copied into a folder of its own under `staged/`, the download quarantine cleared.
3. The copy is verified (`AppUpdateVerifier`): its Info.plist names the running app's bundle id and exactly the feed's
   version (newer than the running one) and build; its signature passes strictly against the **running** app's designated
   requirement with `notarized` in the same requirement (`AppBundleSignature.verify(_:matchesNotarized:network:)`); and
   Gatekeeper accepts it as «Notarized Developer ID» (`spctl --assess`; a Mac with assessments turned off can only say
   "accepted", the notarized requirement still applies).
4. Only a verified copy takes the version's place, `staged/<version>/`, with its record `staged.json`; the image is
   detached, older staged copies and downloads removed. Any failure leaves nothing of its own.

hdiutil, copying, hashing and signature checks block a thread: they run on `AppUpdateWork`'s queue, never the Swift
concurrency pool ([阻塞的媒体读取](blocking-media-reads.md)).

## 5. Installing: the app is never missing

At **every** quit while an update is staged (`applicationWillTerminate`, after the quit flow saved and asked about every
project, after the Compress / Burn In stop), and so on Restart and Update. This replaces the person's app, so:

1. The staged copy is checked again, offline (signature with `notarized`, Info.plist): a copy damaged or changed since it
   was staged is removed and never goes in.
2. No other process may run the app from the bundle (`RunningBundleProbe`, this process excepted): never two instances.
3. The marker `installed.json` is written first, so even a kill right after the swap shows Updated next time.
4. **One atomic swap**: `renamex_np(staged, destination, RENAME_SWAP)` on the same volume. The destination names the whole
   old app until that instant and the whole new app from it on. Nothing else ever moves, copies or replaces anything onto
   the destination (`checks/app-update-wiring.sh`).
5. Only then the replaced copy (now at the staged path) goes to the Trash; if it can't, the next launch tries again.

Any failure before the swap leaves the old app where it was and (but for a broken copy) the update staged for the next
quit; a swap across volumes or onto a missing destination fails without changing anything. A quit during logout or shutdown
can at worst skip it. An AI client's `skycut-mcp` running from the old bundle keeps working (a rename under it; it opens the
app at the same path next, as #559 measured).

## 6. Restart and Update

- Nothing running: SkyCut quits through the normal quit flow (unsaved projects are asked about; Cancel there cancels the
  restart: `ProjectQuit.quitCancelled`), installs, and a small shell that outlives it waits for this process to exit, then
  opens the app at the same path (the new version, or the old one if the install didn't go in). The projects that were open
  are opened again (the main window's in the main window, the others in their windows; only within 10 minutes).
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
- App menu: SkyCut › Check for Updates… (after About); once ready, Restart and Update to %@…, which opens the pill's popover
  in the active window. The answer to a check started there is the **only** window the updater ever opens.
- Settings › General › Software Update: the version, the status line, Check for Updates (answers in the status line), the
  switch «Download and install updates automatically» (default on, `SrtFlow.update.automatic.v1`) and its caption, which
  follows the switch. Turning it off stops a background download; a copy already staged then no longer installs by itself
  (Download and Install takes it at once).

Views subscribe to `AppUpdater` only (never a project or the player clock); every popover has `.appLanguage()`; tooltips are
`instantHelp`; colours are `AppThemePalette`'s.

## 8. Files

`Application Support/SrtFlow/Updates/`: `downloads/` (removed once staged and at every launch), `staged/<version>/` (the
verified copy; after the swap, the old app until it is trashed), `staged.json`, `installed.json` (read once by the next
launch, then removed), `mount-*` (image mount points; a killed run's are detached at the next launch). The new version reads
the marker the old version wrote: its format (`AppUpdateInstalledNote`) is part of the contract. UserDefaults:
`SrtFlow.update.automatic.v1`, `SrtFlow.update.lastUpToDate.v1`, `SrtFlow.update.reopen.v1`, the test hook
`SrtFlow.update.feedURL`.

## 9. Checks and guards

- `scripts/check-app-update.sh` (check-all): the feed's parser (every field wrong on its own), versions, who updates, the
  state machine, what a restart waits for, the status line; then against a loopback server and scratch folders: fetch,
  download (wrong SHA-256, wrong size either way, redirect, cancelled), staging from real images, a killed run's image,
  the launch cleanup, the install (order, refusals, cross-volume), and 24 loops of atomic swaps killed with SIGKILL at
  random instants: after every kill both paths hold a whole, valid app. FeedWriter on fixture values.
- `checks/app-update-wiring.sh` (check-all): one feed address, the swap only through `renamex_np` with `RENAME_SWAP`, the
  wiring at start / quit / menu / Settings / both toolbars, the quit-cancel hook, blocking work on its queue, no
  administrator rights, the release team, identity-class keys, no network in the check.
- Reverse-verified on 2026-11-27: replacing the swap with two renames turns the kill loop red (the destination missing after
  kills); removing the cancellation check or the incoming staging folder turns their cases red; each wiring line removed
  turns the guard red. Details: the PR.
- `scripts/render-app-updates.sh <folder>` (graphical session, not in check-all): the pill states, popovers, menu answers and
  Settings section in zh-Hans / en / es.

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
4. Within about a minute (or SkyCut › Check for Updates…): no window; the Update pill appears when B is downloaded and
   verified. The popover shows B's notes in the in-app language.
5. Quit A normally: B replaces it; no password asked; `/Applications/SkyCut.app` never disappears in Finder.
6. Open SkyCut: About says B; the Updated pill (no popover by itself); its notes; the AI line only with Connect AI set up.
   Screen recording, microphone, Downloads, Finder automation and the keychain are not asked again.
7. Restart and Update: with an export running, the popover lists it and SkyCut restarts by itself when it ends; with an
   unsaved project, the save question appears and Cancel keeps SkyCut running; afterwards the open projects come back.
8. With Claude or Codex connected and SkyCut quitting into the update: the AI's next call works (the helper reopens the new
   app).
9. Settings: the switch off → a newer test feed shows New Version, nothing downloads until Download and Install; a copy in
   a folder this user can't write shows the can't-install popover and Open Download Page.
10. Clean up: `defaults delete com.srtflow.SrtFlow SrtFlow.update.feedURL`; the replaced build is in the Trash.
