#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: music length, delivered length and a generated video's own sound
# (2026-11-19, production feedback MCP-18 / MCP-9 / MCP-42; Sky Studio's contract "Music length, delivered lengths and video sound").
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with.
# The behaviour is pinned by scripts/check-sky-studio.sh (MusicLengthChecks, VideoSoundChecks, GenerationDurationChecks, against
# Sky Studio's own catalog records); this section pins the wiring those pure checks cannot see:
#   - each music model's length is judged where every model choice asks (SkyStudioModelPolicy.problem), and the request's length
#     comes from SkyStudioMusicLength only; no music model id is written in App code (the catalog's order and `length` decide);
#   - a video's audio_mode is judged where every model choice asks (SkyStudioGenerationControls.problem), read from the tool's
#     arguments with the shared vocabulary, and written into a request only by SkyStudioVideoSound.apply;
#   - the finished job's `audio` block and note reach get_job (SkyStudioGenerationRun.succeed), with no second, hard-coded note;
#   - the tool refuses an impossible music request with each model's reason, and Sky Studio's own refusals get a plain next step;
#   - a flat-priced music model's length is not counted as going beyond the draft.
# Long-term rules: docs/architecture/sky-studio-jobs.md, "Music length and video sound".

LENGTH_FILE="Sources/SrtFlow/SkyStudio/SkyStudioMusicLength.swift"
SOUND_FILE="Sources/SrtFlow/SkyStudio/SkyStudioVideoSound.swift"
REFUSAL_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRefusal.swift"
POLICY_FILE="Sources/SrtFlow/SkyStudio/SkyStudioModelPolicy.swift"
CONTROLS_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerationControls.swift"
GENERATION_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGeneration.swift"
TOOL_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
RUN_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
CHARACTER_FILE="Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift"
DRAFT_FILE="Sources/SrtFlow/AIDraftPolicy.swift"
for file in "${LENGTH_FILE}" "${SOUND_FILE}" "${REFUSAL_FILE}" "${POLICY_FILE}" "${CONTROLS_FILE}" "${GENERATION_FILE}" "${TOOL_FILE}" \
            "${RUN_FILE}" "${CHARACTER_FILE}" "${DRAFT_FILE}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

grep -qF 'if let problem = SkyStudioMusicLength.problem(model: model, ask: ask) { return problem }' "${POLICY_FILE}" \
  || fail "${POLICY_FILE}: every model choice must ask SkyStudioMusicLength.problem (a music model's length and vocals)"
grep -qF 'SkyStudioMusicLength.seconds(for: ask, model: model)' "${GENERATION_FILE}" \
  || fail "${GENERATION_FILE}: a music request's length must come from SkyStudioMusicLength.seconds (the model's steps and default)"
others="$(code_files_with '"(lyria-3-pro|stable-audio-3-medium)"' || true)"
[ -z "${others}" ] || fail "these files write a music model id in code: $(tr '\n' ' ' <<<"${others}")— the catalog's order and length decide"

grep -qF 'if let problem = SkyStudioVideoSound.problem(model: model, ask: ask) { return problem }' "${CONTROLS_FILE}" \
  || fail "${CONTROLS_FILE}: every model choice must ask SkyStudioVideoSound.problem (none only where the model lists it)"
grep -qF 'ask.audioMode = try args.choice("audio_mode", from: MCPVocabulary.videoAudioModes)' "${CONTROLS_FILE}" \
  && grep -qF 'ask.exactLength = try args.bool("exact_length") ?? false' "${CONTROLS_FILE}" \
  || fail "${CONTROLS_FILE}: audio_mode (shared vocabulary) and exact_length must be read from the tool's arguments"
grep -qF 'SkyStudioVideoSound.apply(ask, model: model, to: &params)' "${GENERATION_FILE}" \
  || fail "${GENERATION_FILE}: the video branch must add the asked sound mode through SkyStudioVideoSound.apply"
others="$(code_files_with 'params\["audio_mode"\] =' | grep -v "^${SOUND_FILE}\$" || true)"
[ -z "${others}" ] || fail "these files write audio_mode into a request: $(tr '\n' ' ' <<<"${others}")— only SkyStudioVideoSound.apply does"

grep -qF 'if generation.kind.isVideo { detail.merge(SkyStudioVideoSound.resultDetail(result)) { _, sound in sound } }' "${RUN_FILE}" \
  || fail "${RUN_FILE}: a finished video's audio block and note must reach get_job through SkyStudioVideoSound.resultDetail"
! grep -qF 'Generated clips may carry their own sound' "${RUN_FILE}" \
  || fail "${RUN_FILE}: the general sound note lives only in SkyStudioVideoSound (one note, not two)"

grep -qF 'if requested == nil, kind == .music, let refusal = SkyStudioMusicLength.refusal(catalog.models(kind: kind.rawValue), ask: ask) { throw AIToolError(refusal) }' "${TOOL_FILE}" \
  || fail "${TOOL_FILE}: a music request no model can make must be refused with each model's reason (SkyStudioMusicLength.refusal)"
grep -qF 'draftAsk.exactLength = false' "${TOOL_FILE}" \
  || fail "${TOOL_FILE}: the draft model compared for the price must not inherit exact_length (it has no length to be exact about)"
grep -qF 'SkyStudioGenerationRefusal.nextStep(value) ?? nextStep(value.code)' "${CHARACTER_FILE}" \
  || fail "${CHARACTER_FILE}: Sky Studio's refusals of a length, vocals or sound must get a plain next step (SkyStudioGenerationRefusal)"
grep -qF 'seconds > base, !lengthIsFree(model)' "${DRAFT_FILE}" \
  || fail "${DRAFT_FILE}: a music model priced per song or clip costs the same at any length; its length is not beyond the draft"
