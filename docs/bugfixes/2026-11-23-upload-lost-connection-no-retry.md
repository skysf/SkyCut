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

- **`SkyStudioAPI.upload` tries a broken PUT again** (`SkyStudioUploadRetry`).
  - Retried: URLError -1005, -1001 and -1009, and POSIX reset / abort / broken pipe / timeout / network down / unreachable / reset.
  - Each new try runs on a fresh task after a 1 s, then 2 s pause, three tries in all, at the same signed address while it is known
    to stay valid (`SkyStudioUploadTicket`). Progress starts again from 0.
  - The address is renewed from `/uploads` when less is left than the last try took plus 60 s, or when the answer had no readable
    `expires_at`. `expires_at` moves onto this Mac's clock with the answer's `Date` header.
  - Never tried again:
    - an answer the storage began, even when its body then broke or stalled, and even when only its head came, which the system
      holds back: the task's metrics show it. The answer is read before the error: a 2xx is success, anything else is refused;
    - a redirect: the signed PUT never follows one, so one try is one PUT;
    - a cancel;
    - a connection that does not work at all (address, certificate, TLS), on the PUT or while renewing;
    - an unreadable file.
- **Giving up is `SkyStudioFailure.uploadFailed`** (`SkyStudioUploadFailure`), of four kinds:
  - interrupted (`upload_network`);
  - could not connect (`upload_network`), also when the first `/uploads` ask could not connect;
  - refused by the storage, with its status, or 0 when the answer did not come through (`upload_refused`);
  - declined by Sky Studio (`upload_declined`): `/uploads` refused it or answered without an address. Sky Studio's own refusal is
    kept, so the voice library still names it.
  - What the AI gets: plain English words, the code, `upload_attempts` (PUTs only, never renewals), `upload_error`, `charged: false`,
    and a `next_step` that says nothing was submitted.
  - What the user reads: one localized line per kind (`SkyStudioUploadWords`; English, 简体中文, Español), naming the network and
    never a proxy.
- **Wired into every job that uploads:**
  - generate_media. Its task row shows the line. Its get_job gives any job that ended before its request left this Mac a next step
    saying nothing was submitted, so never "query this original job"; the upload fields then go in last.
  - upscale_clip and the upscale panel;
  - change_voice and its notice;
  - the voice library and manage_voices;
  - manage_characters;
  - the official film's reference preparation, whose row now stays with the line.
  - A cut sent under a temporary name is reported under the user's file name (`upload(named:)`).
- **For the post-merge smoke test against the real Sky Studio: `SRTFLOW_TEST_UPLOAD_DROPS=N`, debug builds only.**
  - Where it lives: `CloudMedia/CloudUploadFault.swift`, the whole file inside `#if DEBUG`, reached only from `SkyStudioAPI.put`
    inside `#if DEBUG`.
  - What it does: the first N PUT tries of the process are sent as a stream holding only the first quarter of the file (at most
    256 KB) under the whole file's Content-Length, so they can never complete. Each is cut once that part is out and ends as URLError
    -1005, on the same path as a real lost connection.
  - Release builds carry none of it: `scripts/debug-hook-probe.sh` refuses a binary that names it. It runs on the release binary in
    `scripts/build-app.sh`, and `scripts/check-sky-studio.sh` runs it on a build without DEBUG (must pass) and on a debug build (must
    be refused: the control).
- **What the first version missed.** Head `8f0ca09f` passed CI; the review (Codex, reproduced on a loopback) found four gaps, all fixed
  above:
  1. A 403 whose error body then stalled was retried, because the status was checked only after the transfer, which threw a
     transient error first. The second try's 200 was then taken as success.
  2. A certificate failure while renewing the address was retried as if transient, and `upload_attempts` counted renewals: one PUT
     and two renewals were reported as 3. An answer without `expires_at` reused an address of unknown validity.
  3. Only the network interruption had the localized line and a correct next step. A TLS failure on the first PUT still showed
     English "Could not reach Sky Studio", a direct 403 still said "query the original job", and the official preparation's row
     disappeared before anyone could read its line.
  4. The guards had gaps:
     - no case for a 403 with a broken body, and no failing renewal;
     - the packaging guard grepped for lines, so removing the refusal's `exit 1` stayed green;
     - the debug-hook check cut the real PUT by watching the bytes sent, so on a fast link the whole body could already be out (it
       once delivered all 2,000,000 bytes).
- **What the second version missed.** Codex re-checked `4b636f4e` (reproduced on a loopback) and found five gaps, all fixed above:
  1. A 403 whose head came and whose body never did was still retried. The system holds such an answer back while it waits for body
     bytes to sniff, so `task.response` was nil. A local probe confirmed that only the metrics' `responseStartDate` shows the answer
     began (with 1 KB of body the 403 is delivered, which is all the earlier check sent).
  2. A 307 / 308 was followed, so two PUTs went out and `upload_attempts` said 1. Now redirects are not followed: a signed address does
     not redirect.
  3. A `/uploads` 413, or a 200 without an address, bypassed the upload error. The generation row was in English, and the film
     preparation's row and next step were skipped. Those failures are now "declined".
  4. The guard did not see the unsubmitted-job next step removed while its `if` stayed. The step is now pinned as the line right
     inside the `if`.
  5. When a dropped try failed before its body, the hook's watcher spun until its 5 s deadline: `try?` swallowed the cancelled sleep,
     at about 5 CPU s each time. It now stops when the try has ended and honours cancellation.

Key files: `Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift`, `SkyStudioUploadRetry.swift`, `SkyStudioUploadFailure.swift`,
`SkyStudioUploadWords.swift`, `SkyStudioGenerationRun.swift`, `SkyStudioOfficialPreparation.swift`, `Upscale/UpscaleJob.swift`,
`AIUpscaleTool.swift`, `VoiceChange/VoiceChangeJob.swift`, `CloudMedia/CloudTransfer.swift` (redirects, the answer from the metrics),
`CloudMedia/CloudUploadFault.swift`, `SkyStudioVoiceLibraryErrors.swift` / `VoiceLibrary/VoiceLibraryText.swift` (a kept refusal),
`scripts/debug-hook-probe.sh`.

## Verification

- `scripts/check-sky-studio.sh` runs the real transfer against a local 127.0.0.1 server (`checks/SkyStudio/UploadServer.swift`, no
  proxy). 8,436 checks pass, three runs in a row of one binary.
  - `UploadRetryChecks`:
    - one or two drops, or one reset, after the body, then 200: the first ticket's `file_url`, the same address tried 2 or 3 times,
      pauses `[1]` or `[1, 2]`, and progress at 0 right before each pause and ending at 1. Progress and pauses are logged in one
      order: a try can end before the system reports any send progress, so "a 0 right after a non-zero value" was a flaky first
      version of this check;
    - three drops: interrupted, 3 PUTs, `NSURLErrorDomain -1005`, never a fourth;
    - pure: which errors are tried again and which end the upload, the deadline and the renewal rule (including an unknown expiry),
      and each kind's words and fields (no "original job", no proxy).
  - `UploadAnswerChecks`:
    - a 403, and a 403 whose body was reset or stalled into a timeout (a 1.5 s PUT timeout in the check): refused after one PUT, no
      pause;
    - a 403 whose head came and whose body never did: refused (status unread) after one PUT, no pause;
    - a 307 and a 308: refused, with no second PUT to the new address;
    - `/uploads` answering 413, a 200 without an address, or Sky Studio's own 503 `voice_library_unavailable`: declined before any
      PUT. The refusal is kept (`server_code`), and `SkyStudioVoiceLibraryErrors.kind` still says unavailable;
    - a 200 whose body was reset or stalled: success after one PUT;
    - a TLS failure on the PUT (an https address on the plain server): could not connect, one PUT, no pause. The system itself may
      open a second connection inside its handshake, so SkyCut's tries are what is counted;
    - a cancel during the PUT, and a stop during the pause: CancellationError after one PUT;
    - addresses: 30 s left renews, an unknown expiry renews, and a server clock an hour behind reuses;
    - renewals: one broken renewal costs a try and the next renews and sends; two broken renewals end as interrupted with
      `upload_attempts` 1; a refused renewal (the server stops listening during the pause) ends as could not connect, with no other
      ask and no second PUT.
- The debug-only hook (`checks/UploadFault/main.swift`, compiled with `-D DEBUG`, the server reading 32 KB every 10 ms), 16 checks,
  stable over repeated runs:
  - with one drop, the cut try arrives with more than 0 and at most 262,144 bytes of the 2 MB body, and the next arrives whole;
  - with three drops, the upload ends as interrupted after three cut tries, none whole and none over its part (the check waits for
    the slow server to log the last one), and the next upload goes through;
  - a drop whose connection failed before the body (its TLS fails) leaves nothing spinning: under 0.3 CPU s in the next second;
  - garbage values drop nothing;
  - the probe passes the build without DEBUG and refuses the debug build.
- A real `swift build -c release` (first round, on `8f0ca09f`): `strings -a` finds no trace of the hook in the release binary, also
  after `strip -xS`, and finds it in the debug binary.
- Reverse verification. Each mutation was applied on its own, the check run and seen red, then restored.
  - First round:
    - one try only: 12 red;
    - a 403 treated as a broken try: 5 red;
    - a cancel treated as a broken try, with the loop's cancellation check removed: 1 red ("no pause after a cancel"; the PUT itself
      was still not repeated, because `CloudTransfer.perform` refuses to start a cancelled task);
    - the old `.network` error after the last try: 1 red;
    - no renewal: 2 red;
    - the `Date` header ignored: 2 red;
    - no progress reset: 3 red;
    - four wiring mutations: each red;
    - the hook without its fence: the probe and the guard red;
    - the hook never consulted: 5 red;
    - a blind probe: the control red.
  - After the review (eight mutations):
    - the answer no longer read before the error: 7 red. A 403 whose body stalled into a timeout was tried again and the second try's
      200 taken as success, the review's exact case, and a 200 that stalled was sent twice. A body cut by a reset surfaced no error
      in the system's stack, so those cases pass both ways; the stall cases are the guard;
    - every transport error treated as transient: 8 red. Certificate, TLS, DNS and unparseable-answer errors were classified as broken,
      the TLS PUT was tried three times, and the refused renewal was retried;
    - loops counted instead of PUTs: 2 red;
    - an address of unknown validity reused: 4 red;
    - generate_media's next step for an unsubmitted job removed, and the official row's line removed: the wiring guard red for each;
    - the probe without its `exit 1`: the control red ("passed the debug build");
    - the hook streaming the whole file: 2 red (cut tries arrived whole).
  - After the second review (five mutations):
    - an answer whose head alone came, no longer counted as an answer: 6 red (retried, and the second try's 200 taken as success);
    - redirects followed: 8 red (a 307 or 308 sent a second PUT and "worked");
    - `/uploads` failures left unwrapped: 10 red (the 413 and Sky Studio's own refusal escaped the upload error);
    - the unsubmitted-job next step removed with its `if` kept: the wiring guard red;
    - the hook's watcher spinning again: 0.83 CPU s in 1 s, red.
- `checks/sky-studio-wiring.sh` (section `checks/sky-studio-wiring/upload-retry.sh`) is green. It pins:
  - the single PUT inside the retry loop, with the answer read first;
  - each job's wiring;
  - the next-step order in generate_media;
  - the official row;
  - the hook's `#if DEBUG` fence;
  - the probe calls.
- A full debug `swift build --product SrtFlow` compiles every touched file. `scripts/check-local.sh` runs the scan guards with the
  sky-studio, upscale, film-production, localization-coverage and voice-recovery checks.
- **Not verified:** an upload over the user's real uplink (the checks use no real network), and the localized lines at the default
  window size in each language. Both are on the manual list in [Sky Studio jobs](../architecture/sky-studio-jobs.md). The smoke
  hook is for that run.

## Lessons

- A body upload over a consumer uplink needs its own retry, because the system never replays it and a slow PUT is the one most likely
  to be cut. Retry only what a second try can fix (connection lost, timed out, offline), never an answer or a cancel, and keep the
  same idempotent target.
- Read the answer before the error that followed it: once the storage has spoken, a broken body is not a broken connection. Count what
  the user means by a try (a PUT), and never reuse an address you cannot prove is still valid.
- A guard that greps for a line cannot see a missing `exit 1`. Run the thing against a case that must be refused, and give a test hook
  a construction that cannot succeed (a body that cannot complete), not a race it usually wins.
- Name the step that failed. "Could not reach Sky Studio" for a storage PUT that broke sent people looking in the wrong place. A
  failure before submission must not get the "query the original job" next step.
- Long-term rule: [Sky Studio jobs](../architecture/sky-studio-jobs.md), section 1, "Uploads that the network interrupts".
