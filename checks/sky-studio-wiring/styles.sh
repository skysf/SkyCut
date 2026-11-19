#!/usr/bin/env bash
# A section of checks/sky-studio-wiring.sh: Sky Studio's editing styles on this Mac (2026-11-19, SS-5; docs/architecture/
# sky-studio-account.md "Sky Studio's editing styles", docs/architecture/ai-control-mcp.md section 4, item 32).
#
# **Not run alone**: sky-studio-wiring.sh sources it before its final gate and shares fail / code_files_with / ACCOUNT / ROUTER.
# Behaviour is pinned by scripts/check-sky-studio.sh (StyleContentChecks, StyleLibraryChecks) and scripts/check-mcp.sh
# (RecipeSkyStudioChecks); this pins the wiring those checks cannot see:
#   - every stored /me answer reaches the library (SkyStudioAccount.replaceStored → licenceChanged), so the texts are deleted when
#     an answer leaves `recipes` out and everything goes with the key;
#   - recipes / save_recipe go through AIRecipeSkyStudio (the list and the licence first); nothing else calls the pure answers;
#   - the App has one library, asking only over SkyStudioAPI.uncachedSession (no system URL cache keeping copies SkyCut cannot
#     delete) and reading the key silently (never a keychain prompt); only the library asks the content routes;
#   - what the AI is told when the licence refuses is asked only through SkyStudioAccount (styleRefusal), like aiRefusal.
#   - the film's record (SS5 plan 5.5) is stamped only inside VideoEditProject.perform's final state (the change's own undo step),
#     the reads it stamps are noted only by AIRecipeSkyStudio, and get_timeline reports it.

STYLE_LIBRARY="Sources/SrtFlow/SkyStudio/SkyStudioStyleLibrary.swift"
STYLE_GLUE="Sources/SrtFlow/AIRecipeSkyStudio.swift"
for file in "${STYLE_LIBRARY}" "${STYLE_GLUE}"; do
  [ -f "${file}" ] || fail "missing ${file}: renamed? update checks/sky-studio-wiring/styles.sh (an empty scan is a false green)"
done

REPLACE_BODY="$(awk '/private func replaceStored\(/,/^    \}/' "${ACCOUNT}")"
grep -qF 'SkyStudioStyles.shared.licenceChanged(hasKey: hasKey, entitled: answer?.me.skycut.features.recipes == true)' <<<"${REPLACE_BODY}" \
  || fail "${ACCOUNT}: replaceStored must tell the style library about every stored answer (texts go without recipes, all without a key)"

grep -qF 'case .recipes: return try await AIRecipeSkyStudio.recipes(args, project)' "${ROUTER}" \
  && grep -qF 'let result = try await AIRecipeSkyStudio.save(args)' "${ROUTER}" \
  || fail "${ROUTER}: recipes and save_recipe go through AIRecipeSkyStudio (Sky Studio's list and the licence first)"
others="$(code_files_with 'AIRecipeTools\.(recipes|save)\(' | grep -v "^${STYLE_GLUE}\$" || true)"
[ -z "${others}" ] || fail "these files call the pure recipes answers directly: $(tr '\n' ' ' <<<"${others}")- only AIRecipeSkyStudio does"

grep -qF 'static let shared = SkyStudioStyleLibrary(licence: { SkyStudioAccount.shared.license })' "${STYLE_GLUE}" \
  || fail "${STYLE_GLUE}: the App's one style library takes the licence from SkyStudioAccount"
others="$(code_files_with 'SkyStudioStyleLibrary\(' | grep -v "^${STYLE_GLUE}\$" || true)"
[ -z "${others}" ] || fail "these files make another style library: $(tr '\n' ' ' <<<"${others}")- the App has one (SkyStudioStyles.shared)"
grep -qF 'api: @escaping () -> SkyStudioAPI = { SkyStudioAPI(session: SkyStudioAPI.uncachedSession) }' "${STYLE_LIBRARY}" \
  || fail "${STYLE_LIBRARY}: content is asked over SkyStudioAPI.uncachedSession (no system URL cache)"
grep -qF 'key: @escaping () async -> Result<String, SkyStudioJobKey.Problem> = { await SkyStudioJobKey.key(.silent) }' "${STYLE_LIBRARY}" \
  || fail "${STYLE_LIBRARY}: the key is read silently (never a keychain prompt)"
others="$(code_files_with '\.content(Style|Manifest)\(' | grep -v "^${STYLE_LIBRARY}\$" | grep -v '/SkyStudioContentAPI\.swift$' || true)"
[ -z "${others}" ] || fail "these files ask Sky Studio's content routes themselves: $(tr '\n' ' ' <<<"${others}")- only SkyStudioStyleLibrary does"

others="$(code_files_with 'SkyCutGates\.styleRefusal\(' | grep -v "^${ACCOUNT}\$" || true)"
[ -z "${others}" ] || fail "these files call SkyCutGates.styleRefusal: $(tr '\n' ' ' <<<"${others}")- only through SkyStudioAccount.styleRefusal"

PROJECT_FILE="Sources/SrtFlow/VideoEditProject.swift"
PERFORM_BODY="$(awk '/    func perform\(/,/^    \}/' "${PROJECT_FILE}")"
grep -qF 'state = AIEditingStyleStamp.stamped(next, project: shortID)' <<<"${PERFORM_BODY}" \
  || fail "${PROJECT_FILE}: perform stamps the film's editing style into its final state (the change's own undo step)"
others="$(code_files_with 'AIEditingStyleStamp\.stamped\(' | grep -v "^${PROJECT_FILE}\$" || true)"
[ -z "${others}" ] || fail "these files stamp the editing style outside perform: $(tr '\n' ' ' <<<"${others}")- a read-only call must never write it"
others="$(code_files_with 'AIEditingStyleStamp\.noteRead\(' | grep -v "^${STYLE_GLUE}\$" || true)"
[ -z "${others}" ] || fail "these files note style reads: $(tr '\n' ' ' <<<"${others}")- only recipes (AIRecipeSkyStudio) does"
grep -qF 'object["editing_style"] = AIEditingStyleStamp.report(state)' Sources/SrtFlow/AITimelineTools.swift \
  || fail "get_timeline does not report editing_style"
grep -qF 'library.read(style.id, version: version, sha256: version == pin?.version ? pin?.sha256 : nil)' "${STYLE_GLUE}" \
  || fail "${STYLE_GLUE}: a film's pinned version is read by id + version + the checksum it records (Codex review CXS1 #5)"
