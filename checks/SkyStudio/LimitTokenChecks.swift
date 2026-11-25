import Foundation
import SrtFlowMCPKit

// A set_settings token after the daily limit changed, and a token on a call with nothing to approve (Codex CXM3, 2026-11-26;
// AISettingsApproval): any change of the limit since the question voids the token, a change back to the same value too; a token is
// checked before anything in the call is written, and one that is not accepted authorizes nothing.
// docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

@MainActor
func runLimitTokenChecks() {
    let scratch = ScratchDefaults("limit-token-check")
    defer { scratch.remove() }
    let spend = SkyStudioSpendStore(defaults: scratch.defaults)
    let access = AIAccessStore(defaults: scratch.defaults)
    spend.record(988)
    func offer() -> String {
        SkyStudioJobGate.budgetBlocked(credits: 36, store: spend, access: access).payload["options"]?.arrayValue?.first?["confirm_token"]?.stringValue ?? ""
    }
    func raise(_ token: String, _ extra: [String: JSONValue] = [:]) throws -> AIToolResult? {
        var fields: [String: JSONValue] = ["daily_ai_credit_limit": 1_500, "confirm_token": .string(token)]
        fields.merge(extra) { _, new in new }
        return try AISettingsApproval.check(AIToolArguments(.object(fields)), mode: nil, limit: 1_500, access: access, spend: spend)
    }

    // Item 1: the user went to 2,000 and back to 1,000 after the 1,000 → 1,500 offer. The value matches again, but the token is void.
    let before = offer()
    check(!before.isEmpty, "the refusal offers the raise with a token")
    spend.setDailyLimit(1_000)
    check(spend.limitRevision == 0, "setting the same value is not a change of the limit")
    spend.setDailyLimit(2_000)
    spend.setDailyLimit(1_000)
    let back = try? raise(before)
    checkEqual(back?.payload["status"], "needs_confirmation", "a token from before the limit went to 2,000 and back to 1,000 is asked again")
    check(back?.payload["confirm_token_refused"] != nil && back?.payload["confirm_token"]?.stringValue != before,
          "with a new token, saying why the old one was refused: \(String(describing: back?.payload))")
    checkEqual(spend.dailyLimit, 1_000, "and nothing was written")

    // Item 2: a used token replayed with the same limit plus theme=classic authorizes nothing, so nothing in the call is written.
    let good = offer()
    do {
        check(try raise(good) == nil, "a fresh token for exactly the offered raise lets set_settings write")
    } catch { check(false, "the fresh token: \(error)") }
    spend.setDailyLimit(1_500)
    do {
        _ = try raise(good, ["theme": "classic"])
        check(false, "a used token replayed with the same limit and theme=classic must not let the call through")
    } catch let error as AIToolError {
        check(error.message.contains("it was already used") && error.message.contains("nothing was changed")
              && error.message.contains("repeat it without confirm_token"), "the replay is refused and says how to go on: \(error.message)")
    } catch { check(false, "the replay: \(error)") }
    do {
        _ = try AISettingsApproval.check(AIToolArguments(["theme": "classic", "confirm_token": "zzzzzz"]), mode: nil, limit: nil,
                                         access: access, spend: spend)
        check(false, "a token SkyCut never issued must not let a call through")
    } catch { check(error is AIToolError, "a token SkyCut never issued authorizes nothing either") }
    do {
        check(try AISettingsApproval.check(AIToolArguments(["theme": "classic"]), mode: nil, limit: nil, access: access, spend: spend) == nil,
              "the same call without a token needs no approval and goes through")
    } catch { check(false, "the theme alone: \(error)") }
    let modeReplay = try? AISettingsApproval.check(AIToolArguments(["ai_access_mode": "full_access", "confirm_token": .string(good)]),
                                                   mode: .full, limit: nil, access: access, spend: spend)
    check(modeReplay?.payload["status"] == "needs_confirmation" && modeReplay?.payload["confirm_token_refused"] != nil,
          "a used token with a mode change asks that change, with the refusal")
    checkEqual(access.mode, .ask, "and the mode is unchanged")
}
