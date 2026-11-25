# 2026-11-26 Developer ID signing, hardened runtime and notarization: what was proven

> Task SIGN1 (the user, 2026-11-25: sign the DMGs with the new Developer ID so they open directly). What was run on the
> owner's Mac in the night of 2026-11-26 (macOS 26.5.2, Command Line Tools only), what it showed, and what still waits
> for the user. The rules it led to: [code signing](../architecture/code-signing-and-permissions.md). Nothing was
> installed, uploaded to our servers or released; every test bundle was unregistered and deleted, except the one kept for
> the permission proofs (section 5). Times are UTC unless marked.

## 1. Signing

- codesign's first use of the Developer ID key raised the keychain dialog once; the user chose Always Allow (16:5x). Every
  later signing, about thirty of them, asked nothing.
- `scripts/build-app.sh` (VERSION `0.18.68-sign1test`) signed the app and its three helpers in about 10 s, each with a
  secure timestamp. `sign-app.sh`'s own checks passed on all four: `TeamIdentifier=26TVX3S9FR`, `flags=0x10000(runtime)`, a
  `Timestamp=`, the leaf certificate's SHA-1 equal to the pin, entitlements only on the app, and the designated
  requirement `… anchor apple generic … certificate leaf[subject.OU] = "26TVX3S9FR"`.
- The signed helpers run: `skycut-mcp` answers `initialize`, `skycut-web-motion` fed `{}` prints its result line, ffmpeg
  8.1 runs.

## 2. The hardened runtime: which feature needs which entitlement

### 2.1 The entitlement probe (no dialog)

A small probe app made only preflight calls, none of which can show a dialog: the microphone's `authorizationStatus`,
`AEDeterminePermissionToAutomateTarget` for Finder without asking, and `CGPreflightScreenCaptureAccess`. Three copies, all
signed with the Developer ID and launched through LaunchServices (so each is its own responsible process):

| Copy | Hardened runtime | Entitlements | tccd |
| --- | --- | --- | --- |
| c | no | none | nothing about entitlements |
| a | yes | none | «Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing», and the same for kTCCServiceAppleEvents and com.apple.security.automation.apple-events |
| b | yes | `packaging/SkyCut.entitlements` | nothing about entitlements |

- The preflight answers were the same for all three (microphone not determined, Apple Events «would ask the user», screen
  capture not granted). Preflight does not show the runtime's gate; tccd's prompting policy does: without the
  entitlement, macOS denies the resource without asking.
- Started from a terminal instead of LaunchServices, the same probe answered with the terminal's own grants: TCC credits a
  child process to the app that launched it. tccd named the probe as `requesting` in the microphone line and as `accessing`
  in the Apple Events line.
- Screen recording has no entitlement; it only needs the user's grant (section 5).

### 2.2 The features: a hardened build against an ad-hoc control

The same release build, staged as an E2E bundle (`com.srtflow.e2e<pid>.skystudiosmoke`, sandboxed home, fixture licence)
two ways: ad-hoc without the runtime (what `scripts/check-e2e.sh` does), and through `sign-app.sh` (Developer ID, runtime,
entitlements).

| Run | Ad-hoc control | Developer ID, hardened |
| --- | --- | --- |
| E2E MCP suite (`scripts/gui-smoke/e2e`): export through the audio engine's offline mix and ffmpeg (AAC, true peak), `inspect_video`, the reference cut with a web-motion render (all 6 page checks), pixels, subtitles, sound | passed, 18.6 s | passed, 21.4 s |
| Kokoro: one line with `af_heart` through `add_voiceover`, the installed model read through `SRTFLOW_VOICES_DIR` | 2.245 s of speech, mean −19.2 dB, max −3.2 dB | the same |

The helpers ran inside the hardened app as they ship: `skycut-mcp` as the client's server, `skycut-web-motion` for the
motion page, ffmpeg (a byte copy of the signed helper) for the encode.

Not run: real-time playback through the sound device (no MCP tool plays; sound output needs no entitlement, and the
offline render is the same engine); screen recording and the microphone with real grants (section 5).

## 3. Notarization

| Submission | Payload | Upload | Result |
| --- | --- | --- | --- |
| `1982777d` | `SkyCut.zip`, the first run | created 16:53:44, uploaded 17:02:51 (about 9 minutes through the Mac's proxy) | Accepted, «Ready for distribution», no issues; the ticket lists the app and its three helpers |
| `67762689` | `SkyCut.zip`, the clean re-run | created 17:06:56, uploaded 17:07:12 | Accepted, no issues |
| `706c6e87` | `SkyCut-0.18.68-sign1test-arm64.dmg` (42,482,286 bytes), signed by `sign-dmg.sh` | created 17:07:54, uploaded 17:08:09 | Accepted, no issues; the ticket lists the DMG, the app and its helpers |
| `3ed98f8c` | `SkyCut Beta.zip` (`build-beta-app.sh`) | created 17:08:52, uploaded 17:09:22 | Accepted, no issues |

Each was accepted within about a minute of its upload; the clean `build-app.sh` run took 1 min 57 s from start to the
stapled DMG (the compile was already up to date), `build-beta-app.sh` 1 min 7 s. After each submission `stapler staple`
and `stapler validate` worked and Gatekeeper accepted it (`spctl --assess`: «source=Notarized Developer ID»). Also:

- `codesign --verify --deep --strict` passes on the stapled app; `syspolicy_check distribution dist/SkyCut.app`: «App passed
  all pre-distribution checks and is ready for distribution.»
- `scripts/check-dmg.sh` passes on the notarized DMG.
- A simulated download: a copy of the DMG with a quarantine flag is accepted («Notarized Developer ID»); so are the app
  inside it once mounted (its own ticket validates) and a dragged-out copy of that app with a quarantine flag. Nothing was
  opened: Gatekeeper's question on first launch is for the user's real install.
- The Beta copy (`com.srtflow.SrtFlow.beta`) drops the release's stapled ticket (`Contents/CodeResources`) when it is
  re-signed and gets its own.

The first run broke after the DMG was created: the reverse-verification script (section 4) edited `scripts/build-app.sh`
while bash was still reading that file, so bash read a garbled line and the DMG was never signed. The pipeline was run
again from the start without touching any script. Never edit a script that a running build reads.

## 4. The guard, reverse-verified

`checks/release-signing.sh` with each rule broken on its own, then restored (scratch script; all restored green). All 22
went red: notarizing the app after the DMG is built; `build-app.sh` calling codesign itself; the Beta not notarized; no
profile check before the compile; no hardened runtime; no timestamp for the Developer ID; ad-hoc in the Developer ID branch;
entitlements on a helper; the app signed before a helper; stray code not refused (the fixture signed it); no team check
after signing; two pinned certificates; an expired pin falling back to ad-hoc; another certificate of the team falling
back to ad-hoc; another team's Developer ID refused instead of ad-hoc; a JIT exception; the microphone entitlement
removed; a camera usage description without its entitlement; notarytool given a password; no staple; Gatekeeper's
verdict not required; the DMG signed without a timestamp.

The first pass found one gap: an expired pin is also refused by the «another certificate of the team» branch, so
removing the expired-pin branch went unnoticed (its «renew it» advice was lost). Each refusal case now names the words its
message must say.

**After the first review (FBS1, 2026-11-26).** The review found three gaps, now closed:
- A Mac without the Developer ID, or a shell whose `security` failed, still produced an ad-hoc, release-named build with
  exit 0. `signing_mode` now treats a failing `security` as an error and refuses ad-hoc unless `SKYCUT_ALLOW_ADHOC=1`.
- `notarize.sh` and `sign-dmg.sh` lost the refusal's status (`[ "$(signing_mode)" != … ]`), so an expired certificate
  reached the compile. They now take `MODE="$(signing_mode)"` first, as `sign-app.sh` does.
- The guard matched substrings, so 21 of the review's 37 mutations stayed green, a commented-out notarization step among
  them. It now matches steps as whole lines, checks that each failure branch ends the run, reads backslash-continued
  `notarytool` commands whole, and runs the real scripts with stub `security`, `xcrun` and `codesign`.

Re-run: 48 sabotages, all red. That is the review's 21 green ones (commented-out or conditional steps, missing `exit 1`s, a
password on the command's second line, `signing_mode` short-circuited, `notary_profile_ready` returning at once, the leaf
comparison removed), seven for the new rules (opt-out, a failing `security`, the failed-build cleanup, the staple retry,
the kept refusals), and the first round's 20 on the new lines. Also new: a failed build deletes what it wrote in `dist/`,
and the staple is tried three times.

## 5. Waiting for the user: screen recording and the microphone

Both need the user's own grant for a Developer-ID-signed bundle (System Settings, a relaunch, the microphone's Allow), so
they were not run at night. Ready for the morning:

- The bundle «SkyCut Sign Check» at `/private/tmp/skycut-signcheck/SkyCutSignCheck.app`: the release build with its own
  identity (`com.srtflow.e2e2611.skystudiosmoke`), signed by `sign-app.sh` like a release. Its grants, settings and AI
  channel never touch the user's SkyCut. Never installed.
- The scripts, in the worktree's ignored `.build/permission-proof/`: `stage.sh` (stages and signs it again if
  `/private/tmp` was emptied), `permission-proof.py` (launches it through LaunchServices, records 3 s of a screen corner
  with the default microphone through `record_screen`, checks frames and real sound), `cleanup.sh` (quits it, resets its
  grants, deletes everything). A dry run up to `record_screen` worked (launched, licence read, project made) and tccd
  logged no prompt.
- The voice library's «Record now» needs a Sky Studio key, which the test identity does not have: it uses the same
  microphone service and entitlement as the recording's narration and is in the first real install's checklist
  ([code signing](../architecture/code-signing-and-permissions.md) section 五, item 4).

Results: not run yet (as of the night of 2026-11-26); they are added here after the run with the user.
