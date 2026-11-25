#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: downloads of paid results (2026-11-24, backlog B40 and the review of PR #554;
# docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with / line_of.
# The behaviour is pinned by scripts/check-sky-studio.sh (DownloadRetryChecks against a local server: resume, short 206, stalled
# answer, redirects, refusals, stops; HeldDownloadChecks: re-asks; the debug-only hook's checks), scripts/check-voice-recovery.sh
# (VoiceChangeDownloadChecks, GenerationDownloadChecks: real App objects) and scripts/check-upscale.sh (DownloadChecks); this section
# pins the wiring those checks cannot see:
#   - a result's GET exists once, in CloudResultDownload.fetch (and the debug-only hook), inside the retry loop, never redirected by the
#     system; an answer that began is read before the error; resume data comes only from the system's own error; a result is checked
#     whole before it is moved into place; only CloudResultDownload builds a failure (flows only say `.stopped`);
#   - every paid download passes `renew:` (the job's current address, never a new job) and goes through SkyStudioAPI.download;
#   - every flow keeps the paid result for Download again whatever kept it from landing (gave up, stopped, a local step), reads the
#     job's current result first, and runs the same AI job again; the AI's re-asks (generate_media with the same request, film
#     included; upscale_clip; change_voice) and the panels download it again instead of a new paid job; voiceover's row runs its
#     recovery; an upscale's charge reaches the day's books when it is made;
#   - the user's lines name the network, never a proxy;
#   - SRTFLOW_TEST_DOWNLOAD_DROPS exists only in debug builds, and scripts/debug-hook-probe.sh guards the release binary.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

DOWNLOAD_API="Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift"
DOWNLOAD_GETS="Sources/SrtFlow/CloudMedia/CloudResultDownload.swift"
DOWNLOAD_STATUS="Sources/SrtFlow/SkyStudio/SkyStudioMediaStatus.swift"
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
DOWNLOAD_CHANGE_JOB="Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift"
DOWNLOAD_CHANGE_TOOL="Sources/SrtFlow/VoiceChange/VoiceChangeTool.swift"
DOWNLOAD_CHANGE_PANEL="Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift"
DOWNLOAD_ROWS="Sources/SrtFlow/CloudMedia/CloudTaskRows.swift"
DOWNLOAD_FAULT="Sources/SrtFlow/CloudMedia/CloudDownloadFault.swift"
for file in "${DOWNLOAD_API}" "${DOWNLOAD_GETS}" "${DOWNLOAD_STATUS}" "${DOWNLOAD_RUN}" "${DOWNLOAD_DELIVERY}" "${DOWNLOAD_TOOL}" \
            "${DOWNLOAD_OFFICIAL}" "${DOWNLOAD_RECOVERY}" "${DOWNLOAD_VOICEOVER}" "${DOWNLOAD_PIPELINE}" "${DOWNLOAD_UPSCALE_JOB}" \
            "${DOWNLOAD_UPSCALE_TOOL}" "${DOWNLOAD_UPSCALE_PANEL}" "${DOWNLOAD_CHANGE_JOB}" "${DOWNLOAD_CHANGE_TOOL}" "${DOWNLOAD_CHANGE_PANEL}" \
            "${DOWNLOAD_ROWS}" "${DOWNLOAD_FAULT}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# The GET exists once, inside the retry loop; the system never redirects it; an answer that began is judged first; a result is
# checked whole before it is moved into place; only CloudResultDownload gives up.
others="$(code_files_with 'downloadTask\(' | grep -v -e "^${DOWNLOAD_GETS}\$" -e '^Sources/SrtFlow/KokoroVoicePack.swift$' || true)"
[ -z "${others}" ] || fail "these files download results themselves: $(tr '\n' ' ' <<<"${others}")— paid results go through SkyStudioAPI.download (CloudResultDownload resumes and retries)"
grep -qF 'try await CloudResultDownload(session: session, retry: downloadRetry).run(' "${DOWNLOAD_API}" \
  || fail "${DOWNLOAD_API}: SkyStudioAPI.download must hand every paid result to CloudResultDownload"
loop_line="$(line_of 'for attempt in 1...attempts {' "${DOWNLOAD_GETS}")"
fetch_line="$(line_of 'switch try await fetch(address, resuming: resumeData, into: partial, onProgress: onProgress) {' "${DOWNLOAD_GETS}")"
if [ -z "${loop_line}" ] || [ -z "${fetch_line}" ] || [ "${loop_line}" -ge "${fetch_line}" ]; then
  fail "${DOWNLOAD_GETS}: a result's GET must run inside the retry loop"
fi
grep -qF 'CloudTransferDelegate(moveDestination: partial, followsRedirects: false, onProgress: onProgress)' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: the system must never follow a redirect for a result (each GET is counted)"
answer_line="$(line_of 'if let status = answer?.statusCode, !(200..<300).contains(status) { return .answered(status: status) }' "${DOWNLOAD_GETS}")"
transient_line="$(line_of 'guard SkyStudioUploadRetry.isTransient(error) else { return .unreachable(detail: detail) }' "${DOWNLOAD_GETS}")"
if [ -z "${answer_line}" ] || [ -z "${transient_line}" ] || [ "${answer_line}" -ge "${transient_line}" ]; then
  fail "${DOWNLOAD_GETS}: an HTTP answer that began before the error must be judged as that answer, before the error is classified"
fi
grep -qF 'let kept = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a broken GET resumes only from the resume data the system put in its own error"
grep -qF 'return answer == nil && delegate.answerStarted ? .heldBack(' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: an answer whose status was held back must ask the job for its current address first"
grep -qF 'if let problem = SkyStudioDownloadRetry.incompleteness(status: status,' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: a result must be checked whole (a short 206) before it is moved into place"
grep -qF 'guard SkyStudioDownloadRetry.renewableStatuses.contains(status), attempt < attempts, try await moveToFreshAddress() else {' "${DOWNLOAD_GETS}" \
  || fail "${DOWNLOAD_GETS}: only an expired address (403 / 404 / 410) asks for a fresh one, once, while a try is left"
others="$(code_files_with 'SkyStudioDownloadFailure\(kind:' | grep -v -e "^${DOWNLOAD_GETS}\$" -e '^Sources/SrtFlow/SkyStudio/SkyStudioDownloadFailure.swift$' || true)"
[ -z "${others}" ] || fail "these files build a download failure: $(tr '\n' ' ' <<<"${others}")— only CloudResultDownload when it gives up (flows say .stopped)"

# Every paid download can renew an expired address from its original job (and there are as many as the flows that download).
calls="$(grep -rnE '(api|SkyStudioAPI\(\))\.download\(' Sources/SrtFlow --include='*.swift' | grep -v "^${DOWNLOAD_API}:" || true)"
missing="$(grep -v 'renew:' <<<"${calls}" || true)"
[ -z "${missing}" ] || fail "these paid downloads cannot renew an expired address (pass renew:): ${missing}"
[ "$(grep -c . <<<"${calls}")" -ge 7 ] || fail "fewer paid downloads than the flows that download (generation, caption, recovery, batches, upscale, voice change ×2): a rename must be followed here"

# A row holds a paid result for the AI's re-ask too (by job id), and Download again lists it again.
grep -qF 'if let aiJobID { SkyStudioHeldDownloads.hold(aiJobID, retry: retry) }' "${DOWNLOAD_STATUS}" \
  && grep -qF 'SkyStudioGenerationActivity.shared.add(self)' "${DOWNLOAD_STATUS}" \
  || fail "${DOWNLOAD_STATUS}: a held row must register for the AI's re-ask, and Download again must list the row again"

# Generation: every way a download does not finish holds the result; Download again reads the job first; re-asks find it.
grep -qF 'throw SkyStudioDownloadFailure.stopped' "${DOWNLOAD_DELIVERY}" \
  && grep -qF 'return hold(delivery, failure)' "${DOWNLOAD_RUN}" \
  && grep -qF 'status.holdDownload(failure) { [self] in retryDownload() }' "${DOWNLOAD_RUN}" \
  && grep -qF 'let (api, key, current) = await currentResult(delivery.result)' "${DOWNLOAD_RUN}" \
  && grep -qF 'AIJobs.shared.reopen(job)' "${DOWNLOAD_RUN}" \
  && grep -qF 'holdCaption(url, delivered: delivered, delivery: delivery)' "${DOWNLOAD_RUN}" \
  || fail "${DOWNLOAD_RUN} / ${DOWNLOAD_DELIVERY}: a generation whose download gave up or was stopped (or whose SRT did not come) must stay held for Download again"
upload_merge="$(line_of 'payload.merge(uploadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
download_merge="$(line_of 'payload.merge(downloadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
finish_line="$(line_of 'AIJobs.shared.finish(job, status, message: message, detail: .object(payload))' "${DOWNLOAD_RUN}")"
if [ -z "${upload_merge}" ] || [ -z "${download_merge}" ] || [ -z "${finish_line}" ] \
   || [ "${download_merge}" -le "${upload_merge}" ] || [ "${download_merge}" -ge "${finish_line}" ]; then
  fail "${DOWNLOAD_RUN}: the download fields (and their next step: download again, never generate again) go in last, over the generic 'query this original job'"
fi
tool_held="$(line_of 'if let again = SkyStudioGenerationRequests.heldAnswer(key: givenKey, identity: requestIdentity) { return again }' "${DOWNLOAD_TOOL}")"
tool_begin="$(line_of 'if let cached = try SkyStudioGenerationRequests.begin(idempotencyKey, identity: requestIdentity) { return cached }' "${DOWNLOAD_TOOL}")"
if [ -z "${tool_held}" ] || [ -z "${tool_begin}" ] || [ "${tool_held}" -ge "${tool_begin}" ]; then
  fail "${DOWNLOAD_TOOL}: generate_media must download a held result again (the same key, or the same request without one) before anything else"
fi
grep -qF 'return SkyStudioGenerationRequests.heldAnswer(for: prior) ?? prior' "${DOWNLOAD_OFFICIAL}" \
  || fail "${DOWNLOAD_OFFICIAL}: an official key's re-ask must download its held generation or recovery again"
grep -qF 'throw SkyStudioDownloadFailure.stopped' "${DOWNLOAD_RECOVERY}" \
  && grep -qF 'if let download { status.holdDownload(download) { [self] in retryDownload(job) } }' "${DOWNLOAD_RECOVERY}" \
  || fail "${DOWNLOAD_RECOVERY}: the official recovery must stay held for Download again when its download does not finish"
grep -qF 'status.holdDownload(download) { [self] in recoverDownload() }' "${DOWNLOAD_VOICEOVER}" \
  && grep -qF 'generateMissing: false, services: services).start()' "${DOWNLOAD_VOICEOVER}" \
  || fail "${DOWNLOAD_VOICEOVER}: a voiceover batch whose download gave up must offer Download again through its recovery (no new batches)"

# Upscale: the charge reaches the day's books when it is made; anything after that holds the result; re-asks and the panel find it.
grep -qF 'onMade(delivery)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'throw UpscaleUndelivered(failure: .stopped, delivery: delivery)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'Task { @MainActor in self?.settleMade(delivery) }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF '} catch where made.value != nil {' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'if let fresh = try? await SkyStudioAPI().job(delivery.jobID, key: found).result { current.result = fresh }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'job.onRetry = { _ in AIJobs.shared.reopen(aiJob) }' "${DOWNLOAD_UPSCALE_TOOL}" \
  && grep -qF 'if let held = UpscaleActivity.shared.heldDownload(' "${DOWNLOAD_UPSCALE_TOOL}" \
  && grep -qF 'UpscaleActivity.shared.heldDownload(' "${DOWNLOAD_UPSCALE_PANEL}" \
  && grep -qF 'UpscaleActivity.shared.downloadAgain(held)' "${DOWNLOAD_UPSCALE_PANEL}" \
  && grep -qF 'UpscaleActivity.shared.downloadAgain(held)' "${DOWNLOAD_UPSCALE_TOOL}" \
  || fail "${DOWNLOAD_PIPELINE} / ${DOWNLOAD_UPSCALE_JOB} / ${DOWNLOAD_UPSCALE_TOOL} / ${DOWNLOAD_UPSCALE_PANEL}: an upscale made and paid must settle its charge at once and stay held for Download again, never charge again"
# Cancel during a paid download keeps the job (stopped, held); a dismissed held job is still found; Download again lists it again.
grep -qF 'if job.downloadsPaidResult { return job.cancel() }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'if job.canRetryDownload { dismissedHeld.append(job) }' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF '(jobs + dismissedHeld).first { $0.holdsResult(' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'if !jobs.contains(where: { $0.id == job.id }) { jobs.append(job) }' "${DOWNLOAD_UPSCALE_JOB}" \
  || fail "${DOWNLOAD_UPSCALE_JOB}: UpscaleActivity must keep a paid upscale through Cancel and Dismiss (held for Download again) and list it again when it downloads again"

# Voice change: any failure after the job held; Download again reads the job first; re-asks and the panel find it; no own loop.
grep -qF 'return hold(.stopped, result: result, server: done)' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'VoiceChangeActivity.shared.hold(origin.clipID, .init(voice: target.id, direct: direct, jobID: job?.id, retry: retry))' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if case .conversion(let current)? = try? await services.api.job(pending.server.jobID, key: key).voiceResult { result = current }' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'if let held = VoiceChangeActivity.shared.heldChange(clipID: id, voice: target.id, direct: direct) {' "${DOWNLOAD_CHANGE_TOOL}" \
  && grep -qF 'if model.heldDownload != nil {' "${DOWNLOAD_CHANGE_PANEL}" \
  || fail "${DOWNLOAD_CHANGE_JOB} / ${DOWNLOAD_CHANGE_TOOL} / ${DOWNLOAD_CHANGE_PANEL}: a voice change made and paid must stay held for Download again, never charge again"
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
