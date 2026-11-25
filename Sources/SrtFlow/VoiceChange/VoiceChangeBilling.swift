import Foundation
import SrtFlowMCPKit

// MARK: - A voice change's books and what get_job says it charged
//
// What it does: the books follow Sky Studio's final bill only (docs/architecture/sky-studio-jobs.md: billing is the only
// settlement evidence). A bill that returned everything gives the reservation back, a net charge replaces it, and without a final
// bill the reservation stays, also when the top level says credits_charged 0. A refusal that carries a final bill counts the
// same (a 402 for the original job, billed 6.5). The AI reads credits_charged only from a final bill. Codex CXM3: a default
// change whose result lacked its background released all 9 before the job reported its failure; get_job reported a top-level 0
// as the charge; a try? on the original job's 402 dropped its bill and the books kept 9.
// Not: when to ask or reserve (VoiceChangeTool, VoiceChangePanelModel), the job's steps (VoiceChangeJob).
@MainActor
enum VoiceChangeBilling {
    static let noFinalBill = "Sky Studio sent no final bill with this answer, so SkyCut keeps the quoted credits reserved on its daily limit."

    /// Settles `held` by a final bill; without one it stays as it is.
    static func settle(_ held: inout SkyStudioHeldCredits, by billing: SkyStudioBilling?) {
        guard let charged = billing?.netCharged else { return }
        if charged == 0 { held.refund() } else { held.settle(charged: charged) }
    }

    /// The charge as the AI reads it: credits_charged from a final bill, otherwise a note that the reservation stays.
    static func detail(_ billing: SkyStudioBilling?) -> [String: JSONValue] {
        var value: [String: JSONValue] = [:]
        if let charged = billing?.netCharged { value["credits_charged"] = .number(SkyStudioCredits.number(charged)) }
        else { value["billing_note"] = .string(billing?.message ?? noFinalBill) }
        if let billing { value["billing"] = billing.json }
        return value
    }

    /// A job's answer: its id, the charge as above and what SkyCut's books hold today.
    static func charges(_ server: SkyStudioJobStatus) -> [String: JSONValue] {
        var value = detail(server.billing)
        value["skystudio_job_id"] = .string(server.jobID)
        value["spent_today_credits"] = spentToday
        return value
    }

    /// get_job after a refusal for the original job that carried its bill: the charge, Sky Studio's note, and the books read after
    /// settling. The job's detail still had the day's total from before, with the whole 9 reserved (Codex CXM4: it said 9 while the
    /// books held 6.5).
    static func refusalBill(_ billing: SkyStudioBilling) -> [String: JSONValue] {
        var value = detail(billing)
        value["billing_note"] = .string(billing.message)
        value["spent_today_credits"] = spentToday
        return value
    }

    /// What SkyCut's books hold today, read when the reply is built.
    private static var spentToday: JSONValue { .number(SkyStudioCredits.number(SkyStudioSpendStore.shared.spentToday())) }
}
