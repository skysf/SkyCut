import Foundation
import SrtFlowMCPKit

// When SkyCut's own daily credit limit stops a paid request (MSG1, 2026-11-24; SkyCutDailyLimit, SkyStudioJobGate.budgetBlocked):
// the AI's result names the limit as SkyCut's setting, not the Sky Studio balance, with the numbers and the reset (the ledger's
// own next day, also across a skipped midnight); option (a) carries SkyCut's question and a set_settings token for exactly the
// suggested raise (the user's 「只问一次」, 2026-11-25), (b) the settings path in the app's own words (read from the real string
// tables), (c) waiting only when a whole day's limit covers the request. The panels' line says the same.
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
    resetBoundaryChecks()

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
    let raise = SkyCutDailyLimit.RaiseQuestion(question: "Raise it?", token: "tok3n", validMinutes: 30)
    let result = JSONValue.object(SkyCutDailyLimit.aiResult(numbers, appPath: appPath, englishPath: englishPath, raise: raise))
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
    checkEqual(options.first?["question"], "Raise it?", "option (a) carries SkyCut's question")
    checkEqual(options.first?["confirm_token"], "tok3n", "and the set_settings token for exactly that raise")
    checkEqual(options.first?["valid_for_minutes"], 30, "and how long it is good for")
    checkEqual(options.dropFirst().first?["path"], .string(appPath), "the settings option carries the path")
    checkEqual(options.last?["resets_at"], "2026-11-25T00:00:00+08:00", "the wait option carries the reset")
    let next = result["next_step"]?.stringValue ?? ""
    for phrase in ["SkyCut's own daily credit limit", "not their Sky Studio balance", "ask the raise_limit option's question",
                   "Only if they agree to exactly that", "plus its confirm_token", "SkyCut does not ask again",
                   "For another value, call set_settings with that value: SkyCut asks first", "settings_path", "resets_at",
                   "Never raise it without the user's yes", "never split or shrink", "full access obeys the same limit"] {
        check(next.contains(phrase), "next_step says \"\(phrase)\"")
    }
    check(result["confirm_token"] == nil, "no token for the refused request itself")
    let english = JSONValue.object(SkyCutDailyLimit.aiResult(numbers, appPath: englishPath, englishPath: englishPath, raise: nil))
    check(english["settings_path_english"] == nil, "no second path when the app is in English")
    check(english["options"]?.arrayValue?.first?["confirm_token"] == nil, "no token when none was issued")
    check(english["next_step"]?.stringValue?.contains("SkyCut asks them first") == true, "and then set_settings asks as before")
    for (limit, why) in [(0.0, "a paused limit (0)"), (20.0, "a limit of 20")] {
        let short = JSONValue.object(SkyCutDailyLimit.aiResult(.init(limit: limit, spent: 0, needed: 36, now: afternoon, calendar: shanghai),
                                                               appPath: englishPath, englishPath: englishPath, raise: raise))
        checkEqual(short["options"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["raise_limit", "change_in_settings"],
                   "\(why) below a 36-credit request offers no waiting")
        check(short["next_step"]?.stringValue?.contains("Waiting does not help") == true && short["next_step"]?.stringValue?.contains("(c)") == false,
              "\(why): the next step says waiting does not help")
        check(short["message"]?.stringValue?.contains("Even a whole day's limit is below it.") == true, "\(why): the message says so too")
    }
    let paused = JSONValue.object(SkyCutDailyLimit.aiResult(.init(limit: 0, spent: 0, needed: 36, now: afternoon, calendar: shanghai),
                                                            appPath: englishPath, englishPath: englishPath, raise: nil))
    check(paused["message"]?.stringValue?.contains("set to 0, which pauses paid work") == true, "a limit of 0 is said as paused paid work")
    let tooBig = JSONValue.object(SkyCutDailyLimit.aiResult(.init(limit: 1_000, spent: 999_990, needed: 36, now: afternoon, calendar: shanghai),
                                                            appPath: englishPath, englishPath: englishPath, raise: nil))
    checkEqual(tooBig["options"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["change_in_settings", "wait_for_reset"],
               "no raise option when even the highest limit is too low")
    check(tooBig["next_step"]?.stringValue?.contains("(a) is not possible") == true, "and the next step says so")

    gateChecks()
    settingsPathChecks()
}

/// The reset is where the ledger's next day starts (DailySpendLedger.dayKey), also on a day that skips its midnight.
private func resetBoundaryChecks() {
    var santiago = Calendar(identifier: .gregorian)
    santiago.timeZone = TimeZone(identifier: "America/Santiago")!
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        santiago.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    // 2026-09-06 skips 00:00 (it starts at 01:00); 2026-09-07 starts at 00:00 again.
    let noonSixth = SkyCutDailyLimit.Numbers(limit: 100, spent: 90, needed: 36, now: at(6, 12), calendar: santiago)
    checkEqual(SkyCutDailyLimit.resetText(noonSixth), "2026-09-07T00:00:00-03:00", "after a skipped midnight the next day still starts at 00:00")
    var nuuk = Calendar(identifier: .gregorian)
    nuuk.timeZone = TimeZone(identifier: "America/Nuuk")!
    // 2026-03-28 skips 23:00–24:00 in Nuuk: "this time tomorrow" from 03-27 23:30 does not exist (the review's case gave the 29th).
    let lateNuuk = nuuk.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 23, minute: 30))!
    checkEqual(SkyCutDailyLimit.resetText(.init(limit: 100, spent: 90, needed: 36, now: lateNuuk, calendar: nuuk)), "2026-03-28T00:00:00-02:00",
               "the reset is the end of today's calendar day, also when tomorrow lacks this time of day")
    let cases = [(santiago, at(5, 23, 30)), (santiago, at(6, 1, 30)), (santiago, at(6, 12)), (santiago, at(6, 23, 59)), (santiago, at(7, 0, 1)),
                 (nuuk, lateNuuk), (nuuk, lateNuuk.addingTimeInterval(23 * 3_600))]
    for (calendar, now) in cases {
        let reset = SkyCutDailyLimit.Numbers(limit: 100, spent: 90, needed: 36, now: now, calendar: calendar).resetsAt
        let today = DailySpendLedger.dayKey(for: now, calendar: calendar)
        check(reset > now && DailySpendLedger.dayKey(for: reset, calendar: calendar) != today
              && DailySpendLedger.dayKey(for: reset.addingTimeInterval(-1), calendar: calendar) == today,
              "the reset is the first moment of the ledger's next day (\(calendar.timeZone.identifier), from \(today))")
    }
}

/// The production builder (SkyStudioJobGate.budgetBlocked) and the question its option (a) asks in advance.
@MainActor
private func gateChecks() {
    let scratch = ScratchDefaults("daily-limit-check")
    defer { scratch.remove() }
    let spend = SkyStudioSpendStore(defaults: scratch.defaults)
    let access = AIAccessStore(defaults: scratch.defaults)
    spend.record(988)
    let blocked = SkyStudioJobGate.budgetBlocked(credits: 36, store: spend, access: access).payload
    checkEqual(blocked["code"], "daily_budget_exceeded", "budgetBlocked keeps the code")
    checkEqual(blocked["suggested_daily_limit_credits"], 1_500, "budgetBlocked suggests a raise from the store's numbers")
    checkEqual(blocked["left_today_credits"], 12, "budgetBlocked reports what is left")
    let option = blocked["options"]?.arrayValue?.first
    let token = option?["confirm_token"]?.stringValue ?? ""
    check(!token.isEmpty, "option (a) carries a set_settings token")
    let question = option?["question"]?.stringValue ?? ""
    for phrase in ["SkyCut's own daily credit limit for AI", "not the Sky Studio balance", "from 1000 to 1500 credits a day"] {
        check(question.contains(phrase), "the question names the limit and the raise: \(question)")
    }
    check(blocked["confirm_token"] == nil, "no token for the refused request itself")
    if case .needsConfirmation(let result)? = try? SkyStudioJobGate.decide(credits: 36, summary: "Talking head", identity: "daily-limit",
        args: AIToolArguments([:]), store: spend, access: access) {
        checkEqual(result.payload["blocked_by"], "skycut_daily_credit_limit", "decide over the limit returns the same result")
        checkEqual(result.payload["options"]?.arrayValue?.first?["confirm_token"]?.stringValue, token, "asking again gives the same token")
    } else { check(false, "decide over the limit is blocked") }
    checkEqual(spend.spentToday(), 988, "a blocked request reserves nothing")

    // The user's yes to that exact raise is the approval: set_settings with the token goes through without a second question.
    let other = try? AISettingsApproval.check(AIToolArguments(["daily_ai_credit_limit": 2_000, "confirm_token": .string(token)]), mode: nil,
                                              limit: 2_000, access: access, currentLimit: spend.dailyLimit)
    check(other?.payload["confirm_token_refused"] != nil, "another value with that token is asked as before (the token is left untouched)")
    do {
        let approved = try AISettingsApproval.check(AIToolArguments(["daily_ai_credit_limit": 1_500, "confirm_token": .string(token)]), mode: nil,
                                                    limit: 1_500, access: access, currentLimit: spend.dailyLimit)
        check(approved == nil, "the exact raise with the refusal's token is approved without asking again")
    } catch { check(false, "the refusal's token: \(error)") }
    let reused = try? AISettingsApproval.check(AIToolArguments(["daily_ai_credit_limit": 1_500, "confirm_token": .string(token)]), mode: nil,
                                               limit: 1_500, access: access, currentLimit: spend.dailyLimit)
    checkEqual(reused?.payload["status"], "needs_confirmation", "the token is good for one call")

    // A late answer after the limit moved: the user set 2,000 themselves after a 1,000 → 1,500 offer. The token is void (it would
    // set the limit back to 1,500), and the change is asked again from 2,000 (MSG1 review, 2026-11-25).
    let offer = SkyStudioJobGate.budgetBlocked(credits: 36, store: spend, access: access).payload
    let offered = offer["options"]?.arrayValue?.first?["confirm_token"]?.stringValue ?? ""
    spend.setDailyLimit(2_000)
    let late = try? AISettingsApproval.check(AIToolArguments(["daily_ai_credit_limit": 1_500, "confirm_token": .string(offered)]), mode: nil,
                                             limit: 1_500, access: access, currentLimit: spend.dailyLimit)
    checkEqual(late?.payload["status"], "needs_confirmation", "a late yes to 1,500 after the user set 2,000 is asked again, not written")
    check(late?.payload["confirm_token_refused"] != nil && late?.payload["question"]?.stringValue?.contains("2000 -> 1500") == true,
          "the question says it would now lower the limit from 2,000")
    checkEqual(spend.dailyLimit, 2_000, "and the user's own 2,000 stays")
    spend.setDailyLimit(1_000)

    // Without it, the raise asks first, in full access too, and the question names the limit plainly.
    access.setMode(.full)
    let raise = AIToolArguments(["daily_ai_credit_limit": 1_500])
    let asked = try? AISettingsApproval.check(raise, mode: nil, limit: 1_500, access: access, currentLimit: spend.dailyLimit)
    checkEqual(asked?.payload["status"], "needs_confirmation", "raising the limit to the suggested value asks the user, even in full access")
    let settingsQuestion = asked?.payload["question"]?.stringValue ?? ""
    for phrase in ["SkyCut's daily credit limit for AI", "not the Sky Studio balance", "1000 -> 1500 credits a day",
                   "SkyCut → Settings → Sky Studio → Daily limit for AI"] {
        check(settingsQuestion.contains(phrase), "the approval question says \"\(phrase)\": \(settingsQuestion)")
    }
    check(!settingsQuestion.contains("1000.0"), "credits are whole numbers in the question")
    let fullBlocked = SkyStudioJobGate.budgetBlocked(credits: 36, store: spend, access: access).payload
    let fullToken = fullBlocked["options"]?.arrayValue?.first?["confirm_token"]?.stringValue ?? ""
    check(!fullToken.isEmpty && fullToken != token, "in full access the refusal's token is bound to that mode")
    do {
        let full = try AISettingsApproval.check(AIToolArguments(["daily_ai_credit_limit": 1_500, "confirm_token": .string(fullToken)]),
                                                mode: nil, limit: 1_500, access: access, currentLimit: spend.dailyLimit)
        check(full == nil, "and the user's yes to it raises the limit in full access too")
    } catch { check(false, "the full-access refusal's token: \(error)") }
    checkEqual(spend.dailyLimit, 1_000, "nothing here wrote the store (set_settings writes after the approval)")
}

/// The path is the app's own words: every label is a key of every string table, read from the real tables.
private func settingsPathChecks() {
    let expected = ["en": "SkyCut → Settings → Sky Studio → Daily limit for AI",
                    "zh-Hans": "SkyCut → 设置 → Sky Studio → AI 每日上限",
                    "es": "SkyCut → Ajustes → Sky Studio → Límite diario para la IA"]
    let fits = "SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, %3$@ left, and this needs %4$@. Raise it in %5$@, or wait until %6$@, when it resets."
    let never = "SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, %3$@ left, and this needs %4$@, more than a whole day allows, so waiting does not help. Raise it in %5$@."
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let afternoon = Date(timeIntervalSince1970: 1_795_510_140)
    let numbers = SkyCutDailyLimit.Numbers(limit: 1_000, spent: 988, needed: 36, now: afternoon, calendar: shanghai)
    let paused = SkyCutDailyLimit.Numbers(limit: 20, spent: 7, needed: 36, now: afternoon, calendar: shanghai)
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: "Sources/SrtFlow/Resources"))?.filter { $0.hasSuffix(".lproj") } ?? []
    check(folders.count >= 3, "the string tables are found (\(folders.count))")
    for folder in folders.sorted() {
        let code = String(folder.dropLast(".lproj".count))
        let url = URL(fileURLWithPath: "Sources/SrtFlow/Resources/\(folder)/Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            check(false, "\(folder): Localizable.strings reads as a strings table"); continue
        }
        for key in SkyCutDailyLimit.settingsKeys + [fits, never, "The same setting as in %@."] {
            check(table[key] != nil, "\(folder) translates \"\(key)\" (the settings path and the panels' lines)")
        }
        let lookup: (String) -> String = { table[$0] ?? $0 }
        if let want = expected[code] { checkEqual(SkyCutDailyLimit.settingsPath(lookup), want, "the settings path in \(code)") }
        let locale = Locale(identifier: code)
        let shown = SkyCutDailyLimit.userLine(numbers, localized: lookup, locale: locale)
        let time = SkyCutDailyLimit.resetTime(numbers, locale: locale)
        check(!shown.contains("%") && ["988", "1000", "12", "36", time, SkyCutDailyLimit.settingsPath(lookup)].allSatisfy(shown.contains),
              "the panels' line in \(code) fills used, the limit, left, needed, the path and the reset time (\(time)): \(shown)")
        let shownNever = SkyCutDailyLimit.userLine(paused, localized: lookup, locale: locale)
        check(!shownNever.contains("%") && ["7", "20", "13", "36"].allSatisfy(shownNever.contains) && !shownNever.contains(time),
              "a request a whole day cannot cover still gives used and left, and no reset time, in \(code): \(shownNever)")
    }
}
