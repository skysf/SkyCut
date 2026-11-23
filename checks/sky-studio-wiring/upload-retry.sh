#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: uploads the network interrupts (2026-11-23, generate-34 / generate-35;
# docs/bugfixes/2026-11-23-upload-lost-connection-no-retry.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with / line_of.
# The behaviour is pinned by scripts/check-sky-studio.sh (UploadRetryChecks, against a local server that drops the connection);
# this section pins the wiring those checks cannot see:
#   - the PUT exists once, in SkyStudioAPI.upload, inside the retry loop, and only it builds `uploadInterrupted`;
#   - every job that uploads tells the user the localized line (SkyStudioUploadWords) and the AI the code and the count
#     (SkyStudioUploadInterruption.fields): generation, upscale, voice change, the voice library (界面 and manage_voices), characters,
#     the official film's references;
#   - generate_media's get_job never ends with "query this original job" for an upload that was never submitted: the upload fields
#     are merged after the generic next step;
#   - a cut sent under a temporary name is reported by the name the user knows;
#   - the user's line names the network, never a proxy (on 2026-11-23 the uplink was just as unstable without one).
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
for file in "${UPLOAD_API}" "${UPLOAD_RUN}" "${UPLOAD_UPSCALE_JOB}" "${UPLOAD_UPSCALE_TOOL}" "${UPLOAD_UPSCALE_PIPELINE}" "${UPLOAD_CHANGE_JOB}" \
            "${UPLOAD_LIBRARY_TEXT}" "${UPLOAD_RECORDING_TOOL}" "${UPLOAD_RECORDING}" "${UPLOAD_CHARACTER}" "${UPLOAD_CHARACTER_RUN}" "${UPLOAD_OFFICIAL}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# The PUT exists once, inside the retry loop; only the API builds the interruption.
others="$(code_files_with 'uploadTask\(' | grep -v "^${UPLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files PUT files themselves: $(tr '\n' ' ' <<<"${others}")— uploads go through SkyStudioAPI.upload (it retries)"
loop_line="$(line_of 'for attempt in 1...attempts {' "${UPLOAD_API}")"
put_line="$(line_of 'try await put(fileURL, ticket: ticket, onProgress: onProgress)' "${UPLOAD_API}")"
if [ -z "${loop_line}" ] || [ -z "${put_line}" ] || [ "${loop_line}" -ge "${put_line}" ]; then
  fail "${UPLOAD_API}: the PUT must run inside upload's retry loop (for attempt in 1...attempts)"
fi
grep -qF 'try await transfer(task, delegate: delegate, retryable: true)' "${UPLOAD_API}" \
  || fail "${UPLOAD_API}: the PUT's transfer must mark a broken try as retryable (SkyStudioUploadRetry.Broken)"
others="$(code_files_with '\.uploadInterrupted\(SkyStudioUploadInterruption\(' | grep -v "^${UPLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files build an upload interruption: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.upload, after the last try"

# Every job that uploads: the user's localized line and the AI's code and count.
grep -qF 'self.status.issue = uploadInterruption.map(SkyStudioUploadWords.interrupted) ?? message' "${UPLOAD_RUN}" \
  || fail "${UPLOAD_RUN}: the task row must show the localized upload line, not the English message"
generic_line="$(line_of 'payload["next_step"] = .string("Query this original job with get_job' "${UPLOAD_RUN}")"
merge_line="$(line_of 'payload.merge(uploadInterruption.fields(retry:' "${UPLOAD_RUN}")"
if [ -z "${generic_line}" ] || [ -z "${merge_line}" ] || [ "${merge_line}" -le "${generic_line}" ]; then
  fail "${UPLOAD_RUN}: the upload fields must be merged after the generic next step (never 'query this original job' for an unsubmitted upload)"
fi
grep -qF 'uploadInterruption = SkyStudioUploadInterruption.from(failure)' "${UPLOAD_RUN}" \
  || fail "${UPLOAD_RUN}: a failed reference upload must be remembered as an upload interruption"
grep -qF 'uploadInterruption.map(SkyStudioUploadWords.interrupted) ?? SkyStudioJobError.request(failure).message' "${UPLOAD_UPSCALE_JOB}" \
  || fail "${UPLOAD_UPSCALE_JOB}: the upscale's failed state must hold the localized upload line"
grep -qF 'interruption.fields(retry: "call upscale_clip again.")' "${UPLOAD_UPSCALE_TOOL}" \
  || fail "${UPLOAD_UPSCALE_TOOL}: upscale_clip's get_job must carry the upload code and count"
grep -qF 'shown: SkyStudioUploadWords.interrupted(interruption)' "${UPLOAD_CHANGE_JOB}" \
  && grep -qF 'interruption.fields(retry: "call change_voice again.")' "${UPLOAD_CHANGE_JOB}" \
  || fail "${UPLOAD_CHANGE_JOB}: a voice change must show the localized upload line and give the AI the code and count"
grep -qF 'return SkyStudioUploadWords.interrupted(interruption)' "${UPLOAD_LIBRARY_TEXT}" \
  || fail "${UPLOAD_LIBRARY_TEXT}: the voice library must show the localized upload line"
grep -qF 'SkyStudioUploadInterruption.from(error)?.fields(retry:' "${UPLOAD_RECORDING_TOOL}" \
  || fail "${UPLOAD_RECORDING_TOOL}: manage_voices must give the AI the upload code and count"
grep -qF 'case .uploadInterrupted(let interruption):' "${UPLOAD_CHARACTER}" \
  && grep -qF 'activity?.issue = uploadInterruption.map(SkyStudioUploadWords.interrupted) ?? message' "${UPLOAD_CHARACTER_RUN}" \
  && grep -qF 'detail.merge(uploadInterruption.fields(retry:' "${UPLOAD_CHARACTER_RUN}" \
  || fail "${UPLOAD_CHARACTER} / ${UPLOAD_CHARACTER_RUN}: character uploads must show the localized line and give the AI the code and count"
grep -qF 'if let interruption = SkyStudioUploadInterruption.from(error) {' "${UPLOAD_OFFICIAL}" \
  || fail "${UPLOAD_OFFICIAL}: the official references' get_job must carry the upload code and count"

# A cut sent under a temporary name is reported by the name the user knows.
grep -qF 'named: request.originalURL.lastPathComponent' "${UPLOAD_UPSCALE_PIPELINE}" \
  || fail "${UPLOAD_UPSCALE_PIPELINE}: an upscale's upload must be named after the original file"
grep -qF 'named: clipName' "${UPLOAD_CHANGE_JOB}" || fail "${UPLOAD_CHANGE_JOB}: a voice change's upload must be named after the clip"
grep -qF 'named: file.lastPathComponent' "${UPLOAD_RECORDING}" || fail "${UPLOAD_RECORDING}: a voice sample's upload must be named after the user's file"

# The user's line names the network, never a proxy.
proxy_lines="$(grep -hF 'interrupted by the network after %2$d tries' Sources/SrtFlow/Resources/*.lproj/Localizable.strings | grep -iE 'proxy|代理' || true)"
[ -z "${proxy_lines}" ] || fail "the upload line names a proxy in a string table: ${proxy_lines} — say the network (the direct path was just as unstable)"

# SRTFLOW_TEST_UPLOAD_DROPS exists only in debug builds: its file is fenced whole, the API reaches it only inside #if DEBUG, and both
# a build without DEBUG (scripts/check-sky-studio.sh) and the real release binary (scripts/build-app.sh) are searched for its names.
UPLOAD_FAULT="Sources/SrtFlow/CloudMedia/CloudUploadFault.swift"
if [ ! -f "${UPLOAD_FAULT}" ]; then
  fail "${UPLOAD_FAULT} is missing: a rename must be followed here"
else
  [ "$(head -1 "${UPLOAD_FAULT}")" = "#if DEBUG" ] && [ "$(tail -1 "${UPLOAD_FAULT}")" = "#endif" ] \
    || fail "${UPLOAD_FAULT}: the whole file must sit inside #if DEBUG … #endif (release builds carry none of it)"
fi
others="$(code_files_with 'CloudUploadFault|SRTFLOW_TEST_UPLOAD_DROPS' | grep -v -e "^${UPLOAD_FAULT}\$" -e "^${UPLOAD_API}\$" || true)"
[ -z "${others}" ] || fail "these files reach the debug-only upload hook: $(tr '\n' ' ' <<<"${others}")— only SkyStudioAPI.transfer, inside #if DEBUG"
fenced="$(awk '
  /^[[:space:]]*#if DEBUG/ { inside = 1; next }
  /^[[:space:]]*#(else|endif)/ { inside = 0; next }
  /CloudUploadFault/ && !inside { print FILENAME ":" FNR }
' "${UPLOAD_API}")"
[ -z "${fenced}" ] || fail "${UPLOAD_API}: CloudUploadFault is used outside #if DEBUG at ${fenced}"
grep -qF 'strings -a "$BUILD_DIR/$PRODUCT"' scripts/build-app.sh \
  && grep -qF 'grep -F -e SRTFLOW_TEST_UPLOAD_DROPS -e CloudUploadFault' scripts/build-app.sh \
  || fail "scripts/build-app.sh: the release binary must be searched for the debug-only upload hook before it is packaged"
grep -qF 'LEAKED="$(debug_hook_traces "$OUT")"' scripts/check-sky-studio.sh \
  && grep -qF 'if [ -z "$(debug_hook_traces "$DEBUG_OUT")" ]; then' scripts/check-sky-studio.sh \
  || fail "scripts/check-sky-studio.sh: a build without DEBUG must be searched for the upload hook, with the debug build as the control"
