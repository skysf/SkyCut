import Foundation
import SrtFlowMCPKit

// MARK: - When the Sky Studio balance is too low: what the AI and the user are told (pure values)
//
// What it covers (MSG1, 2026-11-24): Sky Studio's `insufficient_credits` refusal, the twin of SkyCut's daily limit
// (SkyCutDailyLimit), said the same way in every paid job (generate_media, upscale_clip, add_voiceover, change_voice, voice design
// and MiniMax versions, manage_characters): which system (the user's Sky Studio account, not SkyCut's daily limit), the numbers
// Sky Studio sent (balance, needed), where only the user can add credits (Sky Studio's recharge address; SkyCut → Settings →
// Sky Studio → Add Credits opens it) and how to go on. A plain refusal (no job id, no billing: SkyStudioJobAdmission) was not
// charged and is retried the job's own way once the user has added credits. One that carries acceptance or billing evidence
// (a job id, `billing.status: pending_review`) may have been charged: the AI queries that original job and never submits it again
// (MSG1 review, 2026-11-25). Before, the AI got "insufficient credits" (or the raw text alone on upscale and change voice) and the
// task row showed Sky Studio's English whatever the app's language.
// What it does not cover: refunds (the jobs, by SkyStudioJobError.canRefund), the account's own balance row
// (SkyStudioSettingsSection). SkyStudioBalanceRefusal+App adds the account's address and L10n.

enum SkyStudioBalanceRefusal {
    static let code = "insufficient_credits"

    /// One balance refusal: Sky Studio's fields, and whether it was refused before Sky Studio accepted anything.
    struct Refusal: Equatable {
        var failure: SkyStudioJobFailure
        /// Nothing was accepted or billed (SkyStudioJobError.rejectedBeforeAdmissionCode): not charged, safe to retry later.
        var beforeAdmission: Bool
    }

    /// The refusal inside an error, when it is the balance. `accepted`: Sky Studio had already given this job an id (a balance
    /// error while polling an accepted job carries no billing, yet the job may have been charged: MSG1 review, 2026-11-25).
    static func refusal(of error: Error, accepted: Bool) -> Refusal? {
        guard let job = error as? SkyStudioJobError, let failure = job.failure, failure.code == code else { return nil }
        return Refusal(failure: failure, beforeAdmission: !accepted && job.rejectedBeforeAdmissionCode == code)
    }

    /// The labels on the way to Add Credits (keys of the string tables; SkyStudioSettingsSection shows the link when Sky Studio
    /// sent a recharge address). Without one the path stops at the pane.
    static func settingsPath(addCredits: Bool, _ localized: (String) -> String) -> String {
        (["SkyCut", localized("Settings"), SettingsCategory.skyStudio.title] + (addCredits ? [localized("Add Credits")] : []))
            .joined(separator: " → ")
    }

    /// The AI's fields: which system, the numbers, where to add credits, and how to go on (`retry`: the job's own way, used only
    /// for a refusal before admission). `recharge` is the account's own address (the last /me answer): the fallback when the
    /// refusal carried none, and Settings shows Add Credits only when there is one.
    static func fields(_ refusal: Refusal, recharge: URL?, retry: String) -> [String: JSONValue] {
        let failure = refusal.failure
        let url = failure.rechargeURL ?? recharge
        var value: [String: JSONValue] = ["blocked_by": "sky_studio_balance", "recharge_url": url.map { .string($0.absoluteString) } ?? .null]
        if let balance = failure.balance { value["balance_credits"] = .number(SkyStudioCredits.number(balance)) }
        if let needed = failure.needed { value["needed_credits"] = .number(SkyStudioCredits.number(needed)) }
        let numbers = [failure.balance.map { "balance \(SkyStudioCredits.text($0))" }, failure.needed.map { "this needs \(SkyStudioCredits.text($0))" }]
            .compactMap { $0 }.joined(separator: ", ")
        let whereTo = url == nil ? "in Sky Studio" : "at recharge_url" + (recharge == nil ? "" : " (or SkyCut → Settings → Sky Studio → Add Credits)")
        let low = "the user's Sky Studio credit balance is too low" + (numbers.isEmpty ? "" : " (\(numbers))")
            + ". This is their Sky Studio account, not SkyCut's daily limit"
        guard refusal.beforeAdmission else {
            value["next_step"] = .string("Sky Studio answered that \(low), but this job may have been accepted or billed (its job id or "
                + "billing came with the refusal). Query this original job with get_job and follow its billing before anything else; "
                + "never submit it again. Tell the user in their language that their balance is low; only they can add credits, \(whereTo).")
            return value
        }
        value["next_step"] = .string("Sky Studio refused it: \(low), and the refused request was not charged. Tell the user in their "
            + "language, with the numbers. Only they can add credits, \(whereTo). Then, once they say they have added credits: \(retry). "
            + "Do not retry or ask for approval before that.")
        return value
    }

    /// The user's line (a task row, a notice): which system, the numbers when Sky Studio sent them, where to add credits.
    static func userLine(_ refusal: Refusal, addCredits: Bool, localized: (String) -> String) -> String {
        let path = settingsPath(addCredits: addCredits, localized)
        guard let balance = refusal.failure.balance, let needed = refusal.failure.needed else {
            return String(format: localized("Not enough Sky Studio credits. This is your Sky Studio balance, not SkyCut's daily limit. Add credits in %@."), path)
        }
        return String(format: localized("Not enough Sky Studio credits: your balance is %1$@ and this needs %2$@. This is your Sky Studio balance, not SkyCut's daily limit. Add credits in %3$@."),
                      SkyStudioCredits.text(balance), SkyStudioCredits.text(needed), path)
    }
}
