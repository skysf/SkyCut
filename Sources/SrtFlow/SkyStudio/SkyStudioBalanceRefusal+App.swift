import Foundation
import SrtFlowMCPKit

// MARK: - The balance refusal with the account's answer and the app's language
//
// What it covers: what SkyStudioBalanceRefusal needs from the running app, so each paid job's failure path is one call: the
// account's recharge address as the fallback (the last /me answer) and whether Settings shows Add Credits, and L10n for the line.
// What it does not cover: the words and fields themselves (SkyStudioBalanceRefusal, checked by scripts/check-sky-studio.sh).

@MainActor
extension SkyStudioBalanceRefusal {
    private static var accountRecharge: URL? { SkyStudioAccount.shared.stored?.me.skycut.rechargeURL }

    /// The AI's fields, with the account's recharge address when the refusal carried none.
    static func fields(_ refusal: Refusal, retry: String) -> [String: JSONValue] {
        fields(refusal, recharge: accountRecharge, retry: retry)
    }

    /// The user's line in the app's language.
    static func shown(_ refusal: Refusal) -> String {
        userLine(refusal, addCredits: accountRecharge != nil, localized: L10n)
    }
}
