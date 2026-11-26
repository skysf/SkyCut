#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: identical paid requests in a row (user, 2026-11-25 / 26; SkyStudioRepeatGuard) and the
# panels' Download again for their own clip (backlog B47's UI half).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / count / line_of /
# code_files_with. The behaviour is pinned by scripts/check-sky-studio.sh (RepeatGuardChecks: counting, words, identities, the gate's
# questions) and scripts/check-voice-recovery.sh (RepeatRequestChecks / RepeatPanelChecks: the tool entries with POSTs counted, the
# panels); this section pins the wiring those checks cannot see:
#   - each paid AI tool that counts builds the identity only through SkyStudioRequestDigest, takes its place in the run before its gate
#     (generate_media, upscale_clip, manage_characters: inside SkyStudioJobGate.decide; manage_voices design: inside voiceOneTime;
#     change_voice and add_voiceover: SkyStudioJobGate.repeatConfirmation before the reservation), counts itself only after its job
#     started, and adds the line to its result;
#   - only the gate approves a run and only the gate asks (AIConfirmations stays in SkyStudioJobGate);
#   - panels are never counted: nothing on the panels' path (the panels, their models, the shared voice change start, the upscale job,
#     the design dialog) touches the run registry; the official film's own submission flow does not count either (each submission
#     needs its own quote token and seam review, so an identical one cannot be sent again by repeating a call);
#   - the panels reach a held paid result only through SkyStudioPanelHeldDownload, by the job's own clip and project opening;
#   - the voice-recovery suite they run in keeps room under its watchdog and prints the binary's own seconds.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Identical paid requests in a row".

REPEAT_GUARD="Sources/SrtFlow/SkyStudio/SkyStudioRepeatGuard.swift"
REPEAT_WORDS="Sources/SrtFlow/SkyStudio/SkyStudioRepeatWords.swift"
REPEAT_DIGEST="Sources/SrtFlow/SkyStudio/SkyStudioRequestDigest.swift"
REPEAT_HELD="Sources/SrtFlow/SkyStudio/SkyStudioPanelHeldDownload.swift"
REPEAT_GATE="Sources/SrtFlow/SkyStudio/SkyStudioJobGate.swift"
for file in "${REPEAT_GUARD}" "${REPEAT_WORDS}" "${REPEAT_DIGEST}" "${REPEAT_HELD}" "${REPEAT_GATE}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

# tool file | its Tool case | the gate call that carries the run | the line that starts its job
repeat_tools=(
  "Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift|generateMedia|repeated: repeated) {|let job = run.start()"
  "Sources/SrtFlow/AIUpscaleTool.swift|upscaleClip|profile: AIDraftPolicy.profile(row.quote), repeated: repeated) {|UpscaleActivity.shared.add(job, opensCompare: false)"
  "Sources/SrtFlow/SkyStudio/SkyStudioCharacterManageTool.swift|manageCharacters|repeated: repeated) {|SkyStudioCharacterRun(receipt:"
  "Sources/SrtFlow/SkyStudio/SkyStudioVoiceDesignTool.swift|manageVoices|ask: ask, repeated: repeated) {|SkyStudioVoiceDesignOrder.start("
  "Sources/SrtFlow/VoiceChange/VoiceChangeTool.swift|changeVoice|SkyStudioJobGate.repeatConfirmation(repeated|VoiceChangeOrder.start("
  "Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverStart.swift|addVoiceover|SkyStudioJobGate.repeatConfirmation(repeated|SkyStudioVoiceoverRun(input:"
)
for entry in "${repeat_tools[@]}"; do
  IFS='|' read -r file tool gate start <<<"${entry}"
  [ -f "${file}" ] || { fail "${file} is missing: a rename must be followed here"; continue; }
  grep -qF 'SkyStudioRequestDigest.identity(' "${file}" \
    || fail "${file}: the identity of an identical request is the resolved request, built only by SkyStudioRequestDigest (never the raw arguments)"
  check_line="$(line_of "SkyStudioRepeatGuard.shared.check(.${tool}," "${file}")"
  gate_line="$(line_of "${gate}" "${file}")"
  start_line="$(line_of "${start}" "${file}")"
  started_line="$(line_of 'SkyStudioRepeatGuard.shared.started(repeated)' "${file}")"
  if [ -z "${check_line}" ] || [ -z "${gate_line}" ] || [ -z "${start_line}" ] || [ -z "${started_line}" ] \
     || [ "${check_line}" -gt "${gate_line}" ] || [ "${gate_line}" -ge "${start_line}" ] || [ "${start_line}" -gt "${started_line}" ]; then
    fail "${file}: take the request's place in its run (check .${tool}) before the gate (${gate}), and count it only after its job started (${start} → started)"
  fi
  [ "$(count 'SkyStudioRepeatGuard.shared.started(' "${file}")" -eq 1 ] || fail "${file}: a request is counted once, when its job started"
  grep -qF 'SkyStudioRepeatWords.adding(repeated, to:' "${file}" || fail "${file}: the result says which identical request it is (SkyStudioRepeatWords.adding)"
done
# The two tools that ask nothing else ask before their reservation.
for pair in "Sources/SrtFlow/VoiceChange/VoiceChangeTool.swift|SkyStudioJobGate.reserveWithoutAsking(" \
            "Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverStart.swift|SkyStudioVoiceBudget.reserve("; do
  file="${pair%%|*}"; reserve="${pair##*|}"
  ask_line="$(line_of 'SkyStudioJobGate.repeatConfirmation(' "${file}")"; reserve_line="$(line_of "${reserve}" "${file}")"
  if [ -z "${ask_line}" ] || [ -z "${reserve_line}" ] || [ "${ask_line}" -ge "${reserve_line}" ]; then
    fail "${file}: the 5th identical request asks (SkyStudioJobGate.repeatConfirmation) before anything is reserved (${reserve})"
  fi
done

# Only the gate approves a run, and only the six tools count one.
approvers="$(code_files_with 'SkyStudioRepeatGuard\.shared\.approve\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${approvers}" = "${REPEAT_GATE} " ] || fail "only SkyStudioJobGate approves a run of identical requests (after the user's token): ${approvers:-none}"
counters="$(code_files_with 'SkyStudioRepeatGuard\.shared\.started\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
expected="$(for entry in "${repeat_tools[@]}"; do echo "${entry%%|*}"; done | LC_ALL=C sort -u | tr '\n' ' ')"
[ "${counters}" = "${expected}" ] || fail "only the six paid AI tools count identical requests (expected ${expected}got ${counters:-none})"

# Panels are never counted; the official film's submission flow does not count either.
for file in Sources/SrtFlow/Upscale/UpscalePanel.swift Sources/SrtFlow/Upscale/UpscalePanelModel.swift Sources/SrtFlow/Upscale/UpscaleJob.swift \
            Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift Sources/SrtFlow/VoiceChange/VoiceChangePanelModel.swift \
            Sources/SrtFlow/VoiceChange/VoiceChangeOrder.swift Sources/SrtFlow/VoiceLibrary/DesignVoiceModel.swift \
            Sources/SrtFlow/SkyStudio/SkyStudioVoiceDesignOrder.swift Sources/SrtFlow/SkyStudio/SkyStudioOfficialGenerateTool.swift; do
  [ -f "${file}" ] || { fail "${file} is missing: a rename must be followed here"; continue; }
  if grep -qE 'SkyStudioRepeatGuard|SkyStudioJobGate\.repeatConfirmation' <<<"$(sed 's,//.*,,' "${file}")"; then
    fail "${file}: a panel's click (or an official submission with its own quote and review) is never counted as an identical request"
  fi
done

# The panels reach a held result only through SkyStudioPanelHeldDownload, by the job's own clip and project opening.
grep -qF '$0.projectGeneration == project.documentGeneration && $0.clipIDs.contains(clipID) && $0.canRetryDownload' "${REPEAT_HELD}" \
  && grep -qF 'VoiceChangeActivity.shared.lastJob(for: clipID, generation: project.documentGeneration)' "${REPEAT_HELD}" \
  && ! grep -qE 'originalURL|forOriginal|sourceURL|request\.' <<<"$(sed 's,//.*,,' "${REPEAT_HELD}")" \
  || fail "${REPEAT_HELD}: a panel finds a held job by the job's own clip and project opening, never by a request's parameters or source file"
grep -qF 'SkyStudioPanelHeldDownload.upscale(project: project, clipID: target.id)' Sources/SrtFlow/Upscale/UpscalePresenter.swift \
  && grep -qF 'held = SkyStudioPanelHeldDownload.voiceChange(project: project, clipID: clipID)' Sources/SrtFlow/VoiceChange/VoiceChangePanelModel.swift \
  || fail "the upscale and change-voice panels read their clip's held result through SkyStudioPanelHeldDownload when they open"
for file in Sources/SrtFlow/Upscale/UpscalePanel.swift Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift Sources/SrtFlow/VoiceChange/VoiceChangePanelModel.swift; do
  if grep -qE 'SkyStudioHeldDownloads|retryDownload|UpscaleActivity\.shared\.(jobs|downloadAgain)' <<<"$(sed 's,//.*,,' "${file}")"; then
    fail "${file}: a panel reaches a held result only through SkyStudioPanelHeldDownload (by its own clip), never by looking jobs up itself"
  fi
done
grep -qF 'Button("Download again") { held.downloadAgain(); dismiss() }' Sources/SrtFlow/Upscale/UpscalePanel.swift \
  && grep -qF 'Button("Download again") { held.downloadAgain(); dismiss() }' Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift \
  || fail "after a failed download the panels offer Download again (free) for their clip's own held job"
noters="$(code_files_with 'VoiceChangeActivity\.shared\.noteJob\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${noters}" = "Sources/SrtFlow/VoiceChange/VoiceChangeOrder.swift " ] \
  || fail "a voice change's job is noted for its clip only where both entries start it (VoiceChangeOrder.start): ${noters:-none}"

# The suite RepeatRequestChecks / RepeatPanelChecks run in keeps room under its watchdog and prints the binary's own seconds, so each
# CI log shows the margin (FBR1 on PR #557: these checks took the CI step from 213 to 240 s, and nothing printed the binary's share).
VOICE_RECOVERY="scripts/check-voice-recovery.sh"
watchdog="$(grep -E '^WATCHDOG = [0-9]+$' "${VOICE_RECOVERY}" | grep -oE '[0-9]+' || true)"
{ [ -n "${watchdog}" ] && [ "${watchdog}" -ge 480 ] && grep -qF 'timeout=WATCHDOG' "${VOICE_RECOVERY}" \
    && grep -qF 'print(f"voice-recovery binary: ' "${VOICE_RECOVERY}"; } \
  || fail "${VOICE_RECOVERY}: the watchdog keeps at least 480 s and the wrapper prints the binary's elapsed seconds"
