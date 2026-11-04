import Foundation
import SrtFlowMCPKit

// 官方收费操作的持久回执适配：先保原身份，收到原单立即落盘；不把 pin 写盘，不参与工程撤销。
// 重启只恢复原单。每日预算是聚合账，跨进程无法证明旧结算是否已经落账，因此恢复不再扣/退本机账。
@MainActor
final class SkyStudioOfficialRecovery {
    let file: URL
    private(set) var value: SkyStudioOfficialReceipt
    private(set) var rejectionEvidenceSaved: Bool?
    private var saving: Task<Void, Error>?

    private init(file: URL, value: SkyStudioOfficialReceipt) { self.file = file; self.value = value }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow", isDirectory: true)
            .appendingPathComponent("OfficialGenerationReceipts", isDirectory: true)
    }

    static func create(_ value: SkyStudioOfficialReceipt) async throws -> SkyStudioOfficialRecovery {
        let file = SkyStudioOfficialReceiptStore.url(accountID: value.accountID, key: value.idempotencyKey, directory: directory)
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioOfficialReceiptStore.create(value, at: file) } }.get()
        return SkyStudioOfficialRecovery(file: file, value: value)
    }

    func received(_ status: SkyStudioJobStatus) async throws {
        try value.received(status)
        try await save()
    }

    func delivered(file: URL, original: URL?) async throws {
        let before = value
        value = try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                var updated = before
                try updated.delivered(file: file, original: original)
                return updated
            }
        }.get()
        try await save()
    }

    func observedSettlement() async throws {
        value.localSettlementObserved = true
        try await save()
    }

    func rejectedBeforeAdmission(_ code: String) async throws {
        try value.rejectedBeforeAdmission(code)
        do { try await save(); rejectionEvidenceSaved = true }
        catch { rejectionEvidenceSaved = false; throw error }
    }

    private func save() async throws {
        let snapshot = value, file = file, previous = saving
        let next = Task {
            _ = try? await previous?.value
            try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioOfficialReceiptStore.write(snapshot, at: file) } }.get()
        }
        saving = next
        try await next.value
    }

    static func resume(key: String, argumentsDigest: String, scope: SkyStudioOfficialPrepared.Scope,
                       apiKey: String, project: VideoEditProject) async throws -> AIToolResult? {
        let file = SkyStudioOfficialReceiptStore.url(accountID: scope.accountID, key: key, directory: directory)
        let read = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try SkyStudioOfficialReceiptStore.readIfPresent(at: file) }
        }
        guard let value = try read.get() else { return nil }
        guard value.accountID == scope.accountID, value.projectPath == scope.projectPath,
              value.idempotencyKey == key, value.argumentsDigest == argumentsDigest else {
            throw AIToolError("This idempotency_key already belongs to a different saved project or request. No quote, upload or paid submission was repeated.")
        }
        let recovery = SkyStudioOfficialRecovery(file: file, value: value)
        if let code = value.submissionRejection {
            return .ok(["status": "not_submitted", "recovery_state": "confirmed_not_submitted", "rejection_code": .string(code),
                        "idempotency_key": .string(key), "charged": false, "submitted_again": false, "local_budget_reconciliation": "pending", "recovery_evidence_saved": true,
                        "next_step": "The original operation was explicitly rejected before admission. This key remains retired; no quote, upload, reservation or POST was repeated. If a new operation is wanted, obtain a new quote and review under the current budget and permission mode."])
        }
        guard value.jobID != nil || value.savedFile != nil else {
            return .ok(["status": "unknown", "recovery_state": "cloud_outcome_unknown", "idempotency_key": .string(key),
                        "local_budget_reconciliation": "pending", "submitted_again": false,
                        "next_step": "An official submission receipt exists but its server job id is unknown. Preserve this key and ask Sky Studio to reconcile the original operation; never submit again to find it. No new quote, upload, reservation or POST was made."])
        }
        return SkyStudioOfficialRecoveryRun(recovery: recovery, key: apiKey, project: project).start()
    }
}

/// 已审查的唯一收费请求；引用已在显式准备阶段上传，运行器不能再次上传或重建它。
struct SkyStudioOfficialOperation {
    var request: SkyStudioJobRequest
    var key: String
    var scope: SkyStudioOfficialPrepared.Scope
    var recovery: SkyStudioOfficialRecovery
    var expiresAt: Date
    var sources: JSONValue
}
