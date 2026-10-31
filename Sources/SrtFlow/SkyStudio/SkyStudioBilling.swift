import Foundation
import SrtFlowMCPKit

// MARK: - 服务端结算证据（纯值）
// 管什么：原样保留 billing；仅按服务端的最终净扣费改本机每日账，不从 failed / cancelled / 下载错误推断退款。
struct SkyStudioBilling: Equatable, Sendable {
    let json: JSONValue
    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        json = value
    }
    var status: String? { json["status"]?.stringValue }
    var needsReview: Bool { json["review_required"]?.boolValue == true || ["pending_review", "refund_pending"].contains(status ?? "") }
    var netCharged: Double? {
        guard !needsReview, ["charged", "refunded", "not_charged"].contains(status ?? "") else { return nil }
        if status == "not_charged" { return 0 }
        guard let amount = json["credits_charged"]?.doubleValue, amount.isFinite, amount >= 0 else { return nil }
        return amount
    }
    var returnedAll: Bool { netCharged == 0 }
    var message: String {
        switch status {
        case "charged": return "Sky Studio confirms a charge. Provider-successful generation is not refunded for download, save or import failures."
        case "refunded": return "Sky Studio reports a refund; billing.credits_charged is the remaining net charge (unused reservation returns may be partial)."
        case "not_charged": return "Sky Studio confirms no charge."
        case "reserved": return "Credits remain reserved; query the original job. Do not generate again automatically."
        default: return "Billing requires reconciliation/review. Keep the original job and idempotency key; do not regenerate or switch models automatically."
        }
    }
    static let policyMessage = "Provider-successful generation is not refundable for download, save or import failures. Recovery reuses the original result. Unknown outcomes keep credits reserved for review; refund only after confirmed provider failure/cancellation without known provider costs."
}
