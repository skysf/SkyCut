import Foundation
import SrtFlowMCPKit

// MARK: - 同一操作在 MCP 层只起一个本机任务
// 管什么：把调用方稳定的 idempotency_key 绑定完整参数 / 工程，在报价或上传 await 期间也占位。
// 不管什么：HTTP 重试、服务端的钱包幂等、磁盘恢复；没有任务号的未知提交保留 key，绝不自动重放。
@MainActor
enum SkyStudioGenerationRequests {
    struct Entry { let identity: JSONValue; var result: AIToolResult? }
    private static var entries: [String: Entry] = [:]

    static func begin(_ key: String, identity: JSONValue) throws -> AIToolResult? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.utf16.count <= 128 else { throw AIToolError("idempotency_key must contain 1–128 characters.") }
        if let entry = entries[key] {
            guard entry.identity == identity else { throw AIToolError("This idempotency_key is already bound to different inputs/project. Query the original job; a new operation needs a new key and approved budget.") }
            guard let result = entry.result else { throw AIToolError("The original operation is preparing; reuse this idempotency_key later. No second job was started.") }
            return result
        }
        entries[key] = Entry(identity: identity)
        return nil
    }

    static func complete(_ key: String, result: AIToolResult) { entries[key]?.result = result }
    static func abandonPreparation(_ key: String) { if entries[key]?.result == nil { entries[key] = nil } }
}
