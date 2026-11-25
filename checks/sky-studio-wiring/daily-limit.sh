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

# Second review round (2026-11-25), pinned where the behaviour lives in App-only code:
# - a refused free price check goes through the real entries with beforeSubmission (generate_media, manage_characters);
for entry in Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift Sources/SrtFlow/SkyStudio/SkyStudioCharacterManageTool.swift; do
  grep -qF 'SkyStudioCharacterError.tool(error, beforeSubmission: true)' "${entry}" \
    || fail "${entry}: a refused price check says nothing was submitted (SkyStudioCharacterError.tool(error, beforeSubmission: true))"
done
# - every paid job says whether Sky Studio had accepted it before a balance refusal (a polled 402 may come with a charge), from the
#   job's own state, never a constant; the voice change from its Sky Studio job id (Codex CXM3: pinned to false, nothing went red);
for job in Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
           Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceLibraryJob.swift \
           Sources/SrtFlow/SkyStudio/SkyStudioCharacterRun.swift Sources/SrtFlow/Upscale/UpscaleJob.swift; do
  grep -qF 'SkyStudioBalanceRefusal.refusal(of: error, accepted:' "${job}" \
    || fail "${job}: a balance refusal says whether Sky Studio had accepted the job (SkyStudioBalanceRefusal.refusal(of:accepted:))"
  if grep -qE 'SkyStudioBalanceRefusal\.refusal\(of: error, accepted: (true|false)\)' "${job}"; then
    fail "${job}: whether Sky Studio had accepted the job comes from the job's own state, never a constant"
  fi
done
CHANGE_JOB="Sources/SrtFlow/VoiceChange/VoiceChangeJob.swift"
CHANGE_BILLING="Sources/SrtFlow/VoiceChange/VoiceChangeBilling.swift"
grep -qF 'SkyStudioBalanceRefusal.refusal(of: error, accepted: serverID != nil)' "${CHANGE_JOB}" \
  || fail "${CHANGE_JOB}: a balance refusal counts as accepted once Sky Studio gave the change a job id (serverID != nil)"
# - get_job asks a failed voice change's original job (GET only), reads a refusal's bill and replies with the books after settling;
#   the books follow only a final charge, never a bare top-level credits_charged of 0 (VoiceChangeBilling; Codex CXM3, CXM4);
[ -f "${CHANGE_BILLING}" ] || fail "can't find ${CHANGE_BILLING}: renamed? update checks/sky-studio-wiring/daily-limit.sh"
grep -qF 'job.refresh = { [self] in await refreshBill() }' "${CHANGE_JOB}" \
  && grep -qF 'billPending || job.status == .failed || job.status == .cancelled' "${CHANGE_JOB}" \
  && grep -qF 'server = try await services.api.job(id, key: key)' "${CHANGE_JOB}" \
  && grep -qF 'SkyStudioJobError.request(failure).failure?.billing' "${CHANGE_JOB}" \
  && grep -qF 'AIJobs.shared.updateDetail(job, VoiceChangeBilling.refusalBill(billing))' "${CHANGE_JOB}" \
  || fail "${CHANGE_JOB}: get_job asks the original job a refusal named, reads the bill a refusal carries and replies with today's books"
grep -qF 'if let charged = VoiceChangeBilling.charge(of: done) {' "${CHANGE_JOB}" \
  && grep -qF 'let charge = VoiceChangeBilling.charge(of: server)' "${CHANGE_JOB}" \
  && grep -qF 'return status.billing == nil && charged == 0 ? nil : charged' "${CHANGE_BILLING}" \
  && grep -qF 'guard let charged = billing?.netCharged else { return }' "${CHANGE_BILLING}" \
  || fail "${CHANGE_JOB}: the books and the receipt follow only a final charge, never a bare top-level 0 (VoiceChangeBilling.charge)"
if grep -qE 'creditsCharged|server = try\? await services\.api\.job' "${CHANGE_JOB}" "${CHANGE_BILLING}"; then
  fail "${CHANGE_JOB}: a voice change never settles by a bare top-level credits_charged, and reads a refusal's bill (no try? on get_job's GET)"
fi
# - a refund and a settlement go back to the day key recorded at booking, a settlement in one ledger write; a reservation saved
#   without one uses only a day the ledger proves holds it, never a day worked out from its date (Codex CXM3);
HELD="Sources/SrtFlow/SkyStudio/SkyStudioHeldCredits.swift"
grep -qF 'store.refund(held.credits, dayKey: key)' "${HELD}" \
  && grep -qF 'store.settle(reserved: held.credits, charged: charged, dayKey: key, now: now)' "${HELD}" \
  && grep -qF 'held.dayKey ?? store.ledger.provenDayKey(holding: held.credits, bookedAt: held.day)' "${HELD}" \
  || fail "${HELD}: a refund and a settlement go to the booking's day key (a settlement in one write), a keyless one to a proven day"
if grep -qF 'DailySpendLedger.dayKey(for:' "${HELD}"; then
  fail "${HELD}: a refund or a settlement never works its day out from the reservation's date (the time zone may have changed)"
fi
# - a mid-voiceover MiniMax version keeps its own failure step across a restart, and the fee step knows full access;
grep -qF 'failureStep: "The MiniMax version was not built. Resume the narration from its recovery file' Sources/SrtFlow/SkyStudio/SkyStudioVoiceFallbackFee.swift \
  && grep -qF 'credits: credits, standing: ask == .standing))' Sources/SrtFlow/SkyStudio/SkyStudioVoiceFallbackFee.swift \
  || fail "Sources/SrtFlow/SkyStudio/SkyStudioVoiceFallbackFee.swift: the fee's failure resumes from the recovery file; full access is said"
