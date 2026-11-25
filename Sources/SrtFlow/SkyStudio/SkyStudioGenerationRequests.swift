import Foundation
import SrtFlowMCPKit

// MARK: - 同一操作在 MCP 层只起一个本机任务
// 管什么：把调用方稳定的 idempotency_key 绑定完整参数 / 工程，在报价或上传 await 期间也占位。
// A re-ask of a request whose paid result waits for Download again (the same key, or the same request without a key) downloads
// that result again and never starts a paid job (`heldAnswer`; 2026-11-24). The key itself is not part of what it is bound to, so the
// key SkyCut returned works on the next call (`identity`).
// 不管什么：HTTP 重试、服务端的钱包幂等、磁盘恢复；没有任务号的未知提交保留 key，绝不自动重放。
@MainActor
enum SkyStudioGenerationRequests {
    struct Entry { let identity: JSONValue; var result: AIToolResult? }
    private static var entries: [String: Entry] = [:]

    /// What a key is bound to: the arguments without `confirm_token` and `idempotency_key`, the project and the account.
    static func identity(arguments: JSONValue, project: String, generation: Int, account: String) -> JSONValue {
        var fields = arguments.objectValue ?? [:]
        fields["confirm_token"] = nil
        fields["idempotency_key"] = nil
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

    /// A re-ask whose paid result waits for Download again: that result is downloaded again under its job id (nothing quoted,
    /// uploaded or submitted). With `key`, the request bound to it; without one, any request of this identity (a re-ask that dropped
    /// the key must not mint a new key and pay again). nil when nothing of it is held.
    static func heldAnswer(key: String?, identity: JSONValue, scope: String = "") -> AIToolResult? {
        let candidates = key.map { entries[scope + ":" + $0].map { [$0] } ?? [] }
            ?? entries.filter { $0.key.hasPrefix(scope + ":") }.map(\.value)
        for entry in candidates where entry.identity == identity {
            if let answer = entry.result.flatMap(heldAnswer(for:)) { return answer }
        }
        return nil
    }

    /// The answer a key already has (its job id) when that job holds a paid result: Download again starts, and the answer says so.
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
