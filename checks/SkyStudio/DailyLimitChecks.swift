import Foundation
import SrtFlowMCPKit

// When SkyCut's own daily credit limit stops a paid request (MSG1, 2026-11-24; SkyCutDailyLimit, SkyStudioJobGate.budgetBlocked):
// the AI's result names the limit as SkyCut's setting, not the Sky Studio balance, with the numbers, the reset and three options:
// the exact set_settings call with a friendly suggested value (which SkyCut then asks the user to approve, in every mode), the
// settings path in the app's own words (read from the real string tables) and waiting; the panels' line says the same.
// docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

@MainActor
func runDailyLimitChecks() {
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    // 2026-11-24 16:49:00 in Shanghai: 431 minutes to midnight.
    let afternoon = Date(timeIntervalSince1970: 1_795_510_140)
    let numbers = SkyCutDailyLimit.Numbers(limit: 1_000, spent: 988, needed: 36, now: afternoon, calendar: shanghai)
    checkEqual(numbers.left, 12, "credits left today")
    checkEqual(SkyCutDailyLimit.resetText(numbers), "2026-11-25T00:00:00+08:00", "the limit resets at the next local midnight, with its offset")
    checkEqual(numbers.minutesToReset, 431, "minutes until the reset")

    // The suggested higher limit: enough for this request, rounded up to a friendly number, always above the current limit.
    func suggested(limit: Double, spent: Double, needed: Double) -> Double? {
        SkyCutDailyLimit.suggestedLimit(.init(limit: limit, spent: spent, needed: needed, now: afternoon, calendar: shanghai))
    }
    checkEqual(suggested(limit: 1_000, spent: 988, needed: 36), 1_500, "the reported case: 988 used + 36 needed suggests 1,500")
    checkEqual(suggested(limit: 0, spent: 0, needed: 36), 100, "a paused limit (0) suggests enough for the request")
    checkEqual(suggested(limit: 2_000, spent: 1_990, needed: 200), 2_500, "steps of 500 up to 10,000")
    checkEqual(suggested(limit: 10_000, spent: 9_950, needed: 300), 15_000, "steps of 5,000 above 10,000")
    checkEqual(suggested(limit: 1_000, spent: 1_000.0000002, needed: 499.9999999), 1_500, "float noise in the ledger does not jump a step")
    checkEqual(suggested(limit: 1_000, spent: 900, needed: 100), nil, "a request that fits needs no higher limit")
    checkEqual(suggested(limit: 1_000, spent: 999_990, needed: 36), nil, "nothing above SkyCut's highest limit is suggested")
    checkEqual(suggested(limit: 1_000_000, spent: 1_000_000, needed: 1), nil, "at the highest limit there is nothing to raise to")
    for case let value? in [suggested(limit: 1_000, spent: 988, needed: 36), suggested(limit: 0, spent: 0, needed: 0.3)] {
        checkEqual(SkyStudioSpendStore.clamped(value), value, "set_settings accepts the suggested value as written (\(value))")
    }

    // The AI's result.
    let appPath = "SkyCut → 设置 → Sky Studio → AI 每日上限"
    let englishPath = "SkyCut → Settings → Sky Studio → Daily limit for AI"
    let result = JSONValue.object(SkyCutDailyLimit.aiResult(numbers, appPath: appPath, englishPath: englishPath))
    checkEqual(result["status"], "blocked", "status stays blocked")
    checkEqual(result["code"], "daily_budget_exceeded", "the code stays daily_budget_exceeded")
    checkEqual(result["blocked_by"], "skycut_daily_credit_limit", "which system stopped it: SkyCut's own setting")
    let message = result["message"]?.stringValue ?? ""
    for phrase in ["SkyCut's own daily credit limit", "not the user's Sky Studio balance", "988 of 1000 credits used today", "12 left",
                   "needs 36", "Nothing was started or charged"] {
        check(message.contains(phrase), "the message says \"\(phrase)\": \(message)")
    }
    checkEqual(result["credits_needed"], 36, "this request's estimate")
    checkEqual(result["spent_today_credits"], 988, "used today")
    checkEqual(result["daily_limit_credits"], 1_000, "the limit")
    checkEqual(result["left_today_credits"], 12, "left today")
    checkEqual(result["resets_at"], "2026-11-25T00:00:00+08:00", "when it resets")
    checkEqual(result["resets_in_minutes"], 431, "how long until it resets")
    checkEqual(result["settings_section"], "sky_studio", "the settings section get_settings uses")
    checkEqual(result["settings_field"], "daily_ai_credit_limit", "the set_settings field")
    checkEqual(result["settings_path"], .string(appPath), "the path in the app's language")
    checkEqual(result["settings_path_english"], .string(englishPath), "and in English when the app is in another language")
    checkEqual(result["suggested_daily_limit_credits"], 1_500, "the suggested limit")
    let options = result["options"]?.arrayValue ?? []
    checkEqual(options.compactMap { $0["id"]?.stringValue }, ["raise_limit", "change_in_settings", "wait_for_reset"], "three options, in order")
    checkEqual(options.first?["tool"], "set_settings", "raising goes through set_settings")
    checkEqual(options.first?["arguments"], ["daily_ai_credit_limit": 1_500], "the exact set_settings arguments")
    check(options.first?["approval"]?.stringValue?.contains("asks the user to approve") == true, "the raise option says SkyCut asks the user")
    checkEqual(options.dropFirst().first?["path"], .string(appPath), "the settings option carries the path")
    checkEqual(options.last?["resets_at"], "2026-11-25T00:00:00+08:00", "the wait option carries the reset")
    let next = result["next_step"]?.stringValue ?? ""
    for phrase in ["SkyCut's own daily credit limit", "not their Sky Studio balance", "set_settings", "raise_limit", "settings_path",
                   "resets_at", "Never raise it without the user's yes", "never split or shrink", "full access obeys the same limit"] {
        check(next.contains(phrase), "next_step says \"\(phrase)\"")
    }
    check(result["confirm_token"] == nil, "a budget block never carries a confirm token")
    let english = JSONValue.object(SkyCutDailyLimit.aiResult(numbers, appPath: englishPath, englishPath: englishPath))
    check(english["settings_path_english"] == nil, "no second path when the app is in English")
    let paused = JSONValue.object(SkyCutDailyLimit.aiResult(.init(limit: 0, spent: 0, needed: 36, now: afternoon, calendar: shanghai),
                                                            appPath: englishPath, englishPath: englishPath))
    check(paused["message"]?.stringValue?.contains("set to 0, which pauses paid work") == true, "a limit of 0 is said as paused paid work")
    let tooBig = JSONValue.object(SkyCutDailyLimit.aiResult(.init(limit: 1_000, spent: 999_990, needed: 36, now: afternoon, calendar: shanghai),
                                                            appPath: englishPath, englishPath: englishPath))
    checkEqual(tooBig["options"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["change_in_settings", "wait_for_reset"],
               "no raise option when even the highest limit is too low")
    check(tooBig["next_step"]?.stringValue?.contains("(a) is not possible") == true, "and the next step says so")

    gateChecks()
    settingsPathChecks()
}

/// The production builder (SkyStudioJobGate.budgetBlocked) and the set_settings question the raise option leads to.
@MainActor
private func gateChecks() {
    let scratch = ScratchDefaults("daily-limit-check")
    defer { scratch.remove() }
    let spend = SkyStudioSpendStore(defaults: scratch.defaults)
    let access = AIAccessStore(defaults: scratch.defaults)
    spend.record(988)
    let blocked = SkyStudioJobGate.budgetBlocked(credits: 36, store: spend).payload
    checkEqual(blocked["code"], "daily_budget_exceeded", "budgetBlocked keeps the code")
    checkEqual(blocked["suggested_daily_limit_credits"], 1_500, "budgetBlocked suggests a raise from the store's numbers")
    checkEqual(blocked["left_today_credits"], 12, "budgetBlocked reports what is left")
    if case .needsConfirmation(let result)? = try? SkyStudioJobGate.decide(credits: 36, summary: "Talking head", identity: "daily-limit",
        args: AIToolArguments([:]), store: spend, access: access) {
        checkEqual(result.payload["blocked_by"], "skycut_daily_credit_limit", "decide over the limit returns the same result")
        check(result.payload["options"] != nil, "with its options")
    } else { check(false, "decide over the limit is blocked") }
    checkEqual(spend.spentToday(), 988, "a blocked request reserves nothing")

    // Option (a): set_settings with the suggested value asks first, in full access too, and its question names the limit plainly.
    access.setMode(.full)
    let raise = AIToolArguments(["daily_ai_credit_limit": 1_500])
    let asked = try? AISettingsApproval.check(raise, mode: nil, limit: 1_500, access: access, currentLimit: spend.dailyLimit)
    checkEqual(asked?.payload["status"], "needs_confirmation", "raising the limit to the suggested value asks the user, even in full access")
    let question = asked?.payload["question"]?.stringValue ?? ""
    for phrase in ["SkyCut's daily credit limit for AI", "not the Sky Studio balance", "1000 -> 1500 credits a day",
                   "SkyCut → Settings → Sky Studio → Daily limit for AI"] {
        check(question.contains(phrase), "the approval question says \"\(phrase)\": \(question)")
    }
    check(!question.contains("1000.0"), "credits are whole numbers in the question")
    checkEqual(spend.dailyLimit, 1_000, "asking changes nothing")
}

/// The path is the app's own words: every label is a key of every string table, read from the real tables.
private func settingsPathChecks() {
    let expected = ["en": "SkyCut → Settings → Sky Studio → Daily limit for AI",
                    "zh-Hans": "SkyCut → 设置 → Sky Studio → AI 每日上限",
                    "es": "SkyCut → Ajustes → Sky Studio → Límite diario para la IA"]
    let line = "SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, and this needs %3$@. Raise it in %4$@, or wait until midnight, when it resets."
    let numbers = SkyCutDailyLimit.Numbers(limit: 1_000, spent: 988, needed: 36)
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: "Sources/SrtFlow/Resources"))?.filter { $0.hasSuffix(".lproj") } ?? []
    check(folders.count >= 3, "the string tables are found (\(folders.count))")
    for folder in folders.sorted() {
        let code = String(folder.dropLast(".lproj".count))
        let url = URL(fileURLWithPath: "Sources/SrtFlow/Resources/\(folder)/Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            check(false, "\(folder): Localizable.strings reads as a strings table"); continue
        }
        for key in SkyCutDailyLimit.settingsKeys + [line] {
            check(table[key] != nil, "\(folder) translates \"\(key)\" (the settings path and the panels' line)")
        }
        let lookup: (String) -> String = { table[$0] ?? $0 }
        if let want = expected[code] { checkEqual(SkyCutDailyLimit.settingsPath(lookup), want, "the settings path in \(code)") }
        let shown = SkyCutDailyLimit.userLine(numbers, localized: lookup)
        check(!shown.contains("%") && ["988", "1000", "36", SkyCutDailyLimit.settingsPath(lookup)].allSatisfy(shown.contains),
              "the panels' line in \(code) fills every number and the path: \(shown)")
    }
}
