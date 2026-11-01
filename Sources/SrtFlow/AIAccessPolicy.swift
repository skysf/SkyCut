import Foundation
import SrtFlowMCPKit

// MARK: - AI 操作权限与低成本草稿（纯值）
// 管什么：稳定权限标识、各语言名称、按模型实际能力挑草稿规格；不管设置持久化、报价或发任务。
enum AIAccessMode: String, CaseIterable, Codable, Sendable, Hashable {
    case ask = "ask_for_approval"
    case full = "full_access"

    var title: String { self == .ask ? "Ask for approval" : "Full access" }
    var names: JSONValue {
        self == .ask
            ? ["en": "Ask for approval", "zh": "请求批准", "zh-Hans": "请求批准", "es": "Solicitar aprobación"]
            : ["en": "Full access", "zh": "全部权限", "zh-Hans": "全部权限", "es": "Acceso completo"]
    }
}
