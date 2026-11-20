#!/usr/bin/env bash
# A section of checks/sky-studio-wiring.sh: Sky Studio's craft cards (craft_cards, 2026-11-20, SS5 plan 5.6;
# docs/architecture/sky-studio-account.md "Sky Studio's editing styles on this Mac", docs/architecture/ai-control-mcp.md
# section 4, item 32).
#
# **Not run alone**: sky-studio-wiring.sh sources it before its final gate and shares fail / code_files_with / ACCOUNT / ROUTER.
# Behaviour is pinned by scripts/check-sky-studio.sh (CardContentChecks, CardLibraryChecks) and scripts/check-mcp.sh
# (RecipeSkyStudioChecks); this pins the wiring those checks cannot see:
#   - the router hands craft_cards to AICraftCardsTool, in recipes' Policy row (no queue, no window, no round);
#   - AICraftCardsTool asks the licence first (SkyStudioAccount.cardRefusal, nothing asked without recipes), then the list, then
#     the page, through the App's one content library (SkyStudioStyles.shared); only it reads card pages and builds the answer;
#   - what the AI is told when the licence refuses is asked only through SkyStudioAccount (cardRefusal), like styleRefusal;
#   - the card routes are asked only by the library (the styles section pins the library's session and silent key).

CARD_TOOL="Sources/SrtFlow/AICraftCardsTool.swift"
[ -f "${CARD_TOOL}" ] || fail "missing ${CARD_TOOL}: renamed? update checks/sky-studio-wiring/cards.sh (an empty scan is a false green)"

grep -qF 'case .craftCards: return try await AICraftCardsTool.read(args)' "${ROUTER}" \
  || fail "${ROUTER}: craft_cards goes through AICraftCardsTool (the licence, the list, then the page)"
grep -qE 'case \.recipes, \.saveRecipe, \.skycutGuide, \.craftCards:' "${ROUTER}" \
  || fail "${ROUTER}: craft_cards shares recipes' Policy row (no queue, no window, no round)"

TOOL_BODY="$(sed 's,//.*,,' "${CARD_TOOL}")"
refusal_at="$(grep -n 'SkyStudioAccount.shared.cardRefusal' <<<"${TOOL_BODY}" | head -1 | cut -d: -f1 || true)"
listing_at="$(grep -n 'await library.refreshedListing()' <<<"${TOOL_BODY}" | head -1 | cut -d: -f1 || true)"
read_at="$(grep -n 'try await library.readCard(page)' <<<"${TOOL_BODY}" | head -1 | cut -d: -f1 || true)"
if [ -z "${refusal_at}" ] || [ -z "${listing_at}" ] || [ -z "${read_at}" ] \
  || [ "${refusal_at}" -gt "${listing_at}" ] || [ "${listing_at}" -gt "${read_at}" ]; then
  fail "${CARD_TOOL}: the licence (cardRefusal), then the list (refreshedListing), then the page (readCard), in that order"
fi
grep -qF 'let library = SkyStudioStyles.shared' <<<"${TOOL_BODY}" \
  || fail "${CARD_TOOL}: cards are read through the App's one content library (SkyStudioStyles.shared)"

others="$(code_files_with '\.readCard\(' | grep -v "^${CARD_TOOL}\$" || true)"
[ -z "${others}" ] || fail "these files read craft-card pages: $(tr '\n' ' ' <<<"${others}")- only AICraftCardsTool does"
others="$(code_files_with 'AICraftCardsAnswer\.answer\(' | grep -v "^${CARD_TOOL}\$" || true)"
[ -z "${others}" ] || fail "these files build the craft_cards answer: $(tr '\n' ' ' <<<"${others}")- only AICraftCardsTool does"
others="$(code_files_with 'SkyCutGates\.cardRefusal\(' | grep -v "^${ACCOUNT}\$" || true)"
[ -z "${others}" ] || fail "these files call SkyCutGates.cardRefusal: $(tr '\n' ' ' <<<"${others}")- only through SkyStudioAccount.cardRefusal"
others="$(code_files_with '\.contentCardPage\(' | grep -v '/SkyStudioStyleLibrary\.swift$' | grep -v '/SkyStudioContentAPI\.swift$' || true)"
[ -z "${others}" ] || fail "these files ask Sky Studio's card routes themselves: $(tr '\n' ' ' <<<"${others}")- only SkyStudioStyleLibrary does"
