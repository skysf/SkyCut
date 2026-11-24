#!/usr/bin/env bash
# One section of checks/sky-studio-wiring.sh: reference images fitted to the published limits (2026-11-23,
# docs/architecture/reference-image-fitting.md).
#
# **Not run on its own**: sky-studio-wiring.sh loads it with `source` (before its final gate) and shares fail / code_files_with.
# The behaviour is pinned by scripts/check-sky-studio.sh (ReferenceFitChecks, ReferenceImageFitChecks, ReferenceTotalChecks);
# this section pins the wiring those checks cannot compile:
#   - every reference goes through SkyStudioReferenceImageFit.prepare before SkyStudioAPI.upload, the whole set before the first
#     upload (2026-11-24: a model's total for all reference images together is shared among them), and the fitted copy (not the
#     original) is what goes up, then is removed;
#   - the set's total pass runs whenever the limits carry a total (SkyStudioReferenceImageFit.shareTotal, deciding with real
#     copies: SkyStudioReferenceSetImage);
#   - every image is copied as it is (a snapshot) before it is measured, and only that copy (or one made from it) goes up: the
#     user's path is never read again after the check (Codex review of #551);
#   - an image that cannot be fitted keeps the official preparation's row in the user's words, with a next step; a /jobs
#     too_large_together refusal gets the user's words and its own next step;
#   - both generate tools set the plan's target from the chosen model and its fallbacks (SkyStudioModelPolicy.chain);
#   - the official prepared references carry the target in their identity (a token prepared under other limits is refused);
#   - SkyCut's fitting code writes no limit number: every limit comes from /models;
#   - the file is measured again at upload time (it may have been rewritten since the quote);
#   - a fitting failure reaches the cloud task row in the user's words (SkyStudioReferenceFitWords), get_job in English;
#   - when no model takes a request, both tools list each model's own reason (which names its limit).

FIT_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFit.swift"
TOTAL_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceTotal.swift"
SET_IMAGE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceSetImage.swift"
FIT_IMAGE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceImageFit.swift"
FILES_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFiles.swift"
GENERATE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
OFFICIAL_TOOL_FILE="Sources/SrtFlow/SkyStudio/SkyStudioOfficialGenerateTool.swift"
PREPARATION_FILE="Sources/SrtFlow/SkyStudio/SkyStudioOfficialPreparation.swift"
FAILURE_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFitFailure.swift"
WORDS_FILE="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFitWords.swift"
RUN_FILE="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
for file in "${FIT_FILE}" "${TOTAL_FILE}" "${SET_IMAGE_FILE}" "${FIT_IMAGE_FILE}" "${FILES_FILE}" "${GENERATE_FILE}" "${OFFICIAL_TOOL_FILE}" "${PREPARATION_FILE}" \
            "${FAILURE_FILE}" "${WORDS_FILE}" "${RUN_FILE}"; do
  [ -f "${file}" ] || fail "${file} is missing: a rename must be followed here (an empty scan is a false green)"
done

grep -qF 'let prepared = try await SkyStudioReferenceImageFit.prepare(plan.files, fit: plan.fit)' "${FILES_FILE}" \
  && grep -qF 'defer { prepared.forEach { $0.cleanUp() } }' "${FILES_FILE}" \
  && grep -qF 'for (index, (file, sent)) in zip(plan.files, prepared).enumerated() {' "${FILES_FILE}" \
  && grep -qF 'api.upload(fileURL: sent.url, contentType: type,' "${FILES_FILE}" \
  || fail "${FILES_FILE}: every reference must be prepared, all of them before the first upload (fitted to their limits and to a total), uploaded as prepared, then cleaned up"
! grep -qF 'api.upload(fileURL: file.file' "${FILES_FILE}" \
  || fail "${FILES_FILE}: a reference must not go up as the original file behind the fitting"
! grep -qF 'SkyStudioReferenceImageFit.prepare(file, fit:' "${FILES_FILE}" \
  || fail "${FILES_FILE}: a reference prepared alone never shares the models' total for all reference images; prepare the set"
grep -qF 'if let fit, let total = fit.maxTotalBytes {' "${FIT_IMAGE_FILE}" \
  && grep -qF 'Result { try shareTotal(each, fit: fit, total: total, folder: folder) }' "${FIT_IMAGE_FILE}" \
  && grep -qF 'var each = images.map { SkyStudioReferenceSetImage(prepared[$0], fit: fit) }' "${FIT_IMAGE_FILE}" \
  && grep -qF 'guard try SkyStudioReferenceTotal.share(&each, total: total) else {' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: a set over the total for all reference images must be shared with real copies (SkyStudioReferenceTotal.share) before upload"
grep -qF 'guard var snapshot = try? snapshot(of: planned.file, folder: folder) else { throw unreadable }' "${FIT_IMAGE_FILE}" \
  && grep -qF 'try FileManager.default.copyItem(at: file, to: copy)' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: each image must be copied as it is (a snapshot) before it is measured: what is checked is what goes up"
! grep -qF 'measure(planned.file' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: an image is measured from its snapshot, never from the user's path (it may change before the upload)"
grep -qF 'status.issue = SkyStudioReferenceFitWords.shown(failure)' "${PREPARATION_FILE}" \
  && grep -qF 'detail["next_step"] = .string(SkyStudioReferenceFitFailure.preparedNextStep)' "${PREPARATION_FILE}" \
  || fail "${PREPARATION_FILE}: an image that cannot be fitted keeps the row in the user's words and gives get_job what to change"
grep -qF 'if together, let limit = lastFailure?.limit { self.status.issue = SkyStudioReferenceFitWords.together(limit: limit) }' "${RUN_FILE}" \
  && grep -qF 'if together { payload["next_step"] = .string(SkyStudioReferenceFitFailure.togetherNextStep(limit: lastFailure?.limit)) }' "${RUN_FILE}" \
  || fail "${RUN_FILE}: a /jobs too_large_together refusal shows the user's words and says nothing was submitted or charged and what to change"
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
grep -qF 'guard bytes > 0, let file = SkyStudioReferenceImage.measure(snapshot.url, role: planned.role, bytes: bytes) else { throw unreadable }' "${FIT_IMAGE_FILE}" \
  || fail "${FIT_IMAGE_FILE}: the file must be measured again at upload time (the same path may hold other bytes since the quote)"
grep -qF 'status.issue = SkyStudioReferenceFitWords.shown(failure)' "${RUN_FILE}" \
  || fail "${RUN_FILE}: a fitting failure must reach the task row in the user's words (status.issue is drawn verbatim)"
for file in "${GENERATE_FILE}" "${OFFICIAL_TOOL_FILE}"; do
  grep -qF 'SkyStudioModelPolicy.refusal(catalog: catalog, kind: kind.rawValue, operation: ask.operation' "${file}" \
    || fail "${file}: with no model taking the request, each model's own reason (and limit) must be listed"
done
numbers="$(grep -nE '[0-9]{3}_[0-9]{3}|[0-9]{7,}|1024 \* 1024' "${FIT_FILE}" "${TOTAL_FILE}" "${SET_IMAGE_FILE}" "${FIT_IMAGE_FILE}" "${FAILURE_FILE}" "${WORDS_FILE}" || true)"
[ -z "${numbers}" ] || fail "SkyCut's fitting code writes a limit number; limits come only from /models: ${numbers}"
