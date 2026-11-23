#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: uploads to Sky Studio's storage (2026-11-23, generate-34 / generate-35, and the review
# of PR #549; docs/bugfixes/2026-11-23-upload-lost-connection-no-retry.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with / line_of.
# The behaviour is pinned by scripts/check-sky-studio.sh (UploadRetryChecks / UploadAnswerChecks against a local server, and the
# debug-only hook's checks); this section pins the wiring those checks cannot see:
#   - the PUT exists once, in SkyStudioAPI.upload (and the debug-only hook), inside the retry loop; an answer the storage gave is
#     read before the error that followed it; only the API builds `uploadFailed`;
#   - every job that uploads tells the user the localized line (SkyStudioUploadWords) and the AI the code and the PUT count
#     (SkyStudioUploadFailure.fields): generation, upscale, voice change, the voice library (界面 and manage_voices), characters, the
#     official film's references (whose row keeps the line);
#   - generate_media's get_job never ends with "query this original job" for a request that never left this Mac: the next step for an
#     unsubmitted job and then the upload fields come after the generic one;
#   - a cut sent under a temporary name is reported by the name the user knows;
#   - the user's lines name the network, never a proxy (on 2026-11-23 the uplink was just as unstable without one);
#   - SRTFLOW_TEST_UPLOAD_DROPS exists only in debug builds, and scripts/debug-hook-probe.sh guards the release binary.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".

UPLOAD_API="Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift"
UPLOAD_RUN="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
UPLOAD_UPSCALE_JOB="Sources/SrtFlow/Upscale/UpscaleJob.swift"
UPLOAD_UPSCALE_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
UPLOAD_UPSCALE_PIPELINE="Sources/SrtFlow/Upscale/UpscalePipeline.swift"
UPLOAD_CHANGE_JOB="Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift"
UPLOAD_LIBRARY_TEXT="Sources/SrtFlow/VoiceLibrary/VoiceLibraryText.swift"
UPLOAD_RECORDING_TOOL="Sources/SrtFlow/SkyStudio/SkyStudioVoiceRecordingTool.swift"
UPLOAD_RECORDING="Sources/SrtFlow/SkyStudio/SkyStudioVoiceRecordingSubmission.swift"
UPLOAD_CHARACTER="Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift"
UPLOAD_CHARACTER_RUN="Sources/SrtFlow/SkyStudio/SkyStudioCharacterRun.swift"
UPLOAD_OFFICIAL="Sources/SrtFlow/SkyStudio/SkyStudioOfficialPreparation.swift"
UPLOAD_FAULT="Sources/SrtFlow/CloudMedia/CloudUploadFault.swift"
for file in "${UPLOAD_API}" "${UPLOAD_RUN}" "${UPLOAD_UPSCALE_JOB}" "${UPLOAD_UPSCALE_TOOL}" "${UPLOAD_UPSCALE_PIPELINE}" "${UPLOAD_CHANGE_JOB}" \
            "${UPLOAD_LIBRARY_TEXT}" "${UPLOAD_RECORDING_TOOL}" "${UPLOAD_RECORDING}" "${UPLOAD_CHARACTER}" "${UPLOAD_CHARACTER_RUN}" \
            "${UPLOAD_OFFICIAL}" "${UPLOAD_FAULT}" scripts/debug-hook-probe.sh; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# The PUT exists once, inside the retry loop; the storage's answer is read before the error that followed it; only the API gives up.
others="$(code_files_with 'uploadTask\(|dataTask\(with: streamed' | grep -v -e "^${UPLOAD_API}\$" -e "^${UPLOAD_FAULT}\$" || true)"
[ -z "${others}" ] || fail "these files PUT files themselves: $(tr '\n' ' ' <<<"${others}")— uploads go through SkyStudioAPI.upload (it retries)"
loop_line="$(line_of 'for attempt in 1...max(1, uploadRetry.attempts) {' "${UPLOAD_API}")"
put_line="$(line_of 'try await put(fileURL, ticket: ticket, onProgress: onProgress)' "${UPLOAD_API}")"
if [ -z "${loop_line}" ] || [ -z "${put_line}" ] || [ "${loop_line}" -ge "${put_line}" ]; then
  fail "${UPLOAD_API}: the PUT must run inside upload's retry loop"
fi
grep -qF 'try await transfer(task, delegate: delegate, retryable: true)' "${UPLOAD_API}" \
  && grep -qF '} catch where !(error is CancellationError) && task.response is HTTPURLResponse {' "${UPLOAD_API}" \
  || fail "${UPLOAD_API}: a PUT the storage answered must be judged by that answer, never tried again for the error that followed"
others="$(code_files_with '\.uploadFailed\(SkyStudioUploadFailure\(' | grep -v "^${UPLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files build an upload failure: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.upload, when it gives up"

# Every job that uploads: the user's localized line and the AI's code and count.
grep -qF 'self.status.issue = uploadFailure.map(SkyStudioUploadWords.shown) ?? message' "${UPLOAD_RUN}" \
  && grep -qF 'uploadFailure = SkyStudioUploadFailure.from(failure)' "${UPLOAD_RUN}" \
  || fail "${UPLOAD_RUN}: the task row must show the localized upload line, not the English message"
generic_line="$(line_of 'payload["next_step"] = .string("Query this original job with get_job' "${UPLOAD_RUN}")"
unsent_line="$(line_of 'if status != .done, !requestSent {' "${UPLOAD_RUN}")"
merge_line="$(line_of 'payload.merge(uploadFailure.fields(retry:' "${UPLOAD_RUN}")"
if [ -z "${generic_line}" ] || [ -z "${unsent_line}" ] || [ -z "${merge_line}" ] \
   || [ "${unsent_line}" -le "${generic_line}" ] || [ "${merge_line}" -le "${unsent_line}" ]; then
  fail "${UPLOAD_RUN}: an unsubmitted job's next step, then the upload fields, must come after the generic 'query this original job'"
fi
grep -qF 'uploadFailure.map(SkyStudioUploadWords.shown) ?? SkyStudioJobError.request(failure).message' "${UPLOAD_UPSCALE_JOB}" \
  || fail "${UPLOAD_UPSCALE_JOB}: the upscale's failed state must hold the localized upload line"
grep -qF 'failure.fields(retry: "call upscale_clip again.")' "${UPLOAD_UPSCALE_TOOL}" \
  || fail "${UPLOAD_UPSCALE_TOOL}: upscale_clip's get_job must carry the upload code and count"
grep -qF 'shown: SkyStudioUploadWords.shown(failure))' "${UPLOAD_CHANGE_JOB}" \
  && grep -qF 'failure.fields(retry: "call change_voice again.")' "${UPLOAD_CHANGE_JOB}" \
  || fail "${UPLOAD_CHANGE_JOB}: a voice change must show the localized upload line and give the AI the code and count"
grep -qF 'if let failure = SkyStudioUploadFailure.from(error) { return SkyStudioUploadWords.shown(failure) }' "${UPLOAD_LIBRARY_TEXT}" \
  || fail "${UPLOAD_LIBRARY_TEXT}: the voice library must show the localized upload line"
grep -qF 'SkyStudioUploadFailure.from(error)?.fields(retry:' "${UPLOAD_RECORDING_TOOL}" \
  || fail "${UPLOAD_RECORDING_TOOL}: manage_voices must give the AI the upload code and count"
grep -qF 'case .uploadFailed(let failure):' "${UPLOAD_CHARACTER}" \
  && grep -qF 'activity?.issue = uploadFailure.map(SkyStudioUploadWords.shown) ?? message' "${UPLOAD_CHARACTER_RUN}" \
  && grep -qF 'detail.merge(uploadFailure.fields(retry:' "${UPLOAD_CHARACTER_RUN}" \
  || fail "${UPLOAD_CHARACTER} / ${UPLOAD_CHARACTER_RUN}: character uploads must show the localized line and give the AI the code and count"
grep -qF 'status.issue = SkyStudioUploadWords.shown(failure)' "${UPLOAD_OFFICIAL}" \
  && grep -qF 'detail.merge(failure.fields(retry:' "${UPLOAD_OFFICIAL}" \
  || fail "${UPLOAD_OFFICIAL}: the official references' row must keep the localized line and get_job the upload code and count"

# A cut sent under a temporary name is reported by the name the user knows.
grep -qF 'named: request.originalURL.lastPathComponent' "${UPLOAD_UPSCALE_PIPELINE}" \
  || fail "${UPLOAD_UPSCALE_PIPELINE}: an upscale's upload must be named after the original file"
grep -qF 'named: clipName' "${UPLOAD_CHANGE_JOB}" || fail "${UPLOAD_CHANGE_JOB}: a voice change's upload must be named after the clip"
grep -qF 'named: file.lastPathComponent' "${UPLOAD_RECORDING}" || fail "${UPLOAD_RECORDING}: a voice sample's upload must be named after the user's file"

# The user's lines name the network, never a proxy.
proxy_lines="$(grep -hE '"(The upload of|Sky Studio.s storage refused the upload)' Sources/SrtFlow/Resources/*.lproj/Localizable.strings | grep -iE 'proxy|代理' || true)"
[ -z "${proxy_lines}" ] || fail "an upload line names a proxy in a string table: ${proxy_lines} — say the network (the direct path was just as unstable)"

# SRTFLOW_TEST_UPLOAD_DROPS exists only in debug builds: its file is fenced whole, the API reaches it only inside #if DEBUG, and the
# probe that refuses a binary naming it runs on the release binary (scripts/build-app.sh). That the probe still refuses is tested in
# scripts/check-sky-studio.sh against a debug build.
[ "$(head -1 "${UPLOAD_FAULT}")" = "#if DEBUG" ] && [ "$(tail -1 "${UPLOAD_FAULT}")" = "#endif" ] \
  || fail "${UPLOAD_FAULT}: the whole file must sit inside #if DEBUG … #endif (release builds carry none of it)"
others="$(code_files_with 'CloudUploadFault|SRTFLOW_TEST_UPLOAD_DROPS' | grep -v -e "^${UPLOAD_FAULT}\$" -e "^${UPLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files reach the debug-only upload hook: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.put, inside #if DEBUG"
fenced="$(awk '
  /^[[:space:]]*#if DEBUG/ { inside = 1; next }
  /^[[:space:]]*#(else|endif)/ { inside = 0; next }
  /CloudUploadFault/ && !inside { print FILENAME ":" FNR }
' "${UPLOAD_API}")"
[ -z "${fenced}" ] || fail "${UPLOAD_API}: CloudUploadFault is used outside #if DEBUG at ${fenced}"
grep -qxF 'scripts/debug-hook-probe.sh "$BUILD_DIR/$PRODUCT"' scripts/build-app.sh \
  || fail "scripts/build-app.sh: the release binary must go through scripts/debug-hook-probe.sh before it is packaged"
grep -qxF '/bin/bash scripts/debug-hook-probe.sh "$OUT"' scripts/check-sky-studio.sh \
  && grep -qF 'if /bin/bash scripts/debug-hook-probe.sh "$DEBUG_OUT" > /dev/null 2>&1; then' scripts/check-sky-studio.sh \
  || fail "scripts/check-sky-studio.sh: the probe must pass the build without DEBUG and refuse the debug build (the control)"
