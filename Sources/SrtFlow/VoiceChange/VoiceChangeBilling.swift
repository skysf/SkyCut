import Foundation
import SrtFlowMCPKit

// MARK: - A voice change's books and what get_job says it charged
//
// What it does: the books follow Sky Studio's final charge (SkyStudioJobStatus.finalCharge, PR #554: the bill's net, or the top-level
// credits_charged when no bill came; a bill under review keeps the reservation until get_job reads a final one). One exception for
// a voice change: a bare top-level 0 with no bill at all is not a final charge (Codex CXM3: get_job reported it as the charge, and a
// default change whose result lacked its background had released all 9). A refusal for the original job that carries a final bill
// counts the same (a 402 billed 6.5; a try? once dropped it and the books kept 9), and its reply reads the books after settling
// (Codex CXM4).
// Not: when to ask or reserve (VoiceChangeTool, VoiceChangePanelModel), the job's steps and its receipt (VoiceChangeJob).
@MainActor
enum VoiceChangeBilling {
    /// The charge a voice change's books take from a job's answer: its final charge, but not a bare top-level 0 without a bill.
    static func charge(of status: SkyStudioJobStatus) -> Double? {
        guard let charged = status.finalCharge else { return nil }
        return status.billing == nil && charged == 0 ? nil : charged
    }

    /// Settles `held` by a final bill; without one it stays as it is.
    static func settle(_ held: inout SkyStudioHeldCredits, by billing: SkyStudioBilling?) {
        guard let charged = billing?.netCharged else { return }
        if charged == 0 { held.refund() } else { held.settle(charged: charged) }
    }

    /// get_job after a refusal for the original job that carried its bill: the charge (when the bill is final), Sky Studio's note, and
    /// the books read after settling. The job's detail still had the day's total from before, with the whole 9 reserved (Codex CXM4:
    /// it said 9 while the books held 6.5).
    static func refusalBill(_ billing: SkyStudioBilling) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["billing": billing.json, "billing_pending": .bool(billing.netCharged == nil),
                                          "billing_note": .string(billing.message)]
        if let charged = billing.netCharged { value["credits_charged"] = .number(SkyStudioCredits.number(charged)) }
        value["spent_today_credits"] = .number(SkyStudioCredits.number(SkyStudioSpendStore.shared.spentToday()))
        return value
    }
}
