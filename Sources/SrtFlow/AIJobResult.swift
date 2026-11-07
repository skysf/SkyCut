import Foundation
import SrtFlowMCPKit

// get_job 最后的结果边界：结局优先于缓存 / 远端遗留的进行中字段；不改变账单、成品或任务状态。
enum AIJobResult {
    static func json(_ fields: [String: JSONValue], status: String) -> JSONValue {
        guard ["done", "failed", "cancelled"].contains(status) else { return .object(fields) }
        var result = fields
        for key in ["phase", "phase_seconds", "queue_position", "transfer_percent", "progress", "waiting_for_user"] { result[key] = nil }
        return .object(result)
    }
}
