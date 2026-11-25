#!/usr/bin/env bash
# One part of checks/sky-studio-wiring.sh: SkyCut's own daily credit limit stopping a request (MSG1, 2026-11-24).
#
# Not run alone: sky-studio-wiring.sh sources it (before its final gate) and shares fail / code_files_with and ${SECTION}.
# The words and numbers are checked by scripts/check-sky-studio.sh (DailyLimitChecks); this part pins the wiring:
#   - every daily-limit refusal the AI gets is built by SkyCutDailyLimit.aiResult through SkyStudioJobGate.budgetBlocked: no
#     other file writes the code daily_budget_exceeded (a second copy would drift back to "the daily budget is exhausted"); its
#     option (a) asks the suggested raise in advance through AISettingsApproval.limitRaise (the user's 「只问一次」);
#   - the paid panels (Upscale, Design a Voice, Change Voice) show DailyCreditLimitNote; its Change Limit… edits the Settings row
#     itself in a popover (never switching the Settings pane, where Design a Voice's sheet and draft live); the upscale job that
#     loses the race to the limit says SkyCutDailyLimit.userLine in its row, and the two sheets' models leave that to the note
#     (no second, stale line in `problem`);
#   - the settings path's labels are the window's own words: the window is titled "Settings" and the Sky Studio pane's row
#     says "Daily limit for AI";
#   - its twin, Sky Studio's balance refusal (insufficient_credits), is said by SkyStudioBalanceRefusal in every paid job: the AI's
#     fields (the account, not SkyCut's limit; the numbers; recharge_url; the job's own retry) and the task row's line in the app's
#     language; only SkyStudioBalanceRefusal names the code (SkyStudioJobAdmission's list of refusals aside).
# Long-term rule: docs/architecture/sky-studio-jobs.md section 11.

LIMIT_WORDS="Sources/SrtFlow/SkyStudio/SkyCutDailyLimit.swift"
LIMIT_NOTE="Sources/SrtFlow/SkyStudio/DailyCreditLimitNote.swift"
LIMIT_GATE="Sources/SrtFlow/SkyStudio/SkyStudioJobGate.swift"
SETTINGS_WINDOW="Sources/SrtFlow/SettingsWindowView.swift"
LIMIT_PANELS="Sources/SrtFlow/Upscale/UpscalePanel.swift Sources/SrtFlow/VoiceLibrary/DesignVoiceSheet.swift Sources/SrtFlow/VoiceChange/VoiceChangePanel.swift"
LIMIT_MODELS="Sources/SrtFlow/VoiceLibrary/DesignVoiceModel.swift Sources/SrtFlow/VoiceChange/VoiceChangePanelModel.swift"
for file in "${LIMIT_WORDS}" "${LIMIT_NOTE}" "${LIMIT_GATE}" "${SETTINGS_WINDOW}" ${LIMIT_PANELS} ${LIMIT_MODELS} Sources/SrtFlow/Upscale/UpscaleJob.swift; do
  [ -f "${file}" ] || fail "can't find ${file}: renamed? update checks/sky-studio-wiring/daily-limit.sh (an empty scan is a false green)"
done

others="$(code_files_with '"code": "daily_budget_exceeded"' | grep -v "^${LIMIT_WORDS}\$" || true)"
[ -z "${others}" ] || fail "these files build their own daily-limit refusal: $(tr '\n' ' ' <<<"${others}")— use SkyStudioJobGate.budgetBlocked (SkyCutDailyLimit.aiResult)"
grep -qF 'SkyCutDailyLimit.aiResult(' "${LIMIT_GATE}" \
  || fail "${LIMIT_GATE}: budgetBlocked builds the daily-limit result with SkyCutDailyLimit.aiResult (which limit, the numbers, the options)"
grep -qF 'AISettingsApproval.limitRaise(to:' "${LIMIT_GATE}" \
  || fail "${LIMIT_GATE}: option (a) asks the suggested raise in advance (AISettingsApproval.limitRaise), so the user is asked once"
for panel in ${LIMIT_PANELS}; do
  grep -qF 'DailyCreditLimitNote(' "${panel}" \
    || fail "${panel}: over the daily limit, the panel shows DailyCreditLimitNote (which limit, the numbers, Change Limit…)"
done
# A voiceover's missing batches: the result and the row use the numbers the batches were refused on (SkyStudioVoiceBudgetProblem),
# not the store's when the result is built after the recovery file is saved.
grep -qF 'SkyStudioJobGate.budgetBlocked(budget.numbers' Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
  && grep -qF 'SkyCutDailyLimit.userLine(budget.numbers)' Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
  || fail "Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift: a voiceover's budget stop reports the numbers read at the refusal"
grep -qF 'SkyCutDailyLimit.userLine(' Sources/SrtFlow/Upscale/UpscaleJob.swift \
  || fail "Sources/SrtFlow/Upscale/UpscaleJob.swift: an upscale the daily limit stops at its start says SkyCutDailyLimit.userLine"
for model in ${LIMIT_MODELS}; do
  if grep -qE 'problem = SkyCutDailyLimit' "${model}" || ! grep -qF 'objectWillChange.send()' "${model}"; then
    fail "${model}: losing the race to the daily limit redraws the sheet (its note says it); no second, stale line in problem"
  fi
done
grep -qF 'Button("Change Limit…") { changing = true }' "${LIMIT_NOTE}" \
  && grep -qF '.popover(isPresented: $changing' "${LIMIT_NOTE}" \
  && grep -qF 'DailyCreditLimitEditor().appLanguage()' "${LIMIT_NOTE}" \
  && grep -qF 'SkyStudioCreditLimitRow()' "${LIMIT_NOTE}" \
  || fail "${LIMIT_NOTE}: Change Limit… edits the Settings row itself in a popover, in place (never switching the Settings pane)"
if grep -qE 'openSettings|SettingsLink|showSettingsWindow' "${LIMIT_NOTE}"; then
  fail "${LIMIT_NOTE}: switching the Settings window to Sky Studio would close Design a Voice's sheet and lose its draft"
fi
grep -qF 'static let settingsKeys = ["Settings", SettingsCategory.skyStudio.title, "Daily limit for AI"]' "${LIMIT_WORDS}" \
  || fail "${LIMIT_WORDS}: the settings path names the window, the pane and the row"
grep -qF '.navigationTitle("Settings")' "${SETTINGS_WINDOW}" || fail "${SETTINGS_WINDOW}: the window the settings path names is titled Settings"
grep -qF 'Text("Daily limit for AI")' "${SECTION}" || fail "${SECTION}: the row the settings path names says Daily limit for AI"

BALANCE="Sources/SrtFlow/SkyStudio/SkyStudioBalanceRefusal.swift"
[ -f "${BALANCE}" ] || fail "can't find ${BALANCE}: renamed? update checks/sky-studio-wiring/daily-limit.sh"
others="$(code_files_with '"insufficient_credits"' | grep -v -e "^${BALANCE}\$" -e '^Sources/SrtFlow/SkyStudio/SkyStudioJobFailure.swift$' || true)"
[ -z "${others}" ] || fail "these files handle insufficient_credits themselves: $(tr '\n' ' ' <<<"${others}")— use SkyStudioBalanceRefusal"
for job in Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
           Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceLibraryJob.swift \
           Sources/SrtFlow/SkyStudio/SkyStudioCharacterRun.swift Sources/SrtFlow/AIUpscaleTool.swift; do
  [ -f "${job}" ] || { fail "can't find ${job}: renamed? update checks/sky-studio-wiring/daily-limit.sh"; continue; }
  grep -qF 'SkyStudioBalanceRefusal.fields(' "${job}" \
    || fail "${job}: a balance refusal gives the AI SkyStudioBalanceRefusal.fields (the account, the numbers, recharge_url, the retry)"
done
for row in Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
           Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceLibraryJob.swift \
           Sources/SrtFlow/SkyStudio/SkyStudioCharacterRun.swift Sources/SrtFlow/Upscale/UpscaleJob.swift; do
  grep -qF 'SkyStudioBalanceRefusal.shown' "${row}" || fail "${row}: a balance refusal shows the user SkyStudioBalanceRefusal.shown in the task row"
done
