import Foundation
import SrtFlowMCPKit

// MARK: - When SkyCut's own daily credit limit stops a paid request: what the AI and the user are told (pure values)
//
// What it covers (MSG1, 2026-11-24): the daily limit's refusal in one shape. It names the limit as SkyCut's own setting, not the
// user's Sky Studio balance; gives the numbers (the limit, used today, left, this request's estimate, when the ledger's next day
// starts); and lists what can be done: (a) raise it now to a friendly suggested value, with SkyCut's question and a set_settings
// confirm_token for exactly that change asked in advance (the user's 「只问一次」, 2026-11-25: their yes to that value is the
// approval; any other value is asked by set_settings as before, in every permission mode); (b) change it in Settings, at the path the
// app shows in its own language; (c) wait for the reset, only when a whole day's limit covers the request. The paid panels' line
// (DailyCreditLimitNote) uses the same numbers and path.
// Before, the AI only knew "the daily hard budget is exhausted" and told a user "only 12 credits left today, wait for the refresh",
// who could not tell SkyCut's setting from the Sky Studio balance and got no way forward
// (docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md).
// What it does not cover: whether a request fits (DailySpendPolicy / SkyStudioSpendStore.decide), reserving (SkyStudioJobGate),
// issuing the token (AISettingsApproval.limitRaise). Nothing here raises the limit.

enum SkyCutDailyLimit {
    /// The numbers of one refusal, read at the moment it happened. `now` and `calendar` decide the reset.
    struct Numbers: Equatable {
        var limit: Double
        var spent: Double
        var needed: Double
        var now = Date()
        var calendar = Calendar.current

        /// Credits still allowed today (never below 0: a refund can leave the day above a lowered limit).
        var left: Double { max(0, limit - spent) }

        /// The first moment of the ledger's next day (DailySpendLedger.dayKey: the calendar day): the end of today's calendar day.
        /// Not today's start plus a day (America/Santiago 2026-09-06 starts at 01:00, the 7th at 00:00), and not "this time
        /// tomorrow" rounded down (America/Nuuk at 2026-03-27 23:30: tomorrow has no 23:30, so that gave the 29th, not the 28th).
        var resetsAt: Date {
            calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86_400)
        }

        var minutesToReset: Int { max(1, Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up))) }

        /// Waiting helps only when a whole day's limit covers the request (a limit of 0 or 20 never fits 36).
        var fitsAfterReset: Bool { needed <= limit + DailySpendPolicy.slack }

        /// The store's numbers now: read when the request is refused, not later.
        @MainActor
        static func reading(_ store: SkyStudioSpendStore, needed: Double, now: Date = Date()) -> Numbers {
            Numbers(limit: store.dailyLimit, spent: store.spentToday(now: now), needed: needed, now: now)
        }
    }

    /// SkyCut's question for option (a), asked in advance: a set_settings confirm_token bound to exactly this raise from this
    /// limit and permission mode (the identity AISettingsApproval.check computes).
    struct RaiseQuestion: Equatable {
        var question: String
        var token: String
        var validMinutes: Int
    }

    /// The labels on the way to the limit, as the Settings window shows them (keys of the string tables): the app menu's
    /// Settings (also the toolbar gear and Command-comma), the Sky Studio pane (SettingsCategory) and the row's label
    /// (SkyStudioCreditLimitRow). checks/sky-studio-wiring/daily-limit.sh keeps them equal to the window's own words.
    static let settingsKeys = ["Settings", SettingsCategory.skyStudio.title, "Daily limit for AI"]

    /// "SkyCut → Settings → Sky Studio → Daily limit for AI", each label in the language `localized` reads.
    static func settingsPath(_ localized: (String) -> String) -> String {
        (["SkyCut"] + settingsKeys.map(localized)).joined(separator: " → ")
    }

    /// A limit that lets this request through, rounded up to a friendly number (988 used + 36 needed → 1,500); nil when the
    /// request already fits or even the highest limit SkyCut allows (SkyStudioSpendStore.limitRange) is too low.
    /// Rounds with DailySpendPolicy's slack, so float noise in the ledger (1,500.0000002) does not jump a step.
    static func suggestedLimit(_ numbers: Numbers) -> Double? {
        let ceiling = SkyStudioSpendStore.limitRange.upperBound
        let required = numbers.spent + numbers.needed
        guard required.isFinite, required >= 0, required <= ceiling + DailySpendPolicy.slack else { return nil }
        let step: Double = required <= 1_000 ? 100 : required <= 10_000 ? 500 : required <= 100_000 ? 5_000 : 50_000
        let friendly = min(((required - DailySpendPolicy.slack) / step).rounded(.up) * step, ceiling)
        return friendly > numbers.limit ? friendly : nil
    }

    /// The question option (a) carries: the raise in whole credits, named as the setting it is.
    static func raiseQuestion(from limit: Double, to suggested: Double) -> String {
        "Raise SkyCut's own daily credit limit for AI (a SkyCut setting, not the Sky Studio balance) from "
            + "\(SkyStudioCredits.text(limit)) to \(SkyStudioCredits.text(suggested)) credits a day?"
    }

    /// The reset as the AI reads it: local time with its offset ("2026-11-25T00:00:00+08:00").
    static func resetText(_ numbers: Numbers) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = numbers.calendar.timeZone
        return format.string(from: numbers.resetsAt)
    }

    /// The reset as the user reads it: the time of day in their language ("12:00 AM", "00:00").
    static func resetTime(_ numbers: Numbers, locale: Locale) -> String {
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = numbers.calendar.timeZone
        format.dateStyle = .none
        format.timeStyle = .short
        return format.string(from: numbers.resetsAt)
    }

    /// The AI's result: status blocked + daily_budget_exceeded (the fields the old result had keep their names), which system
    /// stopped it, the numbers, the options and a next step. `appPath` is the path in the app's language; `englishPath` goes in
    /// too when it differs. `raise` is option (a)'s question and token (nil when there is no higher limit to suggest). `outcome`
    /// and `retry` are the caller's own when it is not a fresh call that started nothing (a voiceover's missing batches).
    static func aiResult(_ numbers: Numbers, appPath: String, englishPath: String, raise: RaiseQuestion?,
                         outcome: String = "Nothing was started or charged.", retry: String = "repeat this call") -> [String: JSONValue] {
        let suggested = suggestedLimit(numbers)
        let needed = SkyStudioCredits.text(numbers.needed)
        let which = numbers.limit == 0
            ? "SkyCut's own daily credit limit for AI is set to 0, which pauses paid work (a SkyCut setting, not the user's Sky Studio balance); this request needs \(needed)."
            : "Stopped by SkyCut's own daily credit limit for AI (a SkyCut setting, not the user's Sky Studio balance): \(SkyStudioCredits.text(numbers.spent)) of \(SkyStudioCredits.text(numbers.limit)) credits used today, \(SkyStudioCredits.text(numbers.left)) left, this request needs \(needed)."
        var options: [JSONValue] = []
        if let suggested {
            var option: [String: JSONValue] = ["id": "raise_limit", "tool": "set_settings", "arguments": ["daily_ai_credit_limit": .number(suggested)]]
            if let raise {
                option["question"] = .string(raise.question)
                option["confirm_token"] = .string(raise.token)
                option["valid_for_minutes"] = .number(Double(raise.validMinutes))
            }
            options.append(.object(option))
        }
        options.append(["id": "change_in_settings", "path": .string(appPath)])
        if numbers.fitsAfterReset { options.append(["id": "wait_for_reset", "resets_at": .string(resetText(numbers))]) }
        var result: [String: JSONValue] = [
            "status": "blocked", "code": "daily_budget_exceeded", "blocked_by": "skycut_daily_credit_limit",
            "message": .string(which + (numbers.fitsAfterReset ? "" : " Even a whole day's limit is below it.") + " " + outcome),
            "credits_needed": .number(SkyStudioCredits.number(numbers.needed)),
            "spent_today_credits": .number(SkyStudioCredits.number(numbers.spent)),
            "daily_limit_credits": .number(numbers.limit),
            "left_today_credits": .number(SkyStudioCredits.number(numbers.left)),
            "resets_at": .string(resetText(numbers)), "resets_in_minutes": .number(Double(numbers.minutesToReset)),
            "settings_section": "sky_studio", "settings_field": "daily_ai_credit_limit", "settings_path": .string(appPath),
            "options": .array(options),
            "next_step": .string(nextStep(suggested: suggested, asked: raise != nil, fits: numbers.fitsAfterReset, retry: retry))
        ]
        if let suggested { result["suggested_daily_limit_credits"] = .number(suggested) }
        if appPath != englishPath { result["settings_path_english"] = .string(englishPath) }
        return result
    }

    private static func nextStep(suggested: Double?, asked: Bool, fits: Bool, retry: String) -> String {
        var raise = "(a) is not possible: even SkyCut's highest daily limit is too low for this request today. "
        if let suggested {
            let value = SkyStudioCredits.text(suggested)
            raise = asked
                ? "(a) Raise it now to \(value): ask the raise_limit option's question in their language. Only if they agree to exactly that, "
                    + "call set_settings with its arguments plus its confirm_token (SkyCut does not ask again), then \(retry). For another "
                    + "value, call set_settings with that value: SkyCut asks first. "
                : "(a) Raise it now to \(value): only if the user wants that, call set_settings with the raise_limit option's arguments; "
                    + "SkyCut asks them first and changes nothing until they agree; then \(retry). "
        }
        let wait = fits ? "(c) Wait until resets_at, then \(retry). " : "Waiting does not help: a whole day's limit is below this request. "
        return "Tell the user in their language that SkyCut's own daily credit limit stopped this, not their Sky Studio balance, "
            + "with the numbers" + (fits ? " and the reset time" : "") + ", and offer the options. " + raise
            + "(b) They change it themselves at settings_path (Settings also opens with Command-comma or the toolbar gear). " + wait
            + "Never raise it without the user's yes, never split or shrink the request to fit it; full access obeys the same limit."
    }

    /// The user's line: which limit, the numbers, where to change it, and when it resets when waiting helps.
    static func userLine(_ numbers: Numbers, localized: (String) -> String, locale: Locale) -> String {
        let path = settingsPath(localized)
        guard numbers.fitsAfterReset else {
            return String(format: localized("SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, %3$@ left, and this needs %4$@, more than a whole day allows, so waiting does not help. Raise it in %5$@."),
                          SkyStudioCredits.text(numbers.spent), SkyStudioCredits.text(numbers.limit), SkyStudioCredits.text(numbers.left),
                          SkyStudioCredits.text(numbers.needed), path)
        }
        return String(format: localized("SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, %3$@ left, and this needs %4$@. Raise it in %5$@, or wait until %6$@, when it resets."),
                      SkyStudioCredits.text(numbers.spent), SkyStudioCredits.text(numbers.limit), SkyStudioCredits.text(numbers.left),
                      SkyStudioCredits.text(numbers.needed), path, resetTime(numbers, locale: locale))
    }

    /// The user's line in the app's language (a job's task row; panels pass their own environment's locale).
    @MainActor
    static func userLine(_ numbers: Numbers) -> String {
        userLine(numbers, localized: L10n, locale: AppLanguageStore.shared.language.locale ?? .current)
    }
}
