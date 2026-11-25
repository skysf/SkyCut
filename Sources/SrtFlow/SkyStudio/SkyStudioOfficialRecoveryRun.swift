import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 重启后的官方原单恢复：只 GET 已知任务/原成品，复用下载与可编辑副本逻辑，不报价、不上传、不调用 run/submit。
// 本机聚合预算不二次结算；服务器 billing 与保守留存的本机预留分别报告。
// A download that gave up or was stopped (SkyStudioDownloadFailure) keeps the original job's result held until it has come down: the
// row shows the localized line and Download again, which downloads that result once more (only GETs; the original job is read first
// for a fresh address, and when it cannot be read now, a 503 say, the held result is used: the way back is never lost to it). get_job
// carries the code and the next step; generate_media with this operation's own key reaches the same Download again.
@MainActor
final class SkyStudioOfficialRecoveryRun {
    private let recovery: SkyStudioOfficialRecovery
    private let key: String
    private weak var project: VideoEditProject?
    private var task: Task<Void, Never>?
    private let status: SkyStudioMediaStatus
    /// The original job's result whose download did not finish, and why: kept until it has come down.
    private var held: (result: SkyStudioJobResult, failure: SkyStudioDownloadFailure)?

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
        var downloading: SkyStudioJobResult?
        do {
            if let file = recovery.value.savedFile {
                let receipt = recovery.value
                let valid = await MediaReadQueue.run(on: MediaReadQueue.analysis) { receipt.validSavedFile(file) }
                guard valid else { throw AIToolError("The recorded output is missing or changed. Its original server result is retained below; SkyCut will not overwrite another file or submit again.") }
                finish(job, .done, file: file, message: "Recovered the existing original output; nothing was generated again.")
                return
            }
            guard let serverID = recovery.value.jobID else { throw AIToolError("The original server job id is unknown; no paid request can be repeated.") }
            let result: SkyStudioJobResult
            if let held {
                // Download again: the original job's current result (fresh addresses); the held one when the job cannot be read now.
                result = (try? await SkyStudioAPI().job(serverID, key: key).result) ?? held.result
            } else {
                status.advance(to: .processing, typicalSeconds: nil)
                var runner = SkyStudioJobRun(api: SkyStudioAPI(), key: key)
                runner.checkpoint = { [recovery] server in try await recovery.received(server) }
                guard let made = try await runner.resume(serverID).result else { throw AIToolError("The original operation has no recoverable output yet.") }
                result = made
            }
            guard let kind = SkyStudioGeneration.Kind(rawValue: recovery.value.kind) else {
                throw AIToolError("The original operation has no recoverable output yet.")
            }
            let value = recovery.value
            do { try FileManager.default.createDirectory(at: value.folder, withIntermediateDirectories: true) } catch {
                downloading = result   // its folder cannot be made (a file in the way): held for Download again, as a download would be
                throw SkyStudioDownloadFailure.notSaved(error)
            }
            let original: URL
            if let recorded = value.savedOriginal ?? value.savedFile, FileManager.default.fileExists(atPath: recorded.path) {
                original = recorded
            } else {
                status.advance(to: .downloading(fraction: nil), typicalSeconds: nil)
                downloading = result
                let key = key
                let renew: @Sendable () async throws -> URL? = { try await SkyStudioAPI().job(serverID, key: key).result?.url }
                let place = CloudResultPlace(folder: value.folder, stem: value.stem,
                                             pathExtension: SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: kind))
                // Gave up, stopped or never an image that decodes: SkyStudioDownloadFailure, and the paid output stays held for Download
                // again. It takes its name without replacing or removing anything (the next free number when the name is taken).
                original = try await SkyStudioAPI().download(result.url, into: place, renew: renew,
                                                             check: kind == .image ? SkyStudioImageResult.downloadCheck() : nil) { [weak self] fraction in
                    Task { @MainActor in self?.status.advance(to: .downloading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: nil) }
                }.url
            }
            // The output is on this Mac: nothing is held for it any more.
            held = nil
            status.releaseDownload()
            var file = original
            if await SkyStudioGeneratedVideo.needsCopy(original) {
                let ffmpeg = try await SkyStudioGeneratedVideo.engine()
                file = try await SkyStudioGeneratedVideo.makeCopy(original, in: value.folder, stem: value.stem, ffmpeg: ffmpeg)
            }
            try await recovery.delivered(file: file, original: original)
            finish(job, .done, file: file, message: "Recovered the original output without another generation.")
        } catch {
            let message = (error as? AIToolError)?.message ?? (error as? SkyStudioJobError)?.message
                ?? (error as? SkyStudioFailure).map { SkyStudioJobError.request($0).message } ?? error.localizedDescription
            let download = SkyStudioDownloadFailure.from(error)
            // Held again with the new reason; a Download again that failed before its download keeps the result held as it was.
            if let download, let downloading { held = (downloading, download) }
            finish(job, error is CancellationError || download?.kind == .stopped ? .cancelled : .failed, message: message)
        }
    }

    /// Download again: the held output once more under the same job id (only GETs), unless that download is already running.
    private func retryDownload(_ job: AIJobs.Job) {
        guard held != nil, job.status != .running else { return }
        status.beginDownloadAgain()
        AIJobs.shared.reopen(job)
        task = Task { @MainActor in await self.execute(job) }
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
        let failure = file == nil ? held?.failure : nil
        if let failure {
            detail.merge(failure.fields(retry: "call generate_media again with the same film arguments and idempotency_key "
                + "\"\(value.idempotencyKey)\" (that only reads the original job and downloads its output under this job id), or "
                + SkyStudioDownloadFailure.taskListRetry + " Another idempotency_key is a new generation and is charged again.")) { _, new in new }
        }
        AIJobs.shared.finish(job, result, message: message, detail: .object(detail))
        // Strong: the row's button and the operation's own key keep this recovery until its output has come down.
        if let failure { status.holdDownload(failure) { [self] in retryDownload(job) } }
    }
}
