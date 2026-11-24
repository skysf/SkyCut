import Foundation
import SrtFlowMCPKit

// MARK: - When SkyCut's own daily credit limit stops a paid request: what the AI and the user are told (pure values)
//
// What it covers (MSG1, 2026-11-24): the daily limit's refusal in one shape. It names the limit as SkyCut's own setting, not the
// user's Sky Studio balance; gives the numbers (the limit, used today, left, this request's estimate, the local midnight it resets
// at); and lists what can be done: (a) raise it now with the exact set_settings call and a friendly suggested value, which SkyCut
// asks the user to approve in every permission mode (AISettingsApproval); (b) change it in Settings, at the path the app shows in its
// own language; (c) wait for the reset. The paid panels' line (DailyCreditLimitNote) uses the same numbers and path.
// Before, the AI only knew "the daily hard budget is exhausted" and told a user "only 12 credits left today, wait for the refresh",
// who could not tell SkyCut's setting from the Sky Studio balance and got no way forward
// (docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md).
// What it does not cover: whether a request fits (DailySpendPolicy / SkyStudioSpendStore.decide), reserving (SkyStudioJobGate),
// asking to raise the limit (AISettingsApproval). Nothing here raises the limit: the result only names the call.

enum SkyCutDailyLimit {
    /// The numbers of one refusal. `now` and `calendar` decide the reset (the ledger's day is the local calendar day).
    struct Numbers: Equatable {
        var limit: Double
        var spent: Double
        var needed: Double
        var now = Date()
        var calendar = Calendar.current

        /// Credits still allowed today (never below 0: a refund can leave the day above a lowered limit).
        var left: Double { max(0, limit - spent) }

        /// The next local midnight: the ledger starts a new day there (DailySpendLedger.dayKey).
        var resetsAt: Date {
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        }

        var minutesToReset: Int { max(1, Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up))) }
    }

    /// The labels on the way to the limit, as the Settings window shows them (keys of the string tables): the app menu's
    /// Settings (also the toolbar gear and Command-comma), the Sky Studio pane (SettingsCategory) and the row's label
    /// (SkyStudioSettingsSection). checks/sky-studio-wiring/daily-limit.sh keeps them equal to the window's own words.
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

    /// The reset as the AI reads it: local time with its offset ("2026-11-25T00:00:00+08:00").
    static func resetText(_ numbers: Numbers) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = numbers.calendar.timeZone
        return format.string(from: numbers.resetsAt)
    }

    /// The AI's result: status blocked + daily_budget_exceeded (the fields the old result had keep their names), which system
    /// stopped it, the numbers, the three options and a next step. `appPath` is the path in the app's language;
    /// `englishPath` goes in too when it differs, so the AI can read it. `outcome` and `retry` are the caller's own when it is
    /// not a fresh call that started nothing (a voiceover's missing batches: the finished ones are kept, resume to retry).
    static func aiResult(_ numbers: Numbers, appPath: String, englishPath: String, outcome: String = "Nothing was started or charged.",
                         retry: String = "repeat this call") -> [String: JSONValue] {
        let suggested = suggestedLimit(numbers)
        let used = SkyStudioCredits.text(numbers.spent), limit = SkyStudioCredits.text(numbers.limit)
        let needed = SkyStudioCredits.text(numbers.needed)
        let which = numbers.limit == 0
            ? "SkyCut's own daily credit limit for AI is set to 0, which pauses paid work (a SkyCut setting, not the user's Sky Studio balance); this request needs \(needed)."
            : "Stopped by SkyCut's own daily credit limit for AI (a SkyCut setting, not the user's Sky Studio balance): \(used) of \(limit) credits used today, \(SkyStudioCredits.text(numbers.left)) left, this request needs \(needed)."
        var options: [JSONValue] = []
        if let suggested {
            options.append(["id": "raise_limit", "tool": "set_settings", "arguments": ["daily_ai_credit_limit": .number(suggested)],
                            "approval": "SkyCut asks the user to approve it (needs_confirmation); nothing changes until they agree."])
        }
        options.append(["id": "change_in_settings", "path": .string(appPath)])
        options.append(["id": "wait_for_reset", "resets_at": .string(resetText(numbers))])
        var result: [String: JSONValue] = [
            "status": "blocked", "code": "daily_budget_exceeded", "blocked_by": "skycut_daily_credit_limit",
            "message": .string(which + " " + outcome),
            "credits_needed": .number(SkyStudioCredits.number(numbers.needed)),
            "spent_today_credits": .number(SkyStudioCredits.number(numbers.spent)),
            "daily_limit_credits": .number(numbers.limit),
            "left_today_credits": .number(SkyStudioCredits.number(numbers.left)),
            "resets_at": .string(resetText(numbers)), "resets_in_minutes": .number(Double(numbers.minutesToReset)),
            "settings_section": "sky_studio", "settings_field": "daily_ai_credit_limit", "settings_path": .string(appPath),
            "options": .array(options),
            "next_step": .string(nextStep(suggested: suggested, retry: retry))
        ]
        if let suggested { result["suggested_daily_limit_credits"] = .number(suggested) }
        if appPath != englishPath { result["settings_path_english"] = .string(englishPath) }
        return result
    }

    private static func nextStep(suggested: Double?, retry: String) -> String {
        let raise = suggested.map { "(a) raise it now to \(SkyStudioCredits.text($0)): only if the user wants that, call set_settings with "
            + "the raise_limit option's arguments; SkyCut then asks them to approve and changes nothing until they agree; then \(retry). " }
            ?? "(a) is not possible: even SkyCut's highest daily limit is too low for this request today. "
        return "Tell the user in their language that SkyCut's own daily credit limit stopped this, not their Sky Studio balance, "
            + "with the numbers and the reset time, and offer the options. " + raise
            + "(b) They change it themselves at settings_path (Settings also opens with Command-comma or the toolbar gear). "
            + "(c) Wait until resets_at, then \(retry). Never raise it without the user's yes, never split or shrink the request to fit it; "
            + "full access obeys the same limit."
    }

    /// The user's line for a request of `needed` credits that `store` refuses now (a panel's job that lost the race to the limit).
    @MainActor
    static func userLine(needed: Double, store: SkyStudioSpendStore, localized: (String) -> String) -> String {
        userLine(Numbers(limit: store.dailyLimit, spent: store.spentToday(), needed: needed), localized: localized)
    }

    /// The user's line when a panel's or a job's request is over the limit: which limit, the numbers, where to change it.
    static func userLine(_ numbers: Numbers, localized: (String) -> String) -> String {
        String(format: localized("SkyCut's own daily credit limit stops this, not your Sky Studio balance: %1$@ of %2$@ credits used today, and this needs %3$@. Raise it in %4$@, or wait until midnight, when it resets."),
               SkyStudioCredits.text(numbers.spent), SkyStudioCredits.text(numbers.limit), SkyStudioCredits.text(numbers.needed),
               settingsPath(localized))
    }
}
