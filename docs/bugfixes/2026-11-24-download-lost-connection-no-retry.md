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
  (`CloudMedia/CloudDownloadFault.swift`, the whole file inside `#if DEBUG`, reached only from `SkyStudioAPI.fetch` inside `#if DEBUG`).
  The first N GETs are cancelled with the system's resume data once a quarter of the body (at most 256 KB) arrived and end as -1005.
  `scripts/debug-hook-probe.sh` now refuses a binary naming this hook too, and `scripts/check-sky-studio.sh` requires its refusal of the
  debug build to name both hooks.

Key files: `Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift` (`download`, `fetch`), `SkyStudioDownloadRetry.swift`,
`SkyStudioDownloadFailure.swift`, `SkyStudioDownloadWords.swift`, `SkyStudioGenerationRun.swift`, `SkyStudioGenerateTool.swift`,
`SkyStudioOfficialRecoveryRun.swift`, `SkyStudioVoiceCloudBatches.swift`, `SkyStudioVoiceoverRun.swift`, `Upscale/UpscalePipeline.swift`,
`Upscale/UpscaleJob.swift`, `AIUpscaleTool.swift`, `VoiceChange/VoiceChangeJob.swift`, `CloudMedia/CloudTransfer.swift`
(`didResumeAtOffset`), `CloudMedia/CloudTaskRows.swift`, `AIJobs.swift` (`reopen`), `CloudMedia/CloudDownloadFault.swift`.

## Verification

- `scripts/check-sky-studio.sh` → `DownloadRetryChecks`, real GETs against the local 127.0.0.1 server (`UploadServer.swift` now
  serves results with an ETag and Range support):
  - one drop mid-body: two GETs, the second with `Range: bytes=N-` and the ETag as If-Range, pause `[1]`, progress never going back,
    the file byte-identical; without validators the second GET asks for all of it and progress goes back to 0; a reset, a cut of the
    resumed GET, then the rest: three GETs, pauses `[1, 2]`, identical;
  - three drops: interrupted, 3 GETs, `NSURLErrorDomain -1005`, `download_network`, no file and no partial; a later download of the
    same address gives the identical file;
  - a 403 then a fresh address: renewed once, old then fresh address, no pause, identical; a 404 without renewal: refused after one
    GET; a renewal to the same address: refused, one GET; 403 then 410 at the fresh address: refused after two GETs, renewed once; a
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

## Lessons

- A download after payment is the most expensive step to lose: retry what a second try can fix, resume when the system kept the
  bytes, renew an expired address from the job, and never answer a failure by submitting again.
- "Query the original job" is not a recovery if nothing downloads its result: every flow that holds a paid result needs a way to
  fetch the same result again, and the next step must name it.
- Two retry loops multiply: when the transport retries, remove the callers' own loops.
- The long-term rules are in [Sky Studio jobs](../architecture/sky-studio-jobs.md), "Downloads that the network interrupts".
