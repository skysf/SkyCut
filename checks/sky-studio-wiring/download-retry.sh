#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: downloads of paid results (2026-11-24 / 25, backlog B40 and the reviews of PR #554;
# docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with / line_of.
# The behaviour is pinned by scripts/check-sky-studio.sh (DownloadRetryChecks / DownloadEdgeChecks against a local server: resume, whole
# results only, held-back answers, redirects, refusals, stops; HeldDownloadChecks: a request's key is part of what it is bound to; the
# debug-only hook's checks), scripts/check-voice-recovery.sh (real App objects, POSTs counted through the tool entries) and
# scripts/check-upscale.sh (DownloadChecks); this section pins the wiring those checks cannot see:
#   - a result's GET exists once, in CloudResultDownload.fetch (and the debug-only hook), inside the retry loop, asking for identity
#     bytes and never redirected by the system; an answer that began is read before the error; an answer whose status was held back
#     never sends the same address again; resume data comes only from the system's own error, never an encoded answer's; a result is
#     checked whole (and by the flow's own check) before it takes its name, and it takes it through ExclusivePlacement only: nothing in
#     the download or placement code replaces, moves over or removes a file at the name; only CloudResultDownload builds a failure, a
#     stop included (with its GETs), and flows say .stopped / .notSaved;
#   - every paid download passes `renew:` (the job's current address, never a new job) and goes through SkyStudioAPI.download;
#   - every flow keeps its paid result for Download again on the job's own row / id / key until it has come down, an output folder
#     that cannot be made included; nothing maps a new request to an old held job by its parameters (generate_media's key, as SkyCut
#     reads it, is part of what a request is bound to; upscale_clip, change_voice and the panels start a new paid job: user,
#     2026-11-25); voiceover's row runs its recovery from the record on disk; an upscale's or a voice change's charge reaches the day's
#     books only once its bill is final (get_job reads it again until it is); a voice change's files take their names on disk and a
#     failure deletes only a file it placed, while it is still that file and no timeline uses it;
#   - the user's lines name the network, never a proxy;
#   - SRTFLOW_TEST_DOWNLOAD_DROPS exists only in debug builds, and scripts/debug-hook-probe.sh guards the release binary.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

DOWNLOAD_API="Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift"
DOWNLOAD_GETS="Sources/SrtFlow/CloudMedia/CloudResultDownload.swift"
DOWNLOAD_PLACE="Sources/SrtFlow/CloudMedia/CloudResultPlace.swift"
DOWNLOAD_STATUS="Sources/SrtFlow/SkyStudio/SkyStudioMediaStatus.swift"
DOWNLOAD_HELD="Sources/SrtFlow/SkyStudio/SkyStudioHeldDownloads.swift"
DOWNLOAD_REQUESTS="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRequests.swift"
DOWNLOAD_RUN="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
DOWNLOAD_DELIVERY="Sources/SrtFlow/SkyStudio/SkyStudioGenerationDelivery.swift"
DOWNLOAD_TOOL="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
DOWNLOAD_OFFICIAL="Sources/SrtFlow/SkyStudio/SkyStudioOfficialGenerateTool.swift"
DOWNLOAD_RECOVERY="Sources/SrtFlow/SkyStudio/SkyStudioOfficialRecoveryRun.swift"
DOWNLOAD_VOICEOVER="Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift"
DOWNLOAD_PIPELINE="Sources/SrtFlow/Upscale/UpscalePipeline.swift"
DOWNLOAD_UPSCALE_JOB="Sources/SrtFlow/Upscale/UpscaleJob.swift"
DOWNLOAD_UPSCALE_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
DOWNLOAD_UPSCALE_PANEL="Sources/SrtFlow/Upscale/UpscalePanel.swift"
DOWNLOAD_UPSCALE_INSPECTOR="Sources/SrtFlow/Upscale/UpscaleJobStatusView.swift"
DOWNLOAD_CHANGE_JOB="Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift"
DOWNLOAD_CHANGE_TOOL="Sources/SrtFlow/VoiceChange/VoiceChangeTool.swift"
DOWNLOAD_CHANGE_PANEL="Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift"
DOWNLOAD_CHANGE_MODEL="Sources/SrtFlow/VoiceChange/VoiceChangePanelModel.swift"
DOWNLOAD_ROWS="Sources/SrtFlow/CloudMedia/CloudTaskRows.swift"
DOWNLOAD_FAULT="Sources/SrtFlow/CloudMedia/CloudDownloadFault.swift"
for file in "${DOWNLOAD_API}" "${DOWNLOAD_GETS}" "${DOWNLOAD_PLACE}" "${DOWNLOAD_STATUS}" "${DOWNLOAD_HELD}" "${DOWNLOAD_REQUESTS}" "${DOWNLOAD_RUN}" "${DOWNLOAD_DELIVERY}" \
            "${DOWNLOAD_TOOL}" "${DOWNLOAD_OFFICIAL}" "${DOWNLOAD_RECOVERY}" "${DOWNLOAD_VOICEOVER}" "${DOWNLOAD_PIPELINE}" \
            "${DOWNLOAD_UPSCALE_JOB}" "${DOWNLOAD_UPSCALE_TOOL}" "${DOWNLOAD_UPSCALE_PANEL}" "${DOWNLOAD_UPSCALE_INSPECTOR}" \
            "${DOWNLOAD_CHANGE_JOB}" "${DOWNLOAD_CHANGE_TOOL}" "${DOWNLOAD_CHANGE_PANEL}" "${DOWNLOAD_CHANGE_MODEL}" "${DOWNLOAD_ROWS}" \
            "${DOWNLOAD_FAULT}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# The GET exists once, inside the retry loop, asking for identity bytes; the system never redirects it; an answer that began is judged
# first; a held-back answer never goes to the same address again; a result is checked whole before it is moved into place; only
# CloudResultDownload gives up, a stop included.
others="$(code_files_with 'downloadTask\(' | grep -v -e "^${DOWNLOAD_GETS}\$" -e '^Sources/SrtFlow/KokoroVoicePack.swift$' || true)"
[ -z "${others}" ] || fail "these files download results themselves: $(tr '\n' ' ' <<<"${others}")— paid results go through SkyStudioAPI.download (CloudResultDownload resumes and retries)"
grep -qF 'try await CloudResultDownload(session: session, retry: downloadRetry).run(' "${DOWNLOAD_API}" \
  || fail "${DOWNLOAD_API}: SkyStudioAPI.download must hand every paid result to CloudResultDownload"
loop_line="$(line_of 'for attempt in 1...attempts {' "${DOWNLOAD_GETS}")"
fetch_line="$(line_of 'switch try await fetch(address, resuming: resumeData, into: partial, onProgress: onProgress) {' "${DOWNLOAD_GETS}")"
if [ -z "${loop_line}" ] || [ -z "${fetch_line}" ] || [ "${loop_line}" -ge "${fetch_line}" ]; then
  fail "${DOWNLOAD_GETS}: a result's GET must run inside the retry loop"
fi
grep -qF 'get.setValue("identity", forHTTPHeaderField: "Accept-Encoding")' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a result's GET must ask for the bytes as they are (Accept-Encoding: identity)"
grep -qF 'CloudTransferDelegate(moveDestination: partial, followsRedirects: false, onProgress: onProgress)' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: the system must never follow a redirect for a result (each GET is counted)"
answer_line="$(line_of 'if let status = answer?.statusCode, !(200..<300).contains(status) { return .answered(status: status) }' "${DOWNLOAD_GETS}")"
transient_line="$(line_of 'guard SkyStudioUploadRetry.isTransient(error) else { return .unreachable(detail: detail) }' "${DOWNLOAD_GETS}")"
if [ -z "${answer_line}" ] || [ -z "${transient_line}" ] || [ "${answer_line}" -ge "${transient_line}" ]; then
  fail "${DOWNLOAD_GETS}: an HTTP answer that began before the error must be judged as that answer, before the error is classified"
fi
grep -qF 'let kept = encoded ? nil : (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a broken GET resumes only from the resume data the system put in its own error, never an encoded answer's"
grep -qF 'if answer == nil && delegate.answerStarted { return .heldBack(detail: detail) }' "${DOWNLOAD_GETS}" \
  && grep -qF 'guard attempt < attempts, try await moveToFreshAddress() else { throw failed(.interrupted) }' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: an answer whose status was held back counts as an answer: one GET at the job's current address at most, never the same address again"
grep -qF 'switch SkyStudioDownloadRetry.wholeness(status: status, contentRange: answer?.value(forHTTPHeaderField: "Content-Range"),' "${DOWNLOAD_GETS}" \
  && grep -qF 'encoding: answer?.value(forHTTPHeaderField: "Content-Encoding")) {' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a result must be checked whole (a short or encoded 206, an empty answer) before it is moved into place"
grep -qF 'file = CloudResultFile(file: try await place.place(partial, pathExtension: corrected), gets: gets)' "${DOWNLOAD_GETS}" \
  && grep -qF 'Result { try ExclusivePlacement.placeOwned(partial, in: folder, stem: stem, pathExtension: pathExtension, from: number) }' "${DOWNLOAD_PLACE}" \
  && ! grep -qE '\.moveItem\(|replaceItemAt|removeItem\(' "${DOWNLOAD_GETS}" "${DOWNLOAD_PLACE}" \
  && grep -qF 'guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }' "${DOWNLOAD_PLACE}" \
  && grep -qF 'CloudResultPlace.removePrivateFile(destination)' Sources/SrtFlow/CloudMedia/CloudTransfer.swift \
  || fail "${DOWNLOAD_GETS}: a whole result takes its name only through ExclusivePlacement, never replacing, moving over or removing what is at the name (a gzip 206 overwrote a file; a folder at the name was removed)"
grep -qF 'guard SkyStudioDownloadRetry.renewableStatuses.contains(status), attempt < attempts, try await moveToFreshAddress() else {' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: only an expired address (403 / 404 / 410) asks for a fresh one, once, while a try is left"
grep -qF 'throw SkyStudioDownloadFailure.stopped(attempts: gets)' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a stop must say the GETs it really sent (it once always said 0)"
others="$(code_files_with 'SkyStudioDownloadFailure\(kind:' | grep -v -e "^${DOWNLOAD_GETS}\$" -e '^Sources/SrtFlow/SkyStudio/SkyStudioDownloadFailure.swift$' || true)"
[ -z "${others}" ] || fail "these files build a download failure: $(tr '\n' ' ' <<<"${others}")— only CloudResultDownload when it gives up (flows say .stopped(attempts:) or .notSaved)"

# Every paid download can renew an expired address from its original job (and there are as many as the flows that download).
calls="$(grep -rnE '(api|SkyStudioAPI\(\))\.download\(' Sources/SrtFlow --include='*.swift' | grep -v "^${DOWNLOAD_API}:" || true)"
missing="$(grep -v 'renew:' <<<"${calls}" || true)"
[ -z "${missing}" ] || fail "these paid downloads cannot renew an expired address (pass renew:): ${missing}"
[ "$(grep -c . <<<"${calls}")" -ge 7 ] || fail "fewer paid downloads than the flows that download (generation, caption, recovery, batches, upscale, voice change ×2): a rename must be followed here"

# Held until it has come down, and only by the job's own identity: the registry releases only in `release`, a row registers under its
# own AI job id, and starting Download again does not release it.
[ "$(count 'held[jobID] = nil' "${DOWNLOAD_HELD}")" -eq 1 ] && grep -qF 'static func release(_ jobID: String) { held[jobID] = nil }' "${DOWNLOAD_HELD}" \
  || fail "${DOWNLOAD_HELD}: a held result is released only once it has come down (release), never as Download again starts"
grep -qF 'if let aiJobID { SkyStudioHeldDownloads.hold(aiJobID, retry: retry) }' "${DOWNLOAD_STATUS}" \
  && grep -qF 'SkyStudioGenerationActivity.shared.add(self)' "${DOWNLOAD_STATUS}" \
  && ! grep -qF 'SkyStudioHeldDownloads.release' <<<"$(awk '/    func beginDownloadAgain\(\) \{/,/^    \}/' "${DOWNLOAD_STATUS}")" \
  || fail "${DOWNLOAD_STATUS}: a held row registers under its own job id, Download again lists it again and keeps it held"

# generate_media: the key is part of what a request is bound to (SkyCut's own key filled in), and a held job is reached only through
# that key's own cached answer; nothing looks a held job up by a request's parameters.
grep -qxF '        fields["idempotency_key"] = .string(key)' "${DOWNLOAD_REQUESTS}" \
  && ! grep -qF 'fields["idempotency_key"] = nil' "${DOWNLOAD_REQUESTS}" \
  || fail "${DOWNLOAD_REQUESTS}: the idempotency_key is part of a request's identity, as SkyCut reads it (trimmed, or the one it made)"
grep -qF 'let requestIdentity = SkyStudioGenerationRequests.identity(arguments: args.raw, key: idempotencyKey,' "${DOWNLOAD_TOOL}" \
  && grep -qF 'return SkyStudioGenerationRequests.heldAnswer(for: cached) ?? cached' "${DOWNLOAD_TOOL}" \
  || fail "${DOWNLOAD_TOOL}: generate_media reaches a held result only through its own key's cached answer"
others="$(code_files_with 'heldAnswer\(key:|heldDownload\(|heldChange\(|dismissedHeld|holdsResult\(' || true)"
[ -z "${others}" ] || fail "these files look a held result up by a request's parameters: $(tr '\n' ' ' <<<"${others}")— an identical paid request is a new job (user, 2026-11-25); only the job's own row / id / key reaches its result"
others="$(grep -lE 'downloadAgain|retryDownload|SkyStudioHeldDownloads|heldDownload|heldChange' "${DOWNLOAD_UPSCALE_TOOL}" "${DOWNLOAD_UPSCALE_PANEL}" \
          "${DOWNLOAD_UPSCALE_INSPECTOR}" "${DOWNLOAD_CHANGE_TOOL}" "${DOWNLOAD_CHANGE_PANEL}" "${DOWNLOAD_CHANGE_MODEL}" || true)"
[ -z "${others}" ] || fail "these entries offer Download again for the same input: $(tr '\n' ' ' <<<"${others}")— they start a new paid job; Download again stays on the job's own row"

# Generation: every way a download does not finish holds the result until it has come down; Download again reads the job first.
grep -qF 'return hold(delivery, failure)' "${DOWNLOAD_RUN}" \
  && grep -qF 'status.holdDownload(failure) { [self] in retryDownload() }' "${DOWNLOAD_RUN}" \
  && grep -qF 'guard let delivery = undelivered, let job, job.status != .running else { return }' "${DOWNLOAD_RUN}" \
  && grep -qF 'let (api, key, current) = await currentResult(delivery.result)' "${DOWNLOAD_RUN}" \
  && grep -qF 'AIJobs.shared.reopen(job)' "${DOWNLOAD_RUN}" \
  && grep -qF 'self?.arrived()' "${DOWNLOAD_RUN}" \
  && grep -qF 'holdCaption(url, delivered: delivered, delivery: delivery)' "${DOWNLOAD_RUN}" \
  || fail "${DOWNLOAD_RUN}: a generation whose download gave up or was stopped (or whose SRT did not come) must stay held until it has come down"
upload_merge="$(line_of 'payload.merge(uploadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
download_merge="$(line_of 'payload.merge(downloadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
finish_line="$(line_of 'AIJobs.shared.finish(job, status, message: message, detail: .object(payload))' "${DOWNLOAD_RUN}")"
if [ -z "${upload_merge}" ] || [ -z "${download_merge}" ] || [ -z "${finish_line}" ] \
   || [ "${download_merge}" -le "${upload_merge}" ] || [ "${download_merge}" -ge "${finish_line}" ]; then
  fail "${DOWNLOAD_RUN}: the download fields (and their next step: this job's own key or row, never generate again) go in last, over the generic 'query this original job'"
fi
grep -qF 'return SkyStudioGenerationRequests.heldAnswer(for: prior) ?? prior' "${DOWNLOAD_OFFICIAL}" \
  || fail "${DOWNLOAD_OFFICIAL}: an official key's re-ask must download its own held generation or recovery again"
grep -qF 'catch { throw SkyStudioDownloadFailure.notSaved(error) }' "${DOWNLOAD_DELIVERY}" \
  && grep -qF 'throw SkyStudioDownloadFailure.notSaved(error)' "${DOWNLOAD_RECOVERY}" \
  || fail "${DOWNLOAD_DELIVERY} / ${DOWNLOAD_RECOVERY}: an output folder that cannot be made holds the paid result for Download again (it once ended the job)"
grep -qF 'if let failure { status.holdDownload(failure) { [self] in retryDownload(job) } }' "${DOWNLOAD_RECOVERY}" \
  && grep -qF 'result = (try? await SkyStudioAPI().job(serverID, key: key).result) ?? held.result' "${DOWNLOAD_RECOVERY}" \
  || fail "${DOWNLOAD_RECOVERY}: the official recovery stays held until its output has come down, also when the job cannot be read now"
grep -qF 'if let download, recovery != nil { status.holdDownload(download) { [self] in recoverDownload() } }' "${DOWNLOAD_VOICEOVER}" \
  && grep -qF 'SkyStudioVoiceRecovery.reading(file)' "${DOWNLOAD_VOICEOVER}" \
  && grep -qF 'generateMissing: false, services: services).start()' "${DOWNLOAD_VOICEOVER}" \
  || fail "${DOWNLOAD_VOICEOVER}: a voiceover batch not downloaded (a stop included) offers Download again through its recovery, read from the record on disk (no new batches)"

# Upscale: the final charge (either field, once the bill is final) reaches the day's books when it is made, and again when Download
# again reads it; anything after that holds the result on the job's own row; Cancel during the paid download keeps it there.
grep -qF 'onMade(delivery)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'creditsCharged: UpscaleDelivery.charge(of: done)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'static func charge(of status: SkyStudioJobStatus) -> Double? { status.finalCharge }' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'if let billing, !billing.isFinal { return nil }' Sources/SrtFlow/SkyStudio/SkyStudioJob.swift \
  && grep -qF 'if let charged = result.creditsCharged { held?.settle(charged: charged) }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'aiJob.refresh = { [finished] in' "${DOWNLOAD_UPSCALE_TOOL}" \
  && grep -qF 'destination = try await CloudResultPlace(folder: folder, stem: stem, pathExtension: "mp4").place(file).url' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'throw UpscaleUndelivered(failure: .stopped(attempts: downloaded.gets), delivery: delivery)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'Task { @MainActor in self?.settleMade(delivery) }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'if let charged = UpscaleDelivery.charge(of: fresh) {' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF '} catch where made.value != nil {' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'if job.downloadsPaidResult { return job.cancel() }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'job.onRetry = { _ in AIJobs.shared.reopen(aiJob) }' "${DOWNLOAD_UPSCALE_TOOL}" \
  || fail "${DOWNLOAD_PIPELINE} / ${DOWNLOAD_UPSCALE_JOB} / ${DOWNLOAD_UPSCALE_TOOL}: an upscale made and paid must settle its actual charge at once and stay held on its own row"

# Voice change: any failure after the job is held on its own row; Download again reads the job first; no download loop of its own.
grep -qF 'return hold(failure, result: result, server: done)' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if let failure { status.holdDownload(failure, retry: retry) } else { status.retryDownload = retry }' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if case .conversion(let current)? = try? await services.api.job(pending.server.jobID, key: key).voiceResult { result = current }' "${DOWNLOAD_CHANGE_JOB}" \
  || fail "${DOWNLOAD_CHANGE_JOB}: a voice change made and paid must stay held for Download again on its own row"
grep -qF 'let places = VoiceChangeOutputName.places(' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'for file in placed where !Self.onAnyTimeline(file.url) { ExclusivePlacement.discard(file) }' "${DOWNLOAD_CHANGE_JOB}" \
  && ! grep -qE 'removeItem\(at: (places|file|voice|separated)' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if let failure = SkyStudioDownloadFailure.from(error) { throw failure.after(gets) }' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if let charged = VoiceChangeBilling.charge(of: done) { held.settle(charged: charged); settledBill = done } else { billPending = true }' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'let server = settledBill ?? status' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'job.refresh = { [self] in await refreshBill() }' "${DOWNLOAD_CHANGE_JOB}" \
  || fail "${DOWNLOAD_CHANGE_JOB}: a voice change's files take their names on disk; a failure deletes only a file it placed, while it is still that file and no timeline uses it (a cancel once deleted another process's file and a file that replaced its own); every GET counted; its bill settles only once final"
! grep -qE 'attempt \+= 1|attempt < 3' "${DOWNLOAD_CHANGE_JOB}" \
  || fail "${DOWNLOAD_CHANGE_JOB}: no download loop of its own (SkyStudioAPI.download tries three times in all; two loops would multiply the GETs)"
grep -qF 'if let retry = run.retryDownload {' "${DOWNLOAD_ROWS}" && grep -qF 'if job.canRetryDownload {' "${DOWNLOAD_ROWS}" \
  || fail "${DOWNLOAD_ROWS}: the task rows must offer Download again for a paid result whose download did not finish"

# The user's lines name the network, never a proxy.
proxy_lines="$(grep -hE '"The result is ready on Sky Studio' Sources/SrtFlow/Resources/*.lproj/Localizable.strings | grep -iE 'proxy|代理' || true)"
[ -z "${proxy_lines}" ] || fail "a download line names a proxy in a string table: ${proxy_lines} — say the network"

# SRTFLOW_TEST_DOWNLOAD_DROPS exists only in debug builds: its file is fenced whole, CloudResultDownload reaches it only inside
# #if DEBUG, and the probe that refuses a binary naming it runs on the release binary (scripts/build-app.sh); scripts/check-sky-studio.sh's
# control makes sure the probe names this hook when it refuses a debug build.
[ "$(head -1 "${DOWNLOAD_FAULT}")" = "#if DEBUG" ] && [ "$(tail -1 "${DOWNLOAD_FAULT}")" = "#endif" ] \
  || fail "${DOWNLOAD_FAULT}: the whole file must sit inside #if DEBUG … #endif (release builds carry none of it)"
others="$(code_files_with 'CloudDownloadFault|SRTFLOW_TEST_DOWNLOAD_DROPS' | grep -v -e "^${DOWNLOAD_FAULT}\$" -e "^${DOWNLOAD_GETS}\$" || true)"
[ -z "${others}" ] || fail "these files reach the debug-only download hook: $(tr '\n' ' ' <<<"${others}")— only CloudResultDownload.fetch, inside #if DEBUG"
fenced="$(awk '
  /^[[:space:]]*#if DEBUG/ { inside = 1; next }
  /^[[:space:]]*#(else|endif)/ { inside = 0; next }
  /CloudDownloadFault/ && !inside { print FILENAME ":" FNR }
' "${DOWNLOAD_GETS}")"
[ -z "${fenced}" ] || fail "${DOWNLOAD_GETS}: CloudDownloadFault is used outside #if DEBUG at ${fenced}"
grep -qF -- '-e SRTFLOW_TEST_DOWNLOAD_DROPS -e CloudDownloadFault' scripts/debug-hook-probe.sh \
  && grep -qF 'for HOOK in SRTFLOW_TEST_UPLOAD_DROPS SRTFLOW_TEST_DOWNLOAD_DROPS; do' scripts/check-sky-studio.sh \
  || fail "scripts/debug-hook-probe.sh must refuse a binary naming the download hook, and scripts/check-sky-studio.sh's control must see it named"
