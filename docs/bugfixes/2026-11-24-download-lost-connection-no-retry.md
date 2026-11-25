# 2026-11-24 A paid result whose download lost its connection was never saved, and trying again meant paying again

## Symptom

Backlog B40, found in the review of PR #549 (uploads that lose their connection). On this Mac the link to Sky Studio's storage is
slow and unstable, with or without a proxy (an ops probe on 2026-11-23 measured 18 to 1,448 KB/s and dropped transfers). Uploads got
retries in #549; downloads did not.

- Every paid output comes to this Mac through `SkyStudioAPI.download` after Sky Studio made it and charged for it: a generation and
  its caption, the official recovery, voiceover batches, an upscale, a voice change's two files.
- One dropped connection while the result came down ended the job on the spot. generate_media's get_job said "Could not reach Sky
  Studio: The network connection was lost." and "Query this original job with get_job", but get_job only read the original job again:
  nothing downloaded the result.
- A failed upscale or voice change offered nothing either: the only way to "try again" was a new upscale_clip, change_voice or panel
  run, which is charged again. A voice change's result is not even in the Sky Studio library (it is kept 60 days under the job).
- The task row showed the English sentence whatever the UI language.

## Root cause

1. **One GET, never tried again.** `download` ran a single `downloadTask`; any error other than a cancel became
   `SkyStudioFailure.network`. The system does not replay a download by itself, and the resume data it puts in the error was thrown
   away. Only the voice change looped on its own (three tries, any error, a 403 included, from scratch).
2. **No way back to the same result.** The flows treated a failed download as the job's end. The result's address was kept only in
   get_job's `remote_result`, and no tool, button or recovery downloaded it again (only voiceover's recovery file and the official
   receipt could, by design).
3. **An expired address was a dead end.** A 403 / 404 from the storage ended the download; nothing asked the job for a fresh address.
4. **The first fix (PR #554 at `19e1112f`) looked done and was not** (Codex's review, reproduced on loopback):
   - **A short 206 became the result.** It trusted any 2xx with a non-empty file. A resumed answer `bytes 100000-249999/1000000` was
     moved into place as a 250,000-byte result at 100%: URLSession completes such an answer as if it were whole.
   - **The HTTP answer was not always read first.** An error answer whose body stalls times out with its status held back
     (`task.response` nil; a probe showed the task's metrics carry no status either, only that an answer began), so a stalled 403 was
     counted as broken and the old address was fetched again instead of the job's current one.
   - **Redirects multiplied the GETs.** The system followed them inside one task: three tries sent six GETs.
   - **Download again was not the same paid job on every path.** Upscale and voice change downloaded the address held from the first
     try (an expired one stayed expired); a stop during a voice change's Download again was reported as a save failure, and upscale's
     Cancel removed the job with its button. generate_media bound the idempotency_key into the request's identity, so the key SkyCut
     returned for a keyless first call was refused as "different inputs" and a keyless re-ask minted a new key, a new paid job; a
     dismissed row took the held run with it; official generation and recovery answered from their cached answer and never downloaded
     again. Voiceover's failed row had no button, and the upscale / voice change panels let Start pay again for the same input (B47).
   - **The day's books kept the reservation.** An upscale settled Sky Studio's charge only after a saved file: 75 reserved, 72
     charged, and a failed download left 75 on the books.
   - **The words promised what did not work.** Same-key advice for official requests, "also at the fresh address" when the address
     had not changed, "charged" while billing could still be pending, and an SRT failure pointing at get_job, which never fetches it.
   - Why the checks stayed green: the fake server always completed a 206 to the end of the file, had no stalled error answer and no
     redirect, the order of the HTTP checks was pinned only by a source scan, and Download again was exercised only through one flow's
     button (voice change).

## Fix

- **`SkyStudioAPI.download` resumes or retries a broken GET** (`SkyStudioDownloadRetry`): three GETs in all, 1 s and 2 s apart,
  "broken" by the upload's own rule (`SkyStudioUploadRetry.isTransient`).
  - The next GET resumes from the system's own resume data (Range / If-Range; progress goes on from the offset via
    `didResumeAtOffset`); with none kept it starts again from 0. A local probe confirmed URLSession's behaviour: a drop mid-body gives
    -1005 with resume data when the server sends an ETag and Accept-Ranges, a resumed task reports `didResumeAtOffset` and counts
    `totalBytesWritten` from there, a server that ignores the Range resumes at 0, and resume data from anywhere else raises an
    Objective-C exception (so only the error's own is ever used).
  - An HTTP answer is never tried again as it is, even when its body broke after the head. A 403 / 404 / 410 asks the original job
    once for a fresh address (`renew`, `GET /jobs/{id}`) and tries it when it differs and a try is left; any other answer, a cancel
    and a connection that does not work end the download.
  - The partial file beside the destination is moved over only when whole, as before.
- **Giving up is `SkyStudioDownloadFailure`** (`download_network` / `download_refused`, `download_attempts`, `download_error`), an
  English message and a next step saying the result was made and charged once and how to get it again at no charge, and one
  localized line per kind for the user (`SkyStudioDownloadWords`, en / zh-Hans / es).
- **The paid result is kept for Download again**, the same result under the same AI job id (`AIJobs.reopen`; the keep-awake guard
  allows that one more lease, returned by `finish`):
  - generate_media (`SkyStudioGenerationRun.retryDownload`; also generate_media called again with the same idempotency_key, which
    answers `downloading_again`);
  - the official recovery (its row runs the recovery again);
  - upscale, panel or AI (`UpscaleJob.retryDownload` runs `UpscalePipeline.deliver` again: download, original sound, save);
  - voice change (`VoiceChangeJob.retryDownload`: download and land as one undo step); its own retry loop is gone;
  - voiceover batches show the line and the code; `add_voiceover resume=recovery_file` downloads them again, as before.
  - Every flow passes `renew:`. The task rows show **Download again** (`SkyStudioMediaStatus.retryDownload`,
    `UpscaleJob.canRetryDownload`).
- **For the post-merge smoke test against the real Sky Studio: `SRTFLOW_TEST_DOWNLOAD_DROPS=N`, debug builds only**
  (`CloudMedia/CloudDownloadFault.swift`, the whole file inside `#if DEBUG`, reached only from `CloudResultDownload.fetch` inside `#if DEBUG`).
  The first N GETs are cancelled with the system's resume data once a quarter of the body (at most 256 KB) arrived and end as -1005.
  `scripts/debug-hook-probe.sh` now refuses a binary naming this hook too, and `scripts/check-sky-studio.sh` requires its refusal of the
  debug build to name both hooks.

**Second round, after the review of #554:**

- **The GETs moved into `CloudMedia/CloudResultDownload.swift`** (`SkyStudioAPI.download` hands every paid result to it; the API file
  went from 507 to 416 lines):
  - whole before it is moved: `SkyStudioDownloadRetry.incompleteness` (a 206 must reach the last byte with `total` bytes on disk, a 200
    with a length must hold it, sizes not compared under a Content-Encoding); anything else is thrown away and the result started
    again. Progress counts against the whole length (the Content-Range total), so a short 206 never reads 100%;
  - an answer that began but whose status was held back (`CloudTransferDelegate.answerStarted`) asks the job for its current address
    first and goes there when it differs; otherwise it is tried again after a pause;
  - `followsRedirects: false`: a 3xx with a Location is followed by the next GET, which counts (`redirectTarget`, http(s) only);
  - the refusal says "also at the fresh address" only when a GET went to one (`triedFreshAddress`).
- **Every Download again reads the original job's current result first**, then downloads with `renew:`: generation, the official
  recovery (it GETs the job first, as before), upscale, voice change; voiceover's recovery GETs its original jobs.
- **Held whatever kept it from landing.** A stop while downloading is `download_stopped` (`SkyStudioDownloadFailure.stopped`) and keeps
  the result held in every flow, as does a local step after the download (an upscale's sound or save, a voice change's files).
  Upscale: Cancel during a paid download stops it and keeps the job listed (`UpscaleJob.downloadsPaidResult`).
- **The same paid job on every way back:**
  - generate_media: the key is no longer part of a request's identity (`SkyStudioGenerationRequests.identity`); `heldAnswer` sends the
    same request, with the key SkyCut returned or with none, to Download again under the same job id; held runs are registered by job
    id (`SkyStudioHeldDownloads`), so the re-ask works after the row was dismissed; official generation and recovery find theirs from
    the cached answer (`heldAnswer(for:)`). The delivery (download, image format, WebM copy, SRT, official receipt, music) moved into
    `SkyStudioGenerationDelivery` (the run was at 577 of 600 lines), which Download again runs again; a missing SRT is held on its
    own, and the re-ask fetches only it;
  - upscale and voice change (B47): upscale_clip and change_voice asked for the same input, and both panels, offer Download again (the
    paid button gives way to it, with an orange line) instead of a new paid job; a dismissed held upscale stays findable for them, and
    the upscale inspector shows Download again too;
  - voiceover: the failed row's Download again runs the same local recovery as `add_voiceover resume=recovery_file`
    (`generate_missing` off).
- **The day's books take Sky Studio's charge when the result is made** (`UpscalePipeline.run`'s `onMade`, `UpscaleJob.settleMade`),
  before any download.
- **Words**: the message and next step no longer assert a charge (billing may be pending; the job's billing fields say it), the
  official next step names its film arguments and key, and an SRT failure says that the same request fetches only the SRT.

Key files: `Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift` (`download`), `CloudMedia/CloudResultDownload.swift`, `SkyStudioDownloadRetry.swift`,
`SkyStudioDownloadFailure.swift`, `SkyStudioDownloadWords.swift`, `SkyStudioHeldDownloads.swift`, `SkyStudioGenerationRequests.swift`,
`SkyStudioGenerationRun.swift`, `SkyStudioGenerationDelivery.swift`, `SkyStudioGenerateTool.swift`, `SkyStudioOfficialGenerateTool.swift`,
`SkyStudioOfficialRecoveryRun.swift`, `SkyStudioMediaStatus.swift`, `SkyStudioVoiceCloudBatches.swift`, `SkyStudioVoiceoverRun.swift`,
`Upscale/UpscalePipeline.swift`, `Upscale/UpscaleJob.swift` (and `UpscaleActivity`), `Upscale/UpscalePanel.swift`,
`Upscale/UpscaleJobStatusView.swift`, `AIUpscaleTool.swift`, `VoiceChange/VoiceChangeJob.swift`, `VoiceChange/VoiceChangeActivity.swift`,
`VoiceChange/VoiceChangeTool.swift`, `VoiceChange/VoiceChangePanel.swift` / `VoiceChangePanelModel.swift`, `CloudMedia/CloudTransfer.swift`
(`didResumeAtOffset`, the whole length, `answerStarted`), `CloudMedia/CloudTaskRows.swift`, `AIJobs.swift` (`reopen`),
`CloudMedia/CloudDownloadFault.swift`.

## Verification

- `scripts/check-sky-studio.sh` → `DownloadRetryChecks`, real GETs against the local 127.0.0.1 server (`UploadServer.swift` now
  serves results with an ETag and Range support):
  - one drop mid-body: two GETs, the second with `Range: bytes=N-` and the ETag as If-Range, pause `[1]`, progress never going back,
    the file byte-identical; without validators the second GET asks for all of it and progress goes back to 0; a reset, a cut of the
    resumed GET, then the rest: three GETs, pauses `[1, 2]`, identical;
  - three drops: interrupted, 3 GETs, `NSURLErrorDomain -1005`, `download_network`, no file and no partial; a later download of the
    same address gives the identical file;
  - a 403 then a fresh address: renewed once, old then fresh address, no pause, identical; a 404 without renewal, and a 404 whose body
    broke after its head: refused after one GET; a renewal to the same address: refused, one GET; 403 then 410 at the fresh address: refused after two GETs, renewed once; a
    500: refused after one GET, nothing renewed; a TLS failure: could not connect, one GET;
  - a cancel while the body stalls stops in under 2 s and leaves nothing; a cancel during the pause sends no second GET;
  - the words and fields per kind (no proxy, the next step), and the old 404 case in `JobChecks` reads as `download_refused`.
- The hook's checks (`checks/UploadFault/DownloadFaultChecks.swift`, in the `-D DEBUG` binary, the server sending 32 KB every 10 ms):
  one cut resumes mid-body and the file is identical; three cuts end as interrupted and the next download is not cut; a 10 KB body
  whole before the cut is still dropped and comes again whole; a 404 stays a 404; a cut GET whose TLS fails leaves nothing spinning
  (under 0.3 CPU s in the next second); garbage values cut nothing.
- `scripts/check-voice-recovery.sh` → `VoiceChangeDownloadChecks` (real App objects, the fake Sky Studio): three lost connections fail
  the voice change with `download_network`, three GETs, the timeline untouched, charged once; the row reads the localized line;
  Download again runs the same job id, lands the byte-identical files with no new upload or `/jobs`, one undo; an expired voice
  address (403) is renewed with exactly one `GET /jobs/convert-1`. Every keep-awake lease came back (the existing end check).
- `checks/sky-studio-wiring/download-retry.sh`, `checks/ai-keep-awake.sh` (reopen's lease) and the upload section's probe pin.
- Reverse-verified: each mutation applied alone, its check seen red, the file restored (see the report for the list).

Second round (the local server now also answers a short 206, a stalled error answer and a redirect: `UploadServer.swift`):

- `DownloadRetryChecks`: the short 206 (`bytes 100000-249999/1000000` after a cut) is thrown away, never reads 100%, and the next GET
  fetches the whole file byte-identical (three GETs: cut, short, whole); a 403 whose body stalls goes to the job's fresh address at
  once (old then fresh, no pause), and to the same address again after a pause when the job has no other; a redirect, a cut, then the
  rest is three GETs with the target resumed; a redirect then drops is three GETs, not six; the same address from the job is never
  called a fresh one; the wholeness rule, Content-Range and redirect targets as pure checks.
- `HeldDownloadChecks`: the key and confirm token are not part of a request's identity; the returned key and no key each start the held
  Download again once (a second re-ask while it runs starts nothing); another request, key or scope does not; an official cached answer
  finds its held job.
- `scripts/check-voice-recovery.sh` (real App objects):
  - `GenerationDownloadChecks`, the real `SkyStudioGenerationRun` on a loopback fixture: three drops hold it (both ways back named);
    the row dismissed, the re-ask saves the byte-identical file under the same job id, reading the job first; a stop keeps it
    (`download_stopped`) and the next press saves it; a missing SRT is fetched alone; one `/jobs` each;
  - `VoiceChangeDownloadChecks`: change_voice asked for the same change downloads it again under the same job id (no quote, upload or
    `/jobs`; the job read first; one undo); a stop during Download again keeps the button; the panel offers Download again for the
    same clip and voice only;
  - `UpscaleJobDownloadChecks`, the real `UpscaleJob` and `UpscaleActivity`: three drops hold it with the books at 72 of the 75 reserved;
    Cancel while it downloads again keeps it listed and stopped; dismissed, it is still found for the panel and upscale_clip (the same
    size only), and their Download again lists it again, reads the job first and saves it, one upload and one `/jobs` in all;
  - `VoiceoverDownloadChecks`: a batch whose download gave up fails with `download_network`; the row's Download again runs the recovery,
    which lands the voiceover with no new batch.
- `scripts/check-upscale.sh` → `DownloadChecks`: the charge (72) handed over before any download; three drops held with the job, the
  charge and the offset; Download again saves it with no new upload or job; a stop held.
- Reverse-verified (each mutation's own FAIL line seen, the files restored; independent mutations batched per run, dependent ones in
  runs of their own), 21 behaviour mutations: a short 206 accepted; a held-back answer treated as broken; the system following
  redirects; "fresh address" said without a fresh GET; the key back in the identity; the keyless re-ask not matched; an official
  cached answer not held (check-sky-studio); the charge handed over only after the download; a stop dropping the result
  (check-upscale); the held row not registered for the re-ask; a generation stop not held; the missing SRT not held; the generation's
  Download again not reading the job; the upscale's charge not settled when made; Cancel removing a downloading paid upscale; a
  dismissed held upscale forgotten; the upscale's Download again not reading the job; the voiceover row without Download again; a
  voice change stop read as a save failure; change_voice paying again; the panel not seeing the held change; the voice change's
  Download again not reading the job (check-voice-recovery). And 12 wiring mutations in `download-retry.sh` (wholeness, redirects,
  the held-back answer, the re-ask order, the official answer, voiceover's button, the change_voice interlock, settling when made, a
  generation stop, Cancel / Dismiss / relisting of a held upscale).

## Lessons

- A download after payment is the most expensive step to lose: retry what a second try can fix, resume when the system kept the
  bytes, renew an expired address from the job, and never answer a failure by submitting again.
- "Query the original job" is not a recovery if nothing downloads its result: every flow that holds a paid result needs a way to
  fetch the same result again, and the next step must name it.
- Two retry loops multiply: when the transport retries, remove the callers' own loops.
- "Completed" is not "whole": check a resumed answer's range and the bytes on disk against the total before it becomes the result.
- A held paid result must be reachable from every way the user or the AI asks again (the row, the same request with or without its
  key, the panel, a stop in between), and survive the row being dismissed; a way back that misses one path is a second charge.
- A fake server that only resumes the happy way proves little: give it the edges the real network gives (a short 206, a stalled
  error body, a redirect) before trusting the retry logic.
- The long-term rules are in [Sky Studio jobs](../architecture/sky-studio-jobs.md), "Downloads that the network interrupts".
