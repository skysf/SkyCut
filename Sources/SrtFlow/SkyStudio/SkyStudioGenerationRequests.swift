import Foundation
import SrtFlowMCPKit

// MARK: - 同一操作在 MCP 层只起一个本机任务
// 管什么：把调用方稳定的 idempotency_key 绑定完整参数 / 工程，在报价或上传 await 期间也占位。
// The key is part of what it is bound to (`identity`), as SkyCut reads it: trimmed, or the one SkyCut made when the caller gave none,
// so the key it returned names that same request on the next call (a key sent with spaces, then copied from the receipt without them,
// was once refused as other inputs, CXD3 on PR #554). That key's job holding a paid result that did not come down answers Download
// again (`heldAnswer(for:)`, by the job id in the key's own cached answer). A call without the key, or with another one, is a new
// request and a new paid job (user, 2026-11-25: an identical paid request sent again is a deliberate new version): nothing here maps
// a new request to an old job by its parameters.
// 不管什么：HTTP 重试、服务端的钱包幂等、磁盘恢复；没有任务号的未知提交保留 key，绝不自动重放。
@MainActor
enum SkyStudioGenerationRequests {
    struct Entry { let identity: JSONValue; var result: AIToolResult? }
    private static var entries: [String: Entry] = [:]

    /// What `key` is bound to: the arguments without `confirm_token`, with the key itself as SkyCut reads it (trimmed, or the one it
    /// made when the caller gave none), the project and the account.
    static func identity(arguments: JSONValue, key: String, project: String, generation: Int, account: String) -> JSONValue {
        var fields = arguments.objectValue ?? [:]
        fields["confirm_token"] = nil
        fields["idempotency_key"] = .string(key)
        return ["arguments": .object(fields), "project": .string(project), "generation": .number(Double(generation)), "account": .string(account)]
    }

    static func begin(_ key: String, identity: JSONValue, scope: String = "") throws -> AIToolResult? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.utf16.count <= 128 else { throw AIToolError("idempotency_key must contain 1–128 characters.") }
        let entryKey = scope + ":" + key
        if let entry = entries[entryKey] {
            guard entry.identity == identity else { throw AIToolError("This idempotency_key is already bound to different inputs/project. Query the original job; a new operation needs a new key and approved budget.") }
            guard let result = entry.result else { throw AIToolError("The original operation is preparing; reuse this idempotency_key later. No second job was started.") }
            return result
        }
        entries[entryKey] = Entry(identity: identity)
        return nil
    }

    /// A key's own cached answer (its job id) when that job holds a paid result that did not come down: Download again of that very
    /// result (only GETs; nothing quoted, uploaded or submitted), and the answer says so. nil when its job holds nothing.
    static func heldAnswer(for cached: AIToolResult) -> AIToolResult? {
        guard let id = cached.payload["job_id"]?.stringValue, SkyStudioHeldDownloads.retry(id) else { return nil }
        return SkyStudioHeldDownloads.answer(jobID: id)
    }

    static func complete(_ key: String, result: AIToolResult, scope: String = "") { entries[scope + ":" + key]?.result = result }

    /// 新提交只有真的起了本机任务才占住 key；确认问题/预算阻止仍由 defer 放弃占位，允许同 key 再过闸。
    static func completeStarted(_ key: String, result: AIToolResult, scope: String = "") {
        guard result.payload["status"]?.stringValue == "started",
              result.payload["job_id"]?.stringValue?.isEmpty == false else { return }
        complete(key, result: result, scope: scope)
    }

    static func abandonPreparation(_ key: String, scope: String = "") {
        let entryKey = scope + ":" + key
        if entries[entryKey]?.result == nil { entries[entryKey] = nil }
    }
}
