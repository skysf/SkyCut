#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: downloads of paid results (2026-11-24, backlog B40;
# docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with / line_of.
# The behaviour is pinned by scripts/check-sky-studio.sh (DownloadRetryChecks against a local server, and the debug-only hook's checks)
# and scripts/check-voice-recovery.sh (VoiceChangeDownloadChecks: real App objects); this section pins the wiring those checks cannot see:
#   - a result's GET exists once, in SkyStudioAPI.fetch (and the debug-only hook), inside download's retry loop; an answer that began is
#     read before the error that followed it; resume data comes only from the system's own error; only the API builds the failure;
#   - every paid download passes `renew:` (a fresh address from the original job, never a new job);
#   - every flow that downloads keeps the result for Download again and shows the localized line: generation (and generate_media
#     with the same idempotency_key), the official recovery, voiceover batches (resume=recovery_file), upscale, voice change; the
#     task rows offer the button and a retry runs the same AI job id again (AIJobs.reopen);
#   - the user's lines name the network, never a proxy;
#   - SRTFLOW_TEST_DOWNLOAD_DROPS exists only in debug builds, and scripts/debug-hook-probe.sh guards the release binary.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

DOWNLOAD_API="Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift"
DOWNLOAD_RUN="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
DOWNLOAD_TOOL="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
DOWNLOAD_RECOVERY="Sources/SrtFlow/SkyStudio/SkyStudioOfficialRecoveryRun.swift"
DOWNLOAD_BATCHES="Sources/SrtFlow/SkyStudio/SkyStudioVoiceCloudBatches.swift"
DOWNLOAD_VOICEOVER="Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift"
DOWNLOAD_PIPELINE="Sources/SrtFlow/Upscale/UpscalePipeline.swift"
DOWNLOAD_UPSCALE_JOB="Sources/SrtFlow/Upscale/UpscaleJob.swift"
DOWNLOAD_UPSCALE_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
DOWNLOAD_CHANGE_JOB="Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift"
DOWNLOAD_ROWS="Sources/SrtFlow/CloudMedia/CloudTaskRows.swift"
DOWNLOAD_FAULT="Sources/SrtFlow/CloudMedia/CloudDownloadFault.swift"
DOWNLOAD_WORDS="Sources/SrtFlow/SkyStudio/SkyStudioDownloadWords.swift"
for file in "${DOWNLOAD_API}" "${DOWNLOAD_RUN}" "${DOWNLOAD_TOOL}" "${DOWNLOAD_RECOVERY}" "${DOWNLOAD_BATCHES}" "${DOWNLOAD_VOICEOVER}" \
            "${DOWNLOAD_PIPELINE}" "${DOWNLOAD_UPSCALE_JOB}" "${DOWNLOAD_UPSCALE_TOOL}" "${DOWNLOAD_CHANGE_JOB}" "${DOWNLOAD_ROWS}" \
            "${DOWNLOAD_FAULT}" "${DOWNLOAD_WORDS}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# The GET exists once, inside download's retry loop; an answer that began is judged as that answer; only the API gives up.
others="$(code_files_with 'downloadTask\(' | grep -v -e "^${DOWNLOAD_API}\$" -e '^Sources/SrtFlow/KokoroVoicePack.swift$' || true)"
[ -z "${others}" ] || fail "these files download results themselves: $(tr '\n' ' ' <<<"${others}")— paid results go through SkyStudioAPI.download (it resumes and retries)"
loop_line="$(line_of 'for attempt in 1...attempts {' "${DOWNLOAD_API}")"
fetch_line="$(line_of 'switch try await fetch(address, resuming: resumeData, into: partial, onProgress: onProgress) {' "${DOWNLOAD_API}")"
if [ -z "${loop_line}" ] || [ -z "${fetch_line}" ] || [ "${loop_line}" -ge "${fetch_line}" ]; then
  fail "${DOWNLOAD_API}: a result's GET must run inside download's retry loop"
fi
answer_line="$(line_of 'if let status = (task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {' "${DOWNLOAD_API}")"
transient_line="$(line_of 'guard SkyStudioUploadRetry.isTransient(error) else { return .unreachable(detail: detail) }' "${DOWNLOAD_API}")"
if [ -z "${answer_line}" ] || [ -z "${transient_line}" ] || [ "${answer_line}" -ge "${transient_line}" ]; then
  fail "${DOWNLOAD_API}: an HTTP answer that began before the error must be judged as that answer, before the error is classified"
fi
grep -qF 'return .broken(detail: detail, resumeData: (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)' "${DOWNLOAD_API}" \
  || fail "${DOWNLOAD_API}: a broken GET resumes only from the resume data the system put in its own error"
grep -qF 'guard SkyStudioDownloadRetry.renewableStatuses.contains(status), !renewed, attempt < attempts, let renew else {' "${DOWNLOAD_API}" \
  || fail "${DOWNLOAD_API}: only an expired address (403 / 404 / 410) asks for a fresh one, once, while a try is left"
others="$(code_files_with 'SkyStudioDownloadFailure\(kind:' | grep -v "^${DOWNLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files build a download failure: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.download, when it gives up"

# Every paid download can renew an expired address from its original job (and there are as many as the flows below).
calls="$(grep -rnE '(api|SkyStudioAPI\(\))\.download\(' Sources/SrtFlow --include='*.swift' || true)"
missing="$(grep -v 'renew:' <<<"${calls}" || true)"
[ -z "${missing}" ] || fail "these paid downloads cannot renew an expired address (pass renew:): ${missing}"
[ "$(grep -c . <<<"${calls}")" -ge 7 ] || fail "fewer paid downloads than the flows that download (generation, caption, recovery, batches, upscale, voice change ×2): a rename must be followed here"

# Every flow keeps the paid result for Download again and shows the localized line; a retry runs the same AI job again.
grep -qF 'return hold(delivery, failure)' "${DOWNLOAD_RUN}" && grep -qF 'status.issue = SkyStudioDownloadWords.shown(failure)' "${DOWNLOAD_RUN}" \
  && grep -qF 'status.retryDownload = { [self] in retryDownload() }' "${DOWNLOAD_RUN}" && grep -qF 'AIJobs.shared.reopen(job)' "${DOWNLOAD_RUN}" \
  || fail "${DOWNLOAD_RUN}: a generation whose download gave up must keep its result for Download again, with the localized line"
upload_merge="$(line_of 'payload.merge(uploadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
download_merge="$(line_of 'payload.merge(downloadFailure.fields(retry:' "${DOWNLOAD_RUN}")"
finish_line="$(line_of 'AIJobs.shared.finish(job, status, message: message, detail: .object(payload))' "${DOWNLOAD_RUN}")"
if [ -z "${upload_merge}" ] || [ -z "${download_merge}" ] || [ -z "${finish_line}" ] \
   || [ "${download_merge}" -le "${upload_merge}" ] || [ "${download_merge}" -ge "${finish_line}" ]; then
  fail "${DOWNLOAD_RUN}: the download fields (and their next step: download again, never generate again) go in last, over the generic 'query this original job'"
fi
grep -qF 'return downloadAgain(cached) ?? cached' "${DOWNLOAD_TOOL}" \
  || fail "${DOWNLOAD_TOOL}: generate_media with the same idempotency_key must download a held result again, never start another job"
grep -qF 'status.issue = SkyStudioDownloadWords.shown(download)' "${DOWNLOAD_RECOVERY}" \
  && grep -qF 'status.retryDownload = { [self] in retryDownload(job) }' "${DOWNLOAD_RECOVERY}" \
  || fail "${DOWNLOAD_RECOVERY}: the official recovery's row must keep the localized line and Download again"
grep -qF 'status.issue = SkyStudioDownloadWords.shown(download)' "${DOWNLOAD_VOICEOVER}" \
  || fail "${DOWNLOAD_VOICEOVER}: a voiceover batch whose download gave up must show the localized line (resume=recovery_file downloads it again)"
grep -qF 'throw UpscaleUndelivered(failure: failure, delivery: delivery)' "${DOWNLOAD_PIPELINE}" \
  && grep -qF 'end(.failed(SkyStudioDownloadWords.shown(undelivered.failure)), refunding: false)' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'canRetryDownload = true' "${DOWNLOAD_UPSCALE_JOB}" \
  && grep -qF 'job.onRetry = { _ in AIJobs.shared.reopen(aiJob) }' "${DOWNLOAD_UPSCALE_TOOL}" \
  && grep -qF 'var fields = failure.fields(retry:' "${DOWNLOAD_UPSCALE_TOOL}" \
  || fail "${DOWNLOAD_PIPELINE} / ${DOWNLOAD_UPSCALE_JOB} / ${DOWNLOAD_UPSCALE_TOOL}: an upscale whose download gave up must keep its result for Download again, never charge again"
grep -qF 'return hold(failure, result: result, server: done)' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'shown: SkyStudioDownloadWords.shown(failure))' "${DOWNLOAD_CHANGE_JOB}" \
  && grep -qF 'status.retryDownload = { [self] in retryDownload() }' "${DOWNLOAD_CHANGE_JOB}" \
  || fail "${DOWNLOAD_CHANGE_JOB}: a voice change whose download gave up must keep its result for Download again, with the localized line"
! grep -qE 'attempt \+= 1|attempt < 3' "${DOWNLOAD_CHANGE_JOB}" \
  || fail "${DOWNLOAD_CHANGE_JOB}: no download loop of its own (SkyStudioAPI.download tries three times in all; two loops would multiply the GETs)"
grep -qF 'if let retry = run.retryDownload {' "${DOWNLOAD_ROWS}" && grep -qF 'if job.canRetryDownload {' "${DOWNLOAD_ROWS}" \
  || fail "${DOWNLOAD_ROWS}: the task rows must offer Download again for a paid result whose download gave up"

# The user's lines name the network, never a proxy.
proxy_lines="$(grep -hE '"The result is ready on Sky Studio' Sources/SrtFlow/Resources/*.lproj/Localizable.strings | grep -iE 'proxy|代理' || true)"
[ -z "${proxy_lines}" ] || fail "a download line names a proxy in a string table: ${proxy_lines} — say the network"

# SRTFLOW_TEST_DOWNLOAD_DROPS exists only in debug builds: its file is fenced whole, the API reaches it only inside #if DEBUG, and the
# probe that refuses a binary naming it runs on the release binary (scripts/build-app.sh); scripts/check-sky-studio.sh's control
# makes sure the probe names this hook when it refuses a debug build.
[ "$(head -1 "${DOWNLOAD_FAULT}")" = "#if DEBUG" ] && [ "$(tail -1 "${DOWNLOAD_FAULT}")" = "#endif" ] \
  || fail "${DOWNLOAD_FAULT}: the whole file must sit inside #if DEBUG … #endif (release builds carry none of it)"
others="$(code_files_with 'CloudDownloadFault|SRTFLOW_TEST_DOWNLOAD_DROPS' | grep -v -e "^${DOWNLOAD_FAULT}\$" -e "^${DOWNLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files reach the debug-only download hook: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.fetch, inside #if DEBUG"
fenced="$(awk '
  /^[[:space:]]*#if DEBUG/ { inside = 1; next }
  /^[[:space:]]*#(else|endif)/ { inside = 0; next }
  /CloudDownloadFault/ && !inside { print FILENAME ":" FNR }
' "${DOWNLOAD_API}")"
[ -z "${fenced}" ] || fail "${DOWNLOAD_API}: CloudDownloadFault is used outside #if DEBUG at ${fenced}"
grep -qF -- '-e SRTFLOW_TEST_DOWNLOAD_DROPS -e CloudDownloadFault' scripts/debug-hook-probe.sh \
  && grep -qF 'for HOOK in SRTFLOW_TEST_UPLOAD_DROPS SRTFLOW_TEST_DOWNLOAD_DROPS; do' scripts/check-sky-studio.sh \
  || fail "scripts/debug-hook-probe.sh must refuse a binary naming the download hook, and scripts/check-sky-studio.sh's control must see it named"
