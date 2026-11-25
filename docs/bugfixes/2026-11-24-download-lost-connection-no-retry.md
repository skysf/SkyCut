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
5. **The second round (`89b11755`) matched new requests to old held jobs by their parameters, and that handed back wrong results**
   (Codex's re-check, reproduced with a local fake server, a test account and separate projects):
   - generate_media's key left the request's identity and a key-less call was matched by its arguments: after the canvas went from
     16:9 to 9:16, a new image request got the old 16:9 image; change_voice and its panel matched by clip, voice and option but not
     language or source range, so a Chinese change got the old English one; upscale_clip and its panel matched by file, range, tier
     and target but not project, so project B's request replaced project A's clip and B got nothing. Repeats still started paid jobs
     where the match missed (one held change per clip: two options, then the first again, made three paid POSTs).
   - Download again was not kept until the result came down: starting it released the held entry (a key-less re-ask then paid again);
     an empty 200 was not a download failure and lost the entry; a 503 while re-reading the official job lost the recovery's entry,
     after which the same key only returned the cached `recovering`; voiceover's old row re-ran its recovery from a stale copy of the
     record after `add_voiceover resume` had landed it (one segment became two), and a user's stop during the download removed the
     button.
   - Wholeness and answers: a gzip 206 skipped the size comparison (a 206 `bytes 29-57/58` decoded to 1,000 bytes overwrote a whole
     2,000-byte file); a 500 whose body stalled, with the same address from the job, was fetched three times; every stop said 0 GETs.
   - The upscale's books read only the top-level `credits_charged`: with only `billing.credits_charged` (72 of 75) they stayed at 75,
     and Download again's re-read did not update the reported charge.
   - The words still said a key-less repeat downloads the same result at no charge, which was not always true.
   - Why the checks stayed green: the re-ask checks called the lookup functions directly instead of the tool entries that submit
     orders, and the upscale ledger fixture always sent both charge fields.
6. **The narrowed round (`36ad1d9e`) still lost data in two ways and settled a bill under review** (Codex's re-check CXD3, with
   repros):
   - A gzip 206 `bytes 29-52/53` (the server ignored identity) decoded to exactly 53 bytes, so the size comparison passed and it
     overwrote an existing, complete 2,000-byte file on the first GET: an encoded answer's length can never be checked, and any
     "whole" result replaced a file already at the destination.
   - Two voice changes of the same clip and voice (a new Chinese one downloading, the held English one downloaded again) chose the
     same two output paths, because each chose its names when its download began and neither had written yet. The English files
     landed on the timeline; cancelling the Chinese change deleted both, since a failure deleted its chosen paths whether or not it
     had written them.
   - The upscale's charge came from `billing.credits_charged` even while the bill was `pending_review` / `review_required`: 72 was
     settled and reported as charged, where the reservation (75) must stay until the bill is final.
   - A file where generate_media's output folder should be made the folder fail before the download, as a plain error: the job ended
     failed without a hold, the row lost Download again and the key only returned the old `started` (0 file GETs). A move into place
     that failed was reported as a network failure and not held either.
   - An explicit key with spaces was trimmed for the receipt but not in the identity, so the receipt's key, sent back, was refused as
     other inputs. A voice change stopped during its background download said 1 GET where the server counted 2. A film's next step
     said a key-less call is charged again, but its entry refuses a film submission without a key.
   - Why the checks stayed green: the gzip fixture never decoded to its own total, no check had two voice changes downloading at once
     or a file in the way of an output folder, the ledger fixture had no bill under review, and the official re-ask and the changed
     key were checked through the registry, not the tool entries.
7. **Round 4 (`56c25600`) fixed those repros, but the same two classes went one layer deeper** (Codex's re-check CXD4):
   - Names claimed in memory: SkyCut and SkyCut Beta changing the same clip chose the same voice path; the new job overwrote the old
     job's voice on the timeline and its cancel deleted it. A voice called "Background" and the "background" file became one file on a
     case-insensitive drive (the task said done, only the background was left). A cancel deleted a file that had replaced its own
     voice during the background's download (deleting by path, not by the file it wrote).
   - Placing still removed what was at the name when the result was "checked": generate_media recursively removed a non-empty folder
     `test.png/` that appeared after its name was picked, and said done (on main the same).
   - An upscale whose first download succeeded while its bill was under review booked and reported the quote (75) as the charge, and
     get_job never read the original job again, so it stayed 75 after Sky Studio settled at 72.
   - The image's format check ran after the result had "arrived": a length-less 200 holding only an 8-byte PNG header failed it with
     the Download again entry already released, and the original key then only returned `started`, no second GET.
   - Why the checks stayed green: the not-saved check built its error by hand (mapping the real write error back to a network one
     stayed green), and the film wording was checked by calling the wording function, not through the film flow.
8. **Round 5 (`a6d43d50`) held in realistic use; four edge cases that lose a file, under-book or strand a paid result remained**
   (Codex's re-check CXD5; the rest went to the backlog under the user's 2026-11-19 bug policy):
   - The download's private files were removed by path, recursively: a non-empty folder that took a `.part-*` path between two GETs
     was deleted with its contents by the next GET.
   - A voiceover batch file that did not decode (a length-less 4-byte WAV) stayed in the recovery record, so every resume failed
     `local_split` on it and never downloaded the batch again.
   - A voiceover batch recovered while its bill was under review booked the top-level 0.1 as its charge and cleared its unknown 2.5.
   - A voice change settled by get_job (9 → 7.5) and then downloaded again showed its old pending bill (reserved 9) in the receipt.

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

**Second round, after the review of #554** (its request matching and B47 interlock were reverted in the narrowed round below):

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
  - generate_media (reverted below): the key is no longer part of a request's identity (`SkyStudioGenerationRequests.identity`);
    `heldAnswer` sends the same request, with the key SkyCut returned or with none, to Download again under the same job id; held runs are registered by job
    id (`SkyStudioHeldDownloads`), so the re-ask works after the row was dismissed; official generation and recovery find theirs from
    the cached answer (`heldAnswer(for:)`). The delivery (download, image format, WebM copy, SRT, official receipt, music) moved into
    `SkyStudioGenerationDelivery` (the run was at 577 of 600 lines), which Download again runs again; a missing SRT is held on its
    own, and the re-ask fetches only it;
  - upscale and voice change (B47; reverted below): upscale_clip and change_voice asked for the same input, and both panels, offer Download again (the
    paid button gives way to it, with an orange line) instead of a new paid job; a dismissed held upscale stays findable for them, and
    the upscale inspector shows Download again too;
  - voiceover: the failed row's Download again runs the same local recovery as `add_voiceover resume=recovery_file`
    (`generate_missing` off).
- **The day's books take Sky Studio's charge when the result is made** (`UpscalePipeline.run`'s `onMade`, `UpscaleJob.settleMade`),
  before any download.
- **Words**: the message and next step no longer assert a charge (billing may be pending; the job's billing fields say it), the
  official next step names its film arguments and key, and an SRT failure says that the same request fetches only the SRT.

**Narrowed round (2026-11-25), after Codex's re-check.** The user decided that an identical paid request sent again is a deliberate
new version (a new paid job, no matching, no reuse; a guard that asks once after five identical repeats in a row is a separate change),
so this PR keeps only what concerns the download of a job that was already paid for:

- **Reverted to main:** the idempotency_key is part of a request's identity again (`SkyStudioGenerationRequests.identity`, with the
  key SkyCut made filled in, so the key it returned names that same request); every lookup that mapped a new request to an old held
  job by its parameters is gone (generate_media's key-less matching, upscale_clip's and change_voice's, the panels' and the upscale
  inspector's Download again, `UpscaleActivity`'s dismissed held jobs, `VoiceChangeActivity`'s held changes). Those entries start a
  new paid job as on main; B47 stays open for the repeat guard.
- **Whole results only:** every GET asks for identity bytes; sizes are always compared (no Content-Encoding exception: the system
  reports the decoded length); an empty body is never a result; three answers that are not the whole result end
  `download_incomplete` (a new kind with its own line), a download failure the flows hold.
- **Answers:** an answer whose status was held back counts as an answer: at most one GET at the job's current address, never the same
  address again, then the result is held. A stop is `SkyStudioDownloadFailure.stopped(attempts:)` with the GETs really sent
  (`SkyStudioAPI.download` returns its GET count, so a stop after the download says so too).
- **Held until it came down, on the job's own row / id / key:** `SkyStudioHeldDownloads` releases only once the result arrived;
  starting Download again keeps it, a second ask while it runs starts nothing; the official recovery's Download again uses the held
  result when the job cannot be read now (a 503); voiceover's row reads the recovery record from disk (`SkyStudioVoiceRecovery.reading`)
  and keeps its button after a user's stop during the download.
- **Upscale ledger:** `UpscaleDelivery.charge(of:)` reads the top-level `credits_charged`, else `billing.credits_charged`; Download
  again's re-read settles a charge the first answer did not carry, and the saved upscale reports it.
- **Words:** the user's lines name the way back ("use Download again on this task in the generation task list"); the AI's next step
  names this job's own key or row and says that a call without that key, upscale_clip or change_voice again is a new job, charged
  again.

**Round 4 (2026-11-26), after CXD3:**

- **Encoded answers and files in the way:** `SkyStudioDownloadRetry.wholeness` replaces `incompleteness`: an answer with any
  Content-Encoding but identity is never taken as a 206 and never resumed (its next GET starts without a Range); an encoded 200, like
  a 200 without a length, is whole but unchecked. `CloudResultDownload` replaces a file already at the destination only with a result
  checked against its length; an unchecked one over a file is thrown away like a short one (three end `download_incomplete`).
- **This Mac could not keep it:** a new kind, `notSaved` (`download_not_saved`, its own line in the three string tables): a move into
  place that fails, and an output folder that cannot be made (generate_media's delivery, the official recovery), hold the result for
  Download again like any download failure.
- **Voice change files belong to their own job:** `VoiceChangeOutputName.claim` counts the names other running changes chose as
  taken (released when the download is done with them); a failure or a stop deletes only the files that download wrote and that no
  open project's timeline uses, and a download failure carries every GET the job sent (`SkyStudioDownloadFailure.after`).
- **Upscale ledger:** `UpscaleDelivery.charge(of:)` hands over a charge only once the bill is final (`SkyStudioBilling.isFinal`),
  the bill's net first, else the top-level one; under review, a refund pending or still reserved, the reservation stays.
- **Key and words:** the identity holds the key as SkyCut reads it (trimmed); a film's next step says a film call with another key is
  charged again and one without a key is refused (`SkyStudioGenerationRun.downloadRetry` / `otherCall`, shared with the SRT's line).

**Round 5 (2026-11-26), after CXD4:**

- **Every paid result takes its name through the repo's exclusive placement** (`CloudResultPlace` → `ExclusivePlacement.placeOwned`,
  the exports' placement from #508: exclusive rename → hard link → `O_EXCL` copy): `stem.ext` or the next free number at that moment,
  never replacing, moving over or removing anything at the name (a file, a folder, a case-only variant, another process's file);
  `SkyStudioAPI.download(_:into:renew:check:onProgress:)` returns the placed file by device and inode. A flow that gives one up uses
  `ExclusivePlacement.discard` (only while it is still that file). The WebM editing copy and the upscale's final save go the same way;
  the in-memory name claims (generation, voice change) are gone.
- **A flow's own check before the name**: the image check (`SkyStudioImageResult.downloadCheck`) runs on the private file inside the
  download loop; a failure is an incomplete answer (fetched again, three end `download_incomplete`), so the result stays held until
  a checked image is placed (generation and the official recovery).
- **Final bills only, refreshed by get_job**: `SkyStudioJobStatus.finalCharge` (the bill's net, else the top-level, nil while the bill
  is not final); an upscale or a voice change whose bill is not final keeps its reservation, says `billing_pending` with
  `credits_reserved`, and get_job reads the original job again until it is final (`UpscaleJob.refreshBill`, `VoiceChangeJob.refreshBill`).
- Real-path tests: the real write errors (a read-only folder before the GET and once the result is whole) and an official film
  generation through `SkyStudioGenerationRun` with a production plan and authority.

**Round 6 (2026-11-26, the last, narrow), after CXD5:** private files are removed only as regular files
(`CloudResultPlace.removePrivateFile`: the partial, the transfer's move target, the WebM and upscale temporaries; the voice change's
source folder with `rmdir`, only once empty); a voiceover batch file that does not decode is forgotten and removed, so the resume
downloads it again; a recovered voiceover batch books only a final charge (`received` uses `finalCharge`); a voice change keeps the
bill its books settled (`settledBill`) in every later receipt.

Key files: `Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift` (`download`), `CloudMedia/CloudResultDownload.swift`, `CloudMedia/CloudResultPlace.swift`,
`Sources/SrtFlowCore/ExclusivePlacement.swift` (`placeOwned`), `SkyStudioDownloadRetry.swift`,
`SkyStudioDownloadFailure.swift`, `SkyStudioDownloadWords.swift`, `SkyStudioHeldDownloads.swift`, `SkyStudioGenerationRequests.swift`,
`SkyStudioGenerationRun.swift`, `SkyStudioGenerationDelivery.swift`, `SkyStudioGenerateTool.swift`, `SkyStudioOfficialGenerateTool.swift`,
`SkyStudioOfficialRecoveryRun.swift`, `SkyStudioMediaStatus.swift`, `SkyStudioVoiceCloudBatches.swift`, `SkyStudioVoiceoverRun.swift`,
`SkyStudioVoiceRecovery.swift` (`reading`), `Upscale/UpscalePipeline.swift`, `Upscale/UpscaleJob.swift` (and `UpscaleActivity`),
`Upscale/UpscaleJobStatusView.swift`, `AIUpscaleTool.swift`, `VoiceChange/VoiceChangeJob.swift`, `VoiceChange/VoiceChangeOutputName.swift`,
`SkyStudioBilling.swift` (`isFinal`), `CloudMedia/CloudTransfer.swift`
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

Second round (the local server now also answers a short 206, a stalled error answer and a redirect: `UploadServer.swift`; its re-ask,
panel and dismissed-upscale checks were replaced in the narrowed round below):

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

Narrowed round (the local server now also answers a gzip 206 and an empty 200; the fake Sky Studios answer `/models`, `/quote` and a
503 for the tool entries):

- `DownloadRetryChecks` / `DownloadEdgeChecks` (`scripts/check-sky-studio.sh`): every GET, the resumed one too, asks for identity bytes;
  three gzip 206s are `download_incomplete` after three GETs and the 2,000-byte file at the destination stays byte-identical, a gzip
  206 then the whole answer is the whole result after two GETs; three empty 200s are `download_incomplete`, an empty 200 then the
  whole answer is whole; a 500 whose body stalls is one GET with the same address from the job or with no way to ask, two GETs when
  the fresh address stalls too, never a third; a stop mid-body, during the pause and during the second GET says 1, 1 and 2 GETs; the
  pure rule: a 206 decoded to 1,000 bytes for `bytes 29-57/58`, an empty body and a 200 one byte over its length are not results.
- `HeldDownloadChecks`: the key SkyCut made names the same request when it comes back with the same arguments, the key is part of the
  identity; that key's cached answer reaches the held job, which stays held while it downloads again and until released; the same key
  with other arguments is refused and another key is a new request.
- `scripts/check-voice-recovery.sh`, real App objects:
  - `PaidToolEntryChecks` through `SkyStudioGenerateTool.generate` and `AIUpscaleTool.upscale`, POSTs counted at the fake servers:
    the failure names its job id and idempotency_key; 9:16 after a held 16:9 is a new job whose POST asks for 9:16 (the held one
    stays held); the returned key with the same arguments after the row was dismissed answers `downloading_again` with the same job
    id and saves the identical file with no POST /jobs and no quote; the same arguments without the key are exactly one more POST;
    upscale_clip from project B for project A's held source is B's own upload and job, B's clip replaced, A's untouched and still
    held;
  - `GenerationDownloadChecks`: the next step names the key and the row and says a key-less call is charged again; a Download again
    that fails again keeps it held with its button, a second ask while it runs adds no GET; the key path after the row was dismissed
    saves the identical file, then nothing is held; a stop says its one GET; three empty answers hold it (`download_incomplete`); the
    missing SRT names the key and only the SRT comes down;
  - `VoiceChangeDownloadChecks`: the same change asked again, and Chinese after English, are each a new quote, upload and POST /jobs
    (the Chinese one asks for zh) while the held English change keeps its row's Download again, which then lands its files under its
    job id; a stop says its GET; an expired address renewed once;
  - `UpscaleJobDownloadChecks`: the books at 72 of 75 with the top-level charge alone and with `billing.credits_charged` alone; a first
    answer without a charge, then Download again's re-read with 72: books and saved upscale at 72; Cancel while downloading again
    keeps it on its row, stopped after its one GET, and that row's Download again saves it with one upload and one /jobs;
  - `VoiceoverDownloadChecks`: the row's Download again runs the recovery (no new batch); after `add_voiceover resume` landed it, the
    old row adds nothing (one segment); a user's stop during the batch download keeps the button, which then lands the voiceover;
  - `OfficialRecoveryDownloadChecks`: held after three drops; Download again while the original job answers 503 (and drops again)
    stays held with its button; the operation's own key then saves the output; nothing is ever submitted.
- `scripts/check-upscale.sh` → `DownloadChecks`: the billing-only charge handed over before any download; a stop before the first GET
  says 0.
- Reverse-verified (each mutation's own FAIL line seen, the files restored; independent mutations batched per run): check-sky-studio
  in two runs: no identity header; a held-back answer tried again at the same address; the key taken out of the identity; the
  registry releasing as Download again starts; the gzip size comparison skipped; empty answers taken; a stop saying 0 GETs; SkyCut's
  own key not filled in. check-voice-recovery in two runs (download checks only): the key path returning the cached answer without
  Download again; no running guard on the generation's Download again; voiceover's row recovering from its copy in memory; the charge
  read only from the top level (also red in check-upscale); upscale_clip and change_voice matching a held job by input; the key
  derived from the arguments (9:16 and key-less both red); the row releasing the hold as Download again starts; the official
  recovery forgetting its held output; a stop dropping voiceover's button; the re-read's charge ignored. Seven wiring pins, one by
  one (a lookup by parameters, a panel's Download again, the row releasing, no identity header, the key out of the identity, a
  held-back retry, a stop saying 0).

- Round 4 (2026-11-26):
  - `scripts/check-sky-studio.sh`: `DownloadEdgeChecks` against the local server: three gzip 206s `bytes 29-52/53` decoding to 53
    bytes end `download_incomplete` with the 2,000-byte file untouched; three whole gzip 200s never replace it, a whole answer after
    one does, and one where nothing is in the way is taken; a gzip 200 cut halfway is followed by a GET without a Range;
    `DownloadRetryChecks`: the wholeness verdicts (encoded 206s never taken, `identity` counts as none, encoded and length-less 200s
    unchecked) and the `download_not_saved` words; `HeldDownloadChecks`: a key sent with spaces binds as trimmed.
  - `scripts/check-voice-recovery.sh`: `VoiceChangeOwnFilesChecks` (two claims of the same clip and voice are four paths, a released
    name is free again; the CXD3 scenario: the held English change's Download again lands while a Chinese one downloads, cancelling
    the Chinese one leaves the English files whole and on the timeline; a stop during the background says 2 GETs, keeps the voice a
    timeline uses and someone else's file at its background's name, and deletes a voice nothing uses); `PaidToolEntryChecks` (another
    key is exactly one more POST and the held job stays held; a spaced key sent back as the receipt gives it is the same job with no
    POST; a file where the output folder should be holds the result as `download_not_saved` with no file GET, and once removed the
    job's own key saves it with no POST); `OfficialRecoveryDownloadChecks` through `SkyStudioGenerateTool.generate` with film
    arguments and the operation's key (held, held again through a 503 while reading the job, then saved by that key, nothing quoted
    or submitted; the film's next step); `UpscaleJobDownloadChecks` (75 kept while the bill is under review, 72 once the re-read's
    bill is final).
  - `scripts/check-upscale.sh`: `UpscaleDelivery.charge(of:)` gives nothing under review, with a refund pending or still reserved
    (the top-level field included), the bill's net first.
  - Reverse-verified: check-sky-studio with the encoded-206 rule, the no-replace rule and the encoded resume all undone (each its own
    FAIL: the 53-byte case, the gzip 200 over the file, the GET with `bytes=709238-`), and again with the key untrimmed in the
    identity. check-voice-recovery in three runs: (1) claims ignored, GETs not added, the timeline test dropped, the old charge rule,
    the folder error unwrapped, the key untrimmed, the film's ordinary words, the official entry returning its cached answer: each
    its own FAIL; (2) the old deletion (claimed names ignored, both paths deleted) and a lookup by parameters: the CXD3 scenario, the
    other key and 9:16 red; (3) both chosen paths deleted, timeline test kept: someone else's file red. check-upscale with the old
    charge rule: five FAILs. The five new wiring pins, all undone at once: each its own ✗.

- Round 5 (2026-11-26):
  - `scripts/check-sky-studio.sh`: `DownloadEdgeChecks` (a folder at the name with a file in it and a case-only name left whole, the
    result at the next number; a whole gzip 200 beside the 2,000-byte file; a read-only folder before the GET and once the result is
    whole: `download_not_saved` after one GET); `ImageResultChecks` (the image's check names the extension; a PNG header is fetched
    again; three end `download_incomplete`, nothing placed).
  - `swift run SrtFlowCoreChecks` (`ExclusivePlacementChecks`, rename / link / O_EXCL copy / exFAT): `placeOwned` leaves a folder at
    the name whole; `discard` never removes a file that replaced the placed one.
  - `scripts/check-upscale.sh`: a file already at the upscale's name next to the original is kept, the upscale takes the next number.
  - `scripts/check-voice-recovery.sh`: `VoiceChangeOwnFilesChecks` (another process's file at the voice's name is never replaced nor
    deleted; a voice named like the background lands as its own file; a file that replaced its voice is left; an unused voice is
    deleted), `GenerationDownloadChecks` (PNG headers held, then saved by the key path; a folder at the name), `PaidToolEntryChecks`
    (a read-only output folder: `download_not_saved`, then saved by the key; an upscale saved while its bill is under review: 75
    reserved and `billing_pending`, get_job settles at 72), `VoiceChangeDownloadChecks` (the same for a voice change: 9 kept, 7.5
    once final), `OfficialFilmRunChecks` (an official film generation's next step through the flow); Main checks that the paid jobs
    of the download checks give their job slots back (3 before, 3 after: the three are LibraryRestartChecks' jobs parked as if
    SkyCut had quit, which raise the limit by three; verifying the account against the fake `/me` now keeps that arrangement instead
    of re-adopting 3, which had left the official film run waiting for a slot).
  - Reverse-verified (each FAIL seen, the files restored): check-sky-studio with the placement replacing what is at the name, the
    real write errors mapped back to network errors and the flow's check skipped (14 FAILs, each mutation its own); the core checks
    with `placeOwned` removing what is at the name and `discard` by path; check-voice-recovery in two runs: (1) the placement replacing,
    the quote booked and reported as the upscale's charge, the film flow using the ordinary words, the write error as a network one;
    (2) a voice change deleting by path, a voice change settling a bill under review, the image check skipped, get_job never refreshing
    an upscale's bill, a held generation keeping a job slot, the background's stem allowed to match the voice's in case.

- Round 6 (2026-11-26): `DownloadRetryChecks` (a folder with a file that takes the `.part-*` path between two GETs is left, the
  download ending `download_not_saved`; removing a private file never removes a folder or follows a link); `VoiceoverDownloadChecks`
  (a 4-byte batch file fails `local_split` and resume downloads it again with one more file GET and no POST; a batch stopped while
  running and recovered with a bill under review keeps its 2.5 unknown, 0.1 never booked); `VoiceChangeDownloadChecks` (held with a
  pending bill, settled by get_job at 7.5, then Download again: the receipt keeps 7.5). Reverse-verified: check-sky-studio with the
  removal recursive (2 FAILs); check-voice-recovery with the broken file kept, the recovered bill booked at the top-level figure and
  the receipt taking the stale status (each its own FAIL). The voice-recovery binary now takes ~149 s on the developer Mac (224 s for
  the whole step on CI in round 5), so its watchdog is 300 s.

## Lessons

- A download after payment is the most expensive step to lose: retry what a second try can fix, resume when the system kept the
  bytes, renew an expired address from the job, and never answer a failure by submitting again.
- "Query the original job" is not a recovery if nothing downloads its result: every flow that holds a paid result needs a way to
  fetch the same result again, and the next step must name it.
- Two retry loops multiply: when the transport retries, remove the callers' own loops.
- "Completed" is not "whole": check a resumed answer's range and the bytes on disk against the total before it becomes the result.
- A held paid result is reached only through its own job: its row, its id, its idempotency_key. Matching a new request to an old held
  job by its parameters returned wrong results (a 9:16 request got the old 16:9 image, a Chinese voice change the old English one,
  project B's upscale replaced project A's clip): an identical paid request sent again is a deliberate new version (user,
  2026-11-25), and the way back must survive a dismissed row, a failed Download again and a failed read of the job.
- Check the path that submits the order, not its helpers: count POSTs at the server through the tool entries (the round that only
  called the lookup functions stayed green while repeats still paid).
- The system decodes a Content-Encoding even when identity was asked for and reports the decoded size, so an encoded answer proves
  nothing about its length: never take an encoded range, never resume one, and never let an unchecked result replace a file that is
  already there. Treat an empty body as no result.
- A job deletes only what it wrote: two jobs that choose names before either writes can choose the same ones, so claim the names
  while running, and on a failure delete only your own files that nothing uses.
- A charge under review is not a charge: keep the reservation until the bill is final, and keep asking (get_job) until it is.
- Place, never replace: a result takes its name through the one exclusive placement, so nothing at the name (a file, a folder, a
  case-only variant, another process's file) can be overwritten or removed, and a flow gives up only the file it placed, by identity.
  Names claimed in memory only protect one process.
- A check that guards a paid result belongs before the result counts as arrived: run it on the private file, and treat a failure as
  a failed download (held), never as an arrived result.
- Test the error and the words through the real path: a constructed error or a direct call of a wording function stays green when
  the real path is mapped back.
- Remove your own temporary files only as files: a recursive removal by path deletes whatever took the name. And a cached paid file
  that fails to decode is not the result: forget it, so the next try fetches it again.
- A fake server that only resumes the happy way proves little: give it the edges the real network gives (a short 206, a stalled
  error body, a redirect) before trusting the retry logic.
- The long-term rules are in [Sky Studio jobs](../architecture/sky-studio-jobs.md), "Downloads that the network interrupts".
