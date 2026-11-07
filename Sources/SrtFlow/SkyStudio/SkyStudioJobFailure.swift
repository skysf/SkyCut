import Foundation
import SrtFlowMCPKit

// 服务端明确保证尚未入场的拒绝码；退款判定和官方提交回执共用，未知错误不加入。
enum SkyStudioJobAdmission {
    static let rejectedCodes: Set<String> = ["invalid_key", "upgrade_required", "invalid_request", "insufficient_credits",
                                             "price_changed", "too_many_jobs", "recipe_unavailable", "character_not_ready", "character_changed", "not_found"]

    /// 代码不能盖过受理/供应商/扣费证据；全退只证明净额归零，不证明从未受理。
    static func hasAdmissionEvidence(_ error: SkyStudioServerError) -> Bool {
        let fields: Set<String> = ["job_id", "skystudio_job_id", "billing", "charged", "refunded", "credits_reserved", "credits_charged", "credits_refunded",
            "provider_code", "provider_status", "provider_outcome", "result", "result_url", "generation_id", "generation_status", "delivery_status"]
        return !fields.isDisjoint(with: error.fields.keys)
    }

    /// 只有现行合同明确的容量拒绝形状才能重新 POST；未知附加字段不能冒充未准入。
    static func slotRefusal(_ error: SkyStudioServerError) -> Bool {
        guard error.status == 429, error.code == SkyStudioServerError.tooManyJobs,
              Set(error.fields.keys).isSubset(of: ["limit", "running"]) else { return false }
        return error.fields.values.allSatisfy { value in
            guard let n = value.doubleValue else { return false }
            return n.isFinite && n >= 0 && n.rounded() == n
        }
    }
}

// MARK: - 任务拒绝的机器可读原因与退款证据（纯值）
// 管什么：保留服务端错误码 / job_id / refunded / charged；退款未知不能写成已退、更不能重生成。
// 不管什么：从错误句子猜人脸、安全原因或账务状态；HTTP 请求和模型切换。
struct SkyStudioJobFailure: Equatable, Sendable {
    var message: String
    var code: String?
    var providerCode: String?
    var reason: String?
    var refunded: Bool?
    var charged: Bool?
    var jobID: String?
    var billing: SkyStudioBilling?
    var balance: Double?
    var needed: Double?
    var rechargeURL: URL?

    init(message: String, fields: [String: JSONValue] = [:], jobID: String? = nil) {
        self.message = message
        code = fields["code"]?.stringValue
        providerCode = fields["provider_code"]?.stringValue
        reason = fields["reason"]?.stringValue
        refunded = fields["refunded"]?.boolValue
        charged = fields["charged"]?.boolValue
        self.jobID = fields["job_id"]?.stringValue ?? jobID
        billing = SkyStudioBilling(fields["billing"])
        balance = fields["balance"]?.doubleValue
        needed = fields["needed"]?.doubleValue
        rechargeURL = SkyStudioLinks.webURL(fields["recharge_url"]?.stringValue)
    }

    var creditsReturned: Bool { billing?.returnedAll == true }
    var isRealPersonRefusal: Bool { providerCode == "REAL_PERSON_REFERENCE" || reason == "real_person_reference" }
    var json: JSONValue {
        var value: [String: JSONValue] = ["message": .string(message)]
        if let code { value["code"] = .string(code) }
        if let providerCode { value["provider_code"] = .string(providerCode) }
        if let reason { value["reason"] = .string(reason) }
        if let refunded { value["refunded"] = .bool(refunded) }
        if let charged { value["charged"] = .bool(charged) }
        if let jobID { value["skystudio_job_id"] = .string(jobID) }
        if let billing { value["billing"] = billing.json }
        if let balance { value["balance"] = .number(balance) }
        if let needed { value["needed"] = .number(needed) }
        if let rechargeURL { value["recharge_url"] = .string(rechargeURL.absoluteString) }
        return .object(value)
    }
}
