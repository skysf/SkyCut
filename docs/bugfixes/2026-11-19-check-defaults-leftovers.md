# 2026-11-19 Checks left thousands of preference files in the developer's home

## Symptom

On 2026-11-19 `~/Library/Preferences` on the developer Mac held 2,353 plists that checks had written, almost all
empty: 337 `com.srtflow.approval-check-<UUID>`, 333 `com.srtflow.voice-budget-check-<UUID>`, 308
`com.srtflow.ai-access-check-<UUID>`, 267 `com.srtflow.official-approval-check-<UUID>`, 239 `com.srtflow.image-approval-<UUID>`,
236 `com.srtflow.character-approval-<UUID>`, 223 `keychain-notice-checks-<UUID>`, 100 `com.srtflow.voice-gate-check-<UUID>`,
90 `srtflow-optimizedmedia-*-<pid>`, 77 `com.srtflow.standing-migration-<UUID>`, 68 `com.srtflow.SrtFlow.motionplacementcheck.run<pid>`
and more. Each local `check-sky-studio.sh` run added nine. Checks must not touch the user's real data.

## Root cause

1. **Removing a domain does not remove its file.** Swift checks made a per-run `UserDefaults(suiteName: "com.srtflow.…-<UUID>")`
   and called `removePersistentDomain(forName:)` in a `defer`. That empties the domain, but cfprefsd keeps its plist as a
   42-byte empty dictionary. Measured on macOS 26.5.2: removing the domain, removing every key, `CFPreferencesSetMultiple`
   and `defaults delete` all leave the file, and `defaults delete` on an already emptied domain answers "Domain … not found"
   and leaves it too. Deleting the file from the check, even after `CFPreferencesAppSynchronize`, does not stick: cfprefsd
   writes a domain's last change 3 to 10 s after it (10 s once a domain has been written repeatedly) and recreates the file.
   Neither `CFFIXED_USER_HOME` nor `__CFPREFERENCES_AVOID_DAEMON=1` moves an unsandboxed process's preferences out of the
   real home; the E2E launcher's isolation comes from its sandbox profile.
2. **Per-run names accumulate.** With a UUID or pid in the name, every run left a new file. Some suites (optimized media)
   were never removed at all.
3. **Staged check apps write their own domain.** Their `UserDefaults.standard` is their bundle id; the check mains reset it
   with `removePersistentDomain`, which leaves the plist, and `motionplacementcheck.run<pid>` had no sweep.

It looked handled: every suite had its `defer`, and the domain then reads back empty, so no check could see the file.

## Fix

- `checks/Shared/ScratchDefaults.swift`: a suite named by an absolute path is stored beside that path, not in
  `~/Library/Preferences`. Each scratch suite lives in its own folder under `$TMPDIR/skycut-check-defaults/` and is removed
  with it; cfprefsd does not recreate a deleted folder for a pending write. Nineteen suites in eighteen check files moved to
  it, and the seven scripts that compile them list the helper.
- `scripts/test-defaults-cleanup.sh`, called by `remove_test_app` in `scripts/test-app-cleanup.sh`: a staged check or render
  app's own domain (bundle id `com.srtflow.SrtFlow.<name>check` or `<name>render`, maybe `.run<pid>`) is deleted 15 s after
  the app exits. `check-all.sh` and `check-local.sh` collect the domains and delete them after one wait at the end of the
  run, so a check pays no wait of its own there. Real, dev and smoke identities are never touched.
- On CI, `check-all.sh` compares the home's SkyCut-looking preference names before and after the run and fails on new ones.
- `checks/test-defaults-cleanup.sh` (scan guard): no named suite in Swift checks, every `ScratchDefaults` removed in its
  file, every staged check app carries a check app's bundle id, the entry points wired; the removal exercised on a fake home.

## Verification

- `check-app-theme.sh` and `check-timeline-zoom.sh` pass on scratch suites and leave nothing in `~/Library/Preferences`.
  With `origin/main`'s app theme check, the before / after comparison listed `com.srtflow.theme-checks.<UUID>.plist`; with
  the fix it listed nothing.
- A fake staged check app that writes and resets its domain like the check mains: through the new exit trap its plist was
  gone and still gone 25 s later; through `origin/main`'s trap a 42-byte plist stayed. Two such apps under a collecting entry
  point: no wait per app, one 15 s wait at the end, both plists gone 25 s later.
- The guard turned red when a check opened a raw suite again, when a `ScratchDefaults` was never removed, when a staged app
  got a non-check bundle id, when `remove_test_app` lost the removal, when `check-local.sh` stopped collecting, and when the
  bundle id filter accepted the real app.
- CI's full `check-all` ran on the PR.

## Lessons

- `removePersistentDomain(forName:)` and `defaults delete` empty a domain; they never delete its plist, and a plist deleted
  within about 10 s of the domain's last change comes back. Keep test preferences out of `~/Library/Preferences` instead
  of cleaning them up.
- The rule: [installed copies on the developer Mac](../build/build-and-packaging.md#installed-copies-on-the-developer-mac).
