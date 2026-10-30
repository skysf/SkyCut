import Foundation
import SrtFlowMCPKit

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

    init(message: String, fields: [String: JSONValue] = [:], jobID: String? = nil) {
        self.message = message
        code = fields["code"]?.stringValue
        providerCode = fields["provider_code"]?.stringValue
        reason = fields["reason"]?.stringValue
        refunded = fields["refunded"]?.boolValue
        charged = fields["charged"]?.boolValue
        self.jobID = fields["job_id"]?.stringValue ?? jobID
    }

    var creditsReturned: Bool { refunded == true || charged == false }
    var isRealPersonRefusal: Bool { providerCode == "REAL_PERSON_REFERENCE" || reason == "real_person_reference" }
    var mayReplace: Bool { isRealPersonRefusal && creditsReturned }
    var json: JSONValue {
        var value: [String: JSONValue] = ["message": .string(message)]
        if let code { value["code"] = .string(code) }
        if let providerCode { value["provider_code"] = .string(providerCode) }
        if let reason { value["reason"] = .string(reason) }
        if let refunded { value["refunded"] = .bool(refunded) }
        if let charged { value["charged"] = .bool(charged) }
        if let jobID { value["skystudio_job_id"] = .string(jobID) }
        return .object(value)
    }
}
