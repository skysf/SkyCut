import Foundation
import SrtFlowMCPKit

// MARK: - What identical paid requests in a row say (pure)
//
// What it covers (SkyStudioRepeatGuard; user, 2026-11-25):
// - the AI's line from the 2nd identical request of a run on: `repeat_request` in the tool's result, with which one in a row, the
//   credits each, that the 5th asks the user first (or that the user already agreed to keep going) and a note to relay;
// - the question at the 5th: alone, or as one more sentence of the gate's draft question (one question, not two);
// - the confirm token's action: the exact request plus its run, so a yes answers that run only, and a token issued for the draft
//   question alone never answers the merged one.
// English: the AI relays it in the user's language. Panels say nothing here (they are never counted).
// What it does not cover: counting (SkyStudioRepeatGuard), asking and redeeming (SkyStudioJobGate).

enum SkyStudioRepeatWords {
    /// What a token's action gets when the question is (also) this one: the run it answers, so a token for the draft question alone,
    /// or for another run of the same request, never answers it.
    static func tokenSuffix(_ check: SkyStudioRepeatGuard.Check) -> String { ":repeat_run:" + String(check.run) }

    /// The action of the question alone (a tool that asks nothing else): the resolved request, its price and its run.
    static func action(_ check: SkyStudioRepeatGuard.Check) -> String {
        "skystudio-repeat:" + check.tool.rawValue + ":" + check.identity + ":credits:" + String(check.credits) + tokenSuffix(check)
    }

    /// The sentence the question carries (merged into the draft question when SkyCut asks that too).
    static func sentence(_ check: SkyStudioRepeatGuard.Check) -> String {
        "This is the \(ordinal(check.number)) identical request in a row (\(SkyStudioCredits.text(check.credits)) credits each); each "
            + "one is a new paid version, and a yes also covers the identical requests after it."
    }

    /// The question when only the repeat asks.
    static func question(summary: String, _ check: SkyStudioRepeatGuard.Check) -> String {
        "Sky Studio · \(summary) — \(SkyStudioCredits.text(check.credits)) credits. " + sentence(check) + " Keep making identical versions?"
    }

    /// What a result carries from the 2nd identical request of a run on; nil for the first.
    static func fields(_ check: SkyStudioRepeatGuard.Check) -> [String: JSONValue]? {
        guard check.isRepeat else { return nil }
        return ["repeat_request": .object([
            "identical_in_a_row": .number(Double(check.number)),
            "credits_each": .number(SkyStudioCredits.number(check.credits)),
            "asks_user_at": .number(Double(SkyStudioRepeatGuard.asksAt)),
            "user_agreed": .bool(check.approved),
            "note": .string(note(check))
        ])]
    }

    /// The note to relay: which one in a row and what each costs, then what happens next.
    static func note(_ check: SkyStudioRepeatGuard.Check) -> String {
        let lead = "This is the \(ordinal(check.number)) identical \(check.tool.rawValue) request in a row in this project, "
            + "\(SkyStudioCredits.text(check.credits)) credits each; each one is a new paid job."
        if check.approved {
            return lead + " The user agreed to keep making identical versions, so SkyCut does not ask again until a different request."
        }
        if check.asks { return lead + " SkyCut asks the user before starting it: nothing was started or charged." }
        return lead + " The \(ordinal(SkyStudioRepeatGuard.asksAt)) identical request in a row asks the user first."
    }

    /// The next step of the question (`draft`: the gate's own next step when it asks about the draft too).
    static func nextStep(draft: String?) -> String {
        let repeatPart = "Ask the user in their conversation language whether to keep making identical versions of this request (each "
            + "is a new paid job). Only if they agree, repeat this same call with this confirm_token; the identical requests after it "
            + "then start without asking. If they do not agree, stop sending this request: nothing was started or charged."
        guard let draft else { return repeatPart }
        return draft + " The same answer covers the identical-request question: " + repeatPart
    }

    /// The result of a call that went through (or of another question: the draft's at the 2nd–4th) with the repeat fields merged in;
    /// nothing for the first request of a run, or without a check. A check that asked and still went through was answered yes.
    static func adding(_ check: SkyStudioRepeatGuard.Check?, to result: AIToolResult) -> AIToolResult {
        merging(check.map { $0.asks ? $0.agreed : $0 }, into: result)
    }

    /// The question's result: the repeat fields, and the next step that asks the user (`draft`: SkyCut asks about the draft too).
    static func asking(_ result: AIToolResult, _ check: SkyStudioRepeatGuard.Check, draft: String?) -> AIToolResult {
        guard case .object(var value) = merging(check, into: result).payload else { return result }
        value["next_step"] = .string(nextStep(draft: draft))
        var copy = result
        copy.payload = .object(value)
        return copy
    }

    private static func merging(_ check: SkyStudioRepeatGuard.Check?, into result: AIToolResult) -> AIToolResult {
        guard let check, let fields = fields(check), case .object(var value) = result.payload else { return result }
        value.merge(fields) { _, new in new }
        var copy = result
        copy.payload = .object(value)
        return copy
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st.
    static func ordinal(_ number: Int) -> String {
        let suffixes = [1: "st", 2: "nd", 3: "rd"]
        let suffix = (11...13).contains(number % 100) ? "th" : suffixes[number % 10] ?? "th"
        return "\(number)\(suffix)"
    }
}
