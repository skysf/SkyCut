# 2026-11-23 An upload that lost its connection ended the generation at once, and the error blamed Sky Studio

## Symptom

On 2026-11-23 image generation from the ChatGPT app through SkyCut's MCP failed twice (jobs generate-34 and generate-35). Each job
uploaded its 1,641,401-byte reference image to the signed storage address that Sky Studio's `POST /uploads` returned. The PUT
crawled and then lost its connection without an answer (`NSURLErrorDomain -1005`), and the job ended on the spot:

- get_job said "Could not reach Sky Studio: The network connection was lost.", although Sky Studio had answered `/uploads` and only
  the storage PUT had broken;
- its `next_step` told the AI to "Query this original job with get_job and preserve idempotency_key…", but nothing had been submitted,
  so there was no original job;
- the cloud task row showed that English sentence whatever the UI language.

Nothing was charged: no `/jobs` was sent. The second job (another model, the same reference) failed the same way.

## Root cause

1. **One PUT, never tried again.** `SkyStudioAPI.upload` sent the file as a single `uploadTask(fromFile:)` PUT. Any error other
   than a cancel became `SkyStudioFailure.network` and ended the upload. The system does not replay a body upload by itself (the
   system log showed "can retry(N)" for it), and SkyCut had no retry of its own.
2. **The uplink is slow and unstable, proxy or not.** An ops probe the same day sent twelve real signed PUTs to the same storage,
   alternating the system proxy and a direct path. All twelve worked, but throughput swung from 18 to 1,448 KB/s on both paths, and
   the 1.6 MB file took 3 to 90 s. A long single PUT can be cut either way, so the proxy is not the cause on its own.
3. **The words.** `SkyStudioJobError.message` said "Could not reach Sky Studio" for every network failure. The generation run showed
   that English text in the task row as it was. Its terminal `next_step` was the one written for jobs that had been submitted.

## Fix

- **`SkyStudioAPI.upload` tries a broken PUT again** (`SkyStudioUploadRetry`): URLError -1005, -1001 and -1009, and POSIX
  reset / abort / broken pipe / timeout / network down / unreachable / reset. Each new try runs on a fresh task after a 1 s, then
  2 s pause, three tries in all, at the same signed address while it stays valid (`SkyStudioUploadTicket`). The address is renewed
  from `/uploads` when less is left than the last try took plus 60 s; `expires_at` moves onto this Mac's clock with the answer's
  `Date` header. Progress starts again from 0. Never tried again: a storage answer, a cancel, an address or certificate failure,
  an unreadable file.
- **After the last try: `SkyStudioFailure.uploadInterrupted`** (`SkyStudioUploadInterruption`). The AI gets "The upload of X to Sky
  Studio was interrupted by the network after 3 tries; nothing was submitted and nothing was charged.", plus `code: upload_network`,
  `upload_attempts`, `upload_error`, `charged: false` and a `next_step` that says nothing was submitted and to call again once the user
  has checked the network. The user reads one localized line (`SkyStudioUploadWords`; English, 简体中文, Español) that names the
  network and never a proxy.
- **Wired into every job that uploads:** generate_media (task row; get_job, where the upload fields go in after the generic next
  step), upscale_clip and the upscale panel, change_voice and its notice, the voice library and manage_voices, manage_characters, and
  the official film's reference preparation. A cut sent under a temporary name is reported under the user's file name
  (`upload(named:)`).
- **For the post-merge smoke test against the real Sky Studio: `SRTFLOW_TEST_UPLOAD_DROPS=N`, debug builds only**
  (`CloudMedia/CloudUploadFault.swift`, the whole file inside `#if DEBUG`, reached only from `SkyStudioAPI.transfer` inside
  `#if DEBUG`). The first N PUT tries of the process are cut as soon as part of the body has gone out and end as URLError -1005,
  through the same classification as a real lost connection. `N=1` shows the retry working; `N=3` shows the localized failure with
  nothing charged. No network setting is touched. Release builds carry none of it: `scripts/check-sky-studio.sh` searches a build
  without DEBUG for its names (the debug build is the control), and `scripts/build-app.sh` refuses a release binary that names it.

Key files: `Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift`, `SkyStudioUploadRetry.swift`, `SkyStudioUploadWords.swift`,
`SkyStudioGenerationRun.swift`, `Upscale/UpscaleJob.swift`, `AIUpscaleTool.swift`, `VoiceChange/VoiceChangeJob.swift`,
`CloudMedia/CloudUploadFault.swift`.

## Verification

- `scripts/check-sky-studio.sh` → `UploadRetryChecks` runs the real transfer against a local 127.0.0.1 server
  (`checks/SkyStudio/UploadServer.swift`, no proxy) that reads the whole body and then drops (FIN) or resets (RST) the connection:
  - one or two drops, or one reset, then 200: the upload returns the first ticket's `file_url`. The same signed address is tried 2 or
    3 times with pauses `[1]` or `[1, 2]`; progress reads 0 right before each pause and ends at 1 (progress and pauses are logged in
    one order: a try can end before the system reports any send progress, so "a 0 right after a non-zero value" was a flaky first
    version of this check);
  - three drops: `uploadInterrupted` (3 tries, `NSURLErrorDomain -1005`, `upload_network`), never a fourth PUT;
  - 403: `.badAnswer(403)` after one PUT, no pause;
  - a cancel during the PUT, and a stop during the pause: CancellationError after one PUT;
  - 30 s left on the ticket: renewed (POST, PUT 1, POST, PUT 2, the second `file_url`). Sky Studio's clock an hour behind this
    Mac's: the address is reused;
  - pure: which errors are tried again, the deadline and the renewal rule, the AI's words and fields (no "original job", no proxy).
  All 8,345 checks pass.
- Reverse verification. Each mutation was applied on its own, the check run and seen red, then restored:
  - one try only: 12 red (one or two drops and the reset ended as `uploadInterrupted` after 1 try; the renewal, skew and pause checks);
  - a 403 treated as a broken try: 5 red (it was tried twice and then "worked"; the older `JobChecks` "a refused PUT fails" too);
  - a cancel treated as a broken try, with the loop's cancellation check removed: 1 red ("no pause after a cancel": pauses `[1, 2]`).
    The PUT itself was still not repeated, because `CloudTransfer.perform` refuses to start a cancelled task;
  - the old `.network` error after the last try: 1 red. No renewal: 2 red. The `Date` header ignored: 2 red (the skewed clock
    renewed a fresh address). No progress reset: 3 red (no 0 before the pauses);
  - wiring: generate_media's upload fields merged before the generic next step, the English message back in the task row, a second
    PUT in `UpscalePipeline`, the upscale's cut reported under its temporary name: each red.
- The debug-only hook, compiled with `-D DEBUG` (`checks/UploadFault/main.swift`, 14 checks, the local server reading 32 KB every
  10 ms). With one drop, the cut try arrives with part of its 2 MB body and the next one arrives whole at the same address. With
  three drops, the upload ends as `upload_network` after three tries, no try arrives whole, and the next upload in the process goes
  through. Unset, `""`, `0`, `abc` and `-2` drop nothing. The same script's build without DEBUG has no trace of the hook, and the
  control finds it in the debug build. Reverse:
  - the hook's file without its `#if DEBUG` fence: the leak probe red, and the wiring guard red;
  - no cut (the PUT runs whole, then -1005): 2 red (every try arrived whole);
  - the hook never consulted: 5 red;
  - `build-app.sh` not running `strings` on the release binary: the wiring guard red;
  - a blind probe (the names misspelled in the search): the control red, so the probe's silence on the build without DEBUG
    means something.
- `checks/sky-studio-wiring.sh` (section `checks/sky-studio-wiring/upload-retry.sh`) pins the single PUT inside the retry loop, each
  job's wiring, the hook's `#if DEBUG` fence (the whole file, and its one use in `SkyStudioAPI.transfer`) and both trace probes. It
  is green.
- A full `swift build --product SrtFlow` compiles every touched file, and `scripts/check-local.sh` runs the scan guards with the
  sky-studio, upscale, film-production and localization-coverage checks.
- **Not verified:** an upload over the user's real uplink (the checks use no real network), and the localized line at the default
  window size in each language. Both are on the manual list in [Sky Studio jobs](../architecture/sky-studio-jobs.md).

## Lessons

- A body upload over a consumer uplink needs its own retry, because the system never replays it and a slow PUT is the one most likely
  to be cut. Retry only what a second try can fix (connection lost, timed out, offline), never an answer or a cancel, and keep the
  same idempotent target.
- Name the step that failed. "Could not reach Sky Studio" for a storage PUT that broke sent people looking in the wrong place. A
  failure before submission must not get the "query the original job" next step.
- Long-term rule: [Sky Studio jobs](../architecture/sky-studio-jobs.md), section 1, "Uploads that the network interrupts".
