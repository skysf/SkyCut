import Foundation
import SrtFlowMCPKit

// MCP 任务与持久角色回执的桥：同 key / 本机 job_id 重启后仍定位原单；只读 get_job 从不 POST。
@MainActor
enum SkyStudioCharacterJobs {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow", isDirectory: true)
            .appendingPathComponent("CharacterReceipts", isDirectory: true)
    }

    static func read(_ id: String) async throws -> SkyStudioCharacterReceipt? {
        let directory = directory
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioCharacterReceiptStore.read(id, directory: directory) } }.get()
    }

    static func persist(_ receipt: SkyStudioCharacterReceipt, creating: Bool = false) async throws {
        let directory = directory
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioCharacterReceiptStore.write(receipt, directory: directory, creating: creating) } }.get()
    }

    static func account() throws -> String {
        guard let id = SkyStudioAccount.shared.stored?.me.account.id, !id.isEmpty else { throw AIToolError("A verified Sky Studio account is required. Refresh the account in SkyCut Settings before Character work.") }
        return id
    }

    static func restore(_ id: String, project: VideoEditProject?, explicitFreeImport: Bool = false) async throws -> AIJobs.Job? {
        guard id.hasPrefix("character-"), let receipt = try await read(id) else { return nil }
        guard receipt.accountID == (try account()) else { throw AIToolError("This Character job belongs to another Sky Studio account. No upload, reservation or submission was repeated.") }
        let key = try await SkyStudioOfficialGenerateTool.readKey()
        if let job = AIJobs.shared.job(id), job.status == .running { return job }
        return SkyStudioCharacterRun(receipt: receipt, key: key, project: project, retryFreeImport: explicitFreeImport).start()
    }

    static func response(_ job: AIJobs.Job, receipt: SkyStudioCharacterReceipt) -> AIToolResult {
        .ok(["status": "started", "job_id": .string(job.id), "idempotency_key": .string(receipt.idempotencyKey),
            "character_id": receipt.characterID.map(JSONValue.string) ?? .null,
            "credits": .number(receipt.reservedCredits), "cancellable": false,
            "model_id": (receipt.request.model.isEmpty ? .null : .string(receipt.request.model)), "params": .object(receipt.request.params),
            "notification": "Notify the user in the conversation language of this Character library operation, model/resolution and approved credits. Report actual billing at completion.",
            "next_step": "Wait with get_job using this stable job_id. Preserve idempotency_key across App restarts. Results expose a reusable character_id; no role images are inserted on the timeline. Native Character jobs cannot be cancelled; never repeat paid creation to recover a result."])
    }
}
