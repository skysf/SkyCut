#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: reference images fitted to the published limits (2026-11-23,
# docs/architecture/reference-image-fitting.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with.
# The behaviour is pinned by scripts/check-sky-studio.sh (ReferenceFitChecks, ReferenceImageFitChecks); this section pins the
# wiring those checks cannot compile:
#   - every reference goes through SkyStudioReferenceImageFit.prepare before SkyStudioAPI.upload, and the fitted copy (not the
#     original) is what goes up, then is removed;
#   - both generate tools set the plan's target from the chosen model and its fallbacks (SkyStudioModelPolicy.chain);
#   - the official prepared references carry the target in their identity (a token prepared under other limits is refused);
#   - SkyCut's fitting code writes no limit number: every limit comes from /models;
#   - the file is measured again at upload time (it may have been rewritten since the quote);
#   - a fitting failure reaches the cloud task row in the user's words (SkyStudioReferenceFitWords), get_job in English;
#   - when no model takes a request, both tools list each model's own reason (which names its limit).

FIT_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFit.swift"
FIT_IMAGE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceImageFit.swift"
FILES_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFiles.swift"
GENERATE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
OFFICIAL_TOOL_FILE="Sources/SrtFlow/SkyStudio/SkyStudioOfficialGenerateTool.swift"
PREPARATION_FILE="Sources/SrtFlow/SkyStudio/SkyStudioOfficialPreparation.swift"
FAILURE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFitFailure.swift"
WORDS_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFitWords.swift"
RUN_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
for file in "${FIT_FILE}" "${FIT_IMAGE_FILE}" "${FILES_FILE}" "${GENERATE_FILE}" "${OFFICIAL_TOOL_FILE}" "${PREPARATION_FILE}" \
            "${FAILURE_FILE}" "${WORDS_FILE}" "${RUN_FILE}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

grep -qF 'let sent = try await SkyStudioReferenceImageFit.prepare(file, fit: plan.fit)' "${FILES_FILE}" \
  && grep -qF 'defer { sent.cleanUp() }' "${FILES_FILE}" \
  && grep -qF 'api.upload(fileURL: sent.url, contentType: type,' "${FILES_FILE}" \
  || fail "${FILES_FILE}: every reference must be prepared (fitted when over the limits), uploaded as prepared, then cleaned up"
! grep -qF 'api.upload(fileURL: file.file' "${FILES_FILE}" \
  || fail "${FILES_FILE}: a reference must not go up as the original file behind the fitting"
for file in "${GENERATE_FILE}" "${OFFICIAL_TOOL_FILE}"; do
  grep -qF 'references.fit = SkyStudioReferenceFit.strictest(SkyStudioModelPolicy.chain(catalog: catalog, kind: kind.rawValue, requested: requested,' "${file}" \
    || fail "${file}: the reference plan's target must be the strictest limits of the chosen model and its fallbacks"
done
grep -qF 'generation.notes += SkyStudioReferenceFit.notes(references)' "${GENERATE_FILE}" \
  || fail "${GENERATE_FILE}: the answer's notes must name each image that will be fitted (the AI tells the user)"
grep -qF 'if let fit = plan.fit, plan.files.contains(where: { $0.type == "image" }) { sources.append(["fit": fit.json]) }' "${PREPARATION_FILE}" \
  || fail "${PREPARATION_FILE}: the prepared references' identity must carry the fitting target"
grep -qF 'MediaReadQueue.run(on: MediaReadQueue.analysis)' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: decoding and encoding must run on MediaReadQueue.analysis, not on the cooperative pool"
grep -qF 'guard bytes > 0, let file = SkyStudioReferenceImage.measure(planned.file, role: planned.role, bytes: bytes) else {' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: the file must be measured again at upload time (the same path may hold other bytes since the quote)"
grep -qF 'status.issue = SkyStudioReferenceFitWords.shown(failure)' "${RUN_FILE}" \
  || fail "${RUN_FILE}: a fitting failure must reach the task row in the user's words (status.issue is drawn verbatim)"
for file in "${GENERATE_FILE}" "${OFFICIAL_TOOL_FILE}"; do
  grep -qF 'SkyStudioModelPolicy.refusal(catalog: catalog, kind: kind.rawValue, operation: ask.operation' "${file}" \
    || fail "${file}: with no model taking the request, each model's own reason (and limit) must be listed"
done
numbers="$(grep -nE '[0-9]{3}_[0-9]{3}|[0-9]{7,}|1024 \* 1024' "${FIT_FILE}" "${FIT_IMAGE_FILE}" "${FAILURE_FILE}" "${WORDS_FILE}" || true)"
[ -z "${numbers}" ] || fail "SkyCut's fitting code writes a limit number; limits come only from /models: ${numbers}"
