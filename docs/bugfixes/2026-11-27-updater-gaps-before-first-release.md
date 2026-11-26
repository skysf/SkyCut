# 2026-11-27 The updater's gaps before its first release: repeated downloads, a pulled release still installing, deletes outside its folder

The in-app updater (#565) reaches users only with the next release, and a broken updater can't fix itself: friends would
have to download by hand again. Its first review (FBU1) cleared it for merge with 16 backlog findings. This case covers the
ones fixed before the first release, in one PR (lane U1b). Rules: [App updates](../architecture/app-updates.md).

## Symptom

None seen by a person yet (the updater hadn't shipped). Found by review and reproduced against scratch folders:

- **U1**: a release whose DMG fails its SHA-256 or its staging (a wrong feed, `spctl` timing out, a full disk) was
  downloaded again in full 60 s after every launch and once a day, silently, with no limit.
- **U3**: a finished download was deleted after staging and at every launch; a quit during staging threw it away.
- **U2**: rolling the feed back didn't stop a copy already staged from installing at a quit that came before the next check,
  including the quit in the first minute after a launch.
- **E1**: a staged record naming any `.app` path was installed, and the installer then deleted that app's parent folder
  (a `notes.txt` next to it went too).
- **E2**: the install compared with the version SkyCut started as: a newer app put at `/Applications/SkyCut.app` by hand
  while an older one ran was replaced by the older staged copy and sent to the Trash.
- **E3**: the launch cleanup sent a never-installed staged copy to the Trash as a second `SkyCut.app` (installed by hand at
  the same version), and ran for copies that only tell.
- **E5**: a copy in Downloads (privacy-protected) would ask for folder access from inside the quit, or fail at every quit.
- **E6**: a running app renamed or moved in Finder made its staged copy look broken (deleted, downloaded again), and Restart
  and Update `open`ed a path that held nothing.
- **E7**: a test hook left in `defaults` turned updates off with only «Couldn't check for updates».
- **E8**: the staged copy, a whole SkyCut, sat where Spotlight indexes; started by its path, it would update and trash
  itself.
- **G1**: seven sabotages of the coordinator stayed green (the check doesn't compile `AppUpdater`), and no check looked at
  the request headers.

## Root cause

- One shared cause for E1, E3, E8: **the updater trusted names**. A record's path, a folder named like the running version,
  and the name `staged` were taken as facts about what lay there. The installer moved, and the cleanup trashed, whatever the
  name said, without checking that the path was where the stager writes or what the bundle inside was.
- U1 and U3: **nothing was kept across launches**. A failure was forgotten at the next launch, so the next automatic check
  started from zero; the cleanup deleted downloads unconditionally because "a launch never resumes one".
- U2: the state at launch made an earlier run's staged copy `ready` straight away. The feed was asked only a minute later,
  and the install at quit asked nothing.
- E2 and E6: the install took the running process's facts (its version at launch, its bundle path) for the destination's,
  and one error type covered both "the copy is bad" and "the running app can't be read".
- G1: the coordinator's lines (which probe, which verifier, which decision) lived in a file no check compiles, and the
  guard pinned only where the coordinator is called. FBU1's verdict was right that each slip needs one grep, and right that
  no one had written them.

## Fix

- **Names are checked, not trusted** (`AppUpdateFiles`): every deletion goes through `remove`, which refuses a path that
  leads outside the Updates folder once links are resolved (a link is removed itself, never what it points to). The
  installer takes only `stagedCopy(of:)`: `staged.noindex/<version>/<name>.app`, no link on the way. Any other record is
  refused and dropped (`.recordRefused`).
- **The launch cleanup reads the bundles** (`AppUpdateLaunchFiles`, run only for `decision == .updates`): only an app older
  than the running one and its folder's version (where a swap leaves the copy it replaced) goes to the Trash; any other
  copy is our own download and is deleted. The bundle it runs from is never touched.
- **The install reads the destination at quit** (`AppUpdateInstaller`): unreadable (moved, renamed) keeps the staged copy;
  already at the staged version or newer drops it. `AppUpdateRunningAppError` tells the running app's problems from the
  copy's (`AppUpdateVerifier`); the relaunch shell (`AppUpdateRelaunch`) opens the path only while it holds an app.
- **Kept across launches**: `Updates/retry.json` (`AppUpdateRetryRecord`) holds back from automatic checks a DMG that came
  down whole and failed: 24 h after each failure, never after three, until the feed names another DMG; the person's checks
  always fetch it. A finished DMG stays until installed and is reused when its size and SHA-256 still match
  (`AppUpdatePipeline`).
- **A staged copy from an earlier run is unconfirmed** (`AppUpdateState.unconfirmed`): not shown and not installable until
  this launch's first check names it again or fails to reach the feed. The docs say what pulling a release does and
  doesn't do.
- E5: Desktop, Documents, Downloads and iCloud Drive only tell. E7: Settings shows «Test update feed: …» (three tables).
  E8: `staged.noindex`, and a copy inside the Updates folder never updates (`.never(.updatesFolder)`).
- G1: `checks/app-update-wiring.sh` pins the coordinator's lines (FBU1's table); the loopback server records request
  headers against an allow-list; a verifier case fails only at Gatekeeper (`AppUpdateVerifier.Steps`).

## Verification

- `scripts/check-app-update.sh`: 381 checks, from 278. New: the retry record and the unconfirmed copy in the state machine,
  the pipeline against loopback, the verifier's steps, E1 / E2 / E6 installs, the launch cleanup and gating, the relaunch
  shell with a recorder for `/usr/bin/open`, and 17 requests' headers against the allow-list.
- Reverse verification: each fix undone on its own turned its case or guard line red, then was restored (the table is in the
  PR and in `impl-briefs/status/U1b-app-updates-before-release.md`). FBU1's seven green sabotages now each turn something
  red.
- `scripts/check-local.sh app-update app-update-wiring localization-coverage move-to-applications` green; the full App
  builds; the Settings line rendered in en / zh-Hans / es.
- Not reached by a check (manual list, app-updates.md §10, items 10–14): no prompt while staging without Full Disk Access
  (macOS 15 untested: no such Mac at hand), Wi-Fi off at quit, the Dock and a double-clicked project after the update, a
  project double-clicked while B is staged, a wrong SHA-256 in the test feed.

## Lessons

- An installer or cleanup must check the thing, not its name: resolve the path, refuse links out, read the bundle's
  version before deciding it is "the old app". Keep the one place that deletes as narrow as the one place that swaps.
- Whatever repeats at every launch (a download, a cleanup) needs a memory across launches, or it repeats for ever.
- When a check can't compile a coordinator, pin its lines in the wiring guard on the day it is written; move the logic you
  can into pure, compiled pieces (`AppUpdatePipeline`, `AppUpdateLaunchFiles`, `AppUpdateRelaunch`).
- Long-term rules: [App updates](../architecture/app-updates.md) §1 (pulling a release), §4 (retry, kept downloads), §5
  (own copy only, no downgrade, nothing deleted outside), §8 (the launch cleanup).
