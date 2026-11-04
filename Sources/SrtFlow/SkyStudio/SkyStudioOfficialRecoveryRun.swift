import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 重启后的官方原单恢复：只 GET 已知任务/原成品，复用下载与可编辑副本逻辑，不报价、不上传、不调用 run/submit。
// 本机聚合预算不二次结算；服务器 billing 与保守留存的本机预留分别报告。
@MainActor
final class SkyStudioOfficialRecoveryRun {
    private let recovery: SkyStudioOfficialRecovery
    private let key: String
    private weak var project: VideoEditProject?
    private var task: Task<Void, Never>?
    private let status: SkyStudioMediaStatus

    init(recovery: SkyStudioOfficialRecovery, key: String, project: VideoEditProject) {
        self.recovery = recovery; self.key = key; self.project = project
        let value = recovery.value
        status = SkyStudioMediaStatus(kindLabel: L10n(value.kind == "image" ? "Image" : "Video"), modelTitle: value.modelTitle,
            credits: nil, uploads: false, title: value.stem, owner: CloudTasksActivity.owner(of: project), mediaKind: value.kind == "image" ? .image : .video)
    }

    func start() -> AIToolResult {
        let job = AIJobs.shared.start(.generate, progress: { nil }, liveDetail: { [status] in status.progress?.json() ?? [:] }, cancel: { [weak self] in self?.task?.cancel() })
        status.aiJobID = job.id
        SkyStudioGenerationActivity.shared.add(status)
        task = Task { @MainActor in await self.execute(job) }
        return .ok(["status": "recovering", "job_id": .string(job.id), "idempotency_key": .string(recovery.value.idempotencyKey),
                    "submitted_again": false, "next_step": "Wait with get_job. Recovery only reads the original server task and its saved output; no new generation or credit reservation."])
    }

    private func execute(_ job: AIJobs.Job) async {
        defer { SkyStudioGenerationActivity.shared.remove(status) }
        do {
            if let file = recovery.value.savedFile {
                let receipt = recovery.value
                let valid = await MediaReadQueue.run(on: MediaReadQueue.analysis) { receipt.validSavedFile(file) }
                guard valid else { throw AIToolError("The recorded output is missing or changed. Its original server result is retained below; SkyCut will not overwrite another file or submit again.") }
                finish(job, .done, file: file, message: "Recovered the existing original output; nothing was generated again.")
                return
            }
            guard let serverID = recovery.value.jobID else { throw AIToolError("The original server job id is unknown; no paid request can be repeated.") }
            status.advance(to: .processing, typicalSeconds: nil)
            var runner = SkyStudioJobRun(api: SkyStudioAPI(), key: key)
            runner.checkpoint = { [recovery] server in try await recovery.received(server) }
            let done = try await runner.resume(serverID)
            guard let result = done.result, let kind = SkyStudioGeneration.Kind(rawValue: recovery.value.kind) else {
                throw AIToolError("The original operation has no recoverable output yet.")
            }
            let value = recovery.value
            try FileManager.default.createDirectory(at: value.folder, withIntermediateDirectories: true)
            let pathExtension = SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: kind)
            let original = value.savedOriginal ?? value.savedFile
                ?? ExportFileName.unoccupied(in: value.folder, stem: value.stem, pathExtension: pathExtension) { FileManager.default.fileExists(atPath: $0.path) }
            if !FileManager.default.fileExists(atPath: original.path) {
                status.advance(to: .downloading(fraction: nil), typicalSeconds: nil)
                try await SkyStudioAPI().download(result.url, to: original) { [weak self] fraction in
                    Task { @MainActor in self?.status.advance(to: .downloading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: nil) }
                }
            }
            var file = original
            if await SkyStudioGeneratedVideo.needsCopy(original) {
                let ffmpeg = try await SkyStudioGeneratedVideo.engine()
                file = value.savedFile ?? ExportFileName.unoccupied(in: value.folder, stem: value.stem, pathExtension: "mp4") { FileManager.default.fileExists(atPath: $0.path) }
                try await SkyStudioGeneratedVideo.makeCopy(original, to: file, ffmpeg: ffmpeg)
            }
            try await recovery.delivered(file: file, original: original)
            finish(job, .done, file: file, message: "Recovered the original output without another generation.")
        } catch {
            let message = (error as? AIToolError)?.message ?? (error as? SkyStudioJobError)?.message
                ?? (error as? SkyStudioFailure).map { SkyStudioJobError.request($0).message } ?? error.localizedDescription
            finish(job, error is CancellationError ? .cancelled : .failed, message: message)
        }
    }

    private func finish(_ job: AIJobs.Job, _ result: AIJobs.Status, file: URL? = nil, message: String) {
        let value = recovery.value
        var detail: [String: JSONValue] = ["idempotency_key": .string(value.idempotencyKey), "submitted_again": false,
            "model_id": .string(value.modelID), "recovery_state": .string(file == nil ? "original_job_pending" : "recovered"),
            "local_budget_reconciliation": "pending",
            "local_budget_note": "The original local reservation is preserved. Recovery cannot atomically prove whether a prior process already settled the aggregate daily ledger, so it never reserves or refunds it again; billing below is server evidence.",
            "next_step": "Use this original output and inspect its actual used range. No new generation was submitted. Preserve the original operation key; unknown outcomes must not be retried as paid requests."]
        if let id = value.jobID { detail["skystudio_job_id"] = .string(id) }
        if let billing = value.billing { detail["billing"] = billing }
        if let remote = value.remoteResult { detail["remote_result"] = remote }
        if let file { detail["file"] = .string(file.path); AIReadGrants.shared.remember([file]) }
        if let original = value.savedOriginal { detail["original_file"] = .string(original.path); AIReadGrants.shared.remember([original]) }
        AIJobs.shared.finish(job, result, message: message, detail: .object(detail))
    }
}
