import Foundation
import SrtFlowMCPKit

// MARK: - 可恢复旁白的云端批次
// 管什么：只为明确 missing 的批次 POST，已有原单只 GET；成品地址先持久化，再下载完整音频。
// 新的一段：整段报价和预留在回任务号之前就做完了（SkyStudioVoiceoverStart），每批照记录里定好的请求交（`params.plan` 是整段的选择）。
// 恢复时补没生成的批次（generate_missing）：照记录里的选择把这几批再报一次价（`params.plan`，SkyCut 声音方案 8.4：恢复不重新选模型）、
// 预留，只换这几批的 `max_credits`；服务器回的选择和记录的不一样就不交。
// 不管什么：分句、字幕、入轨；统一提交 / 轮询 / 取消仍全部经 SkyStudioJobRun。

@MainActor
final class SkyStudioVoiceCloudBatches {
    private let recovery: SkyStudioVoiceRecovery
    private let api: SkyStudioAPI
    private let key: String
    private let status: SkyStudioMediaStatus
    private let canSubmit: @MainActor () -> Bool
    private var budget: SkyStudioVoiceBudget?
    /// 批次号 → 它在预算里是第几笔。
    private var positions: [Int: Int] = [:]
    private var credits: [Double] = []

    /// `budget`：新的一段在回任务号之前预留好的那一笔（每批一份，顺序同批次）；恢复时是 nil，补批次之前现报价现预留。
    init(recovery: SkyStudioVoiceRecovery, api: SkyStudioAPI, key: String, status: SkyStudioMediaStatus,
         budget: SkyStudioVoiceBudget? = nil, canSubmit: @escaping @MainActor () -> Bool) {
        self.recovery = recovery; self.api = api; self.key = key; self.status = status
        self.canSubmit = canSubmit
        if let budget {
            self.budget = budget
            credits = recovery.value.plan.batchCredits
            positions = Dictionary(uniqueKeysWithValues: recovery.value.plan.batches.indices.map { ($0, $0) })
        }
    }

    func refundUnused() { budget?.refundUnused() }

    /// 恢复时补没生成的那几批：照记录的选择再报一次价、整体预留。
    func prepareMissing() async throws {
        guard budget == nil else { return }
        let indices = recovery.value.missing
        guard !indices.isEmpty else { return }
        let plan = recovery.value.plan
        let selection = plan.voicePlan.selection
        let segment = try SkyStudioVoiceRequests.segmentQuote(
            kind: plan.kind, model: plan.model, voice: plan.voice, batches: indices.map { plan.batches[$0].speech.prompt },
            lines: recovery.value.input.lines.map(\.text), plan: plan.model == SkyStudioVoiceRequests.autoModel ? selection : nil)
        let quote = try await api.quote(segment, key: key)
        guard let voice = quote.voice, voice.batches.count == indices.count, voice.oneTime.isEmpty else {
            throw AIToolError("Sky Studio's new quote does not cover the missing batches; nothing was generated. Try again later.")
        }
        guard voice.plan?.selection == selection else {
            throw AIToolError("Sky Studio would read the missing batches with another model than the rest of this voiceover "
                + "(\(voice.plan?.model ?? "unknown")), so nothing was generated. Keep the recovery_file; the finished batches stay.")
        }
        let missingCredits = voice.batches.map(\.credits)
        guard let reserved = SkyStudioVoiceBudget.reserve(missingCredits) else {
            throw SkyStudioVoiceBudgetProblem(credits: missingCredits.reduce(0, +))
        }
        budget = reserved
        credits = missingCredits
        positions = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        for (offset, index) in indices.enumerated() { recovery.value.plan.batches[index].request.maxCredits = missingCredits[offset] }
        status.credits = missingCredits.reduce(0, +)
    }

    func audio(_ index: Int, generateMissing: Bool) async throws -> (URL, SkyStudioJobResult)? {
        if recovery.value.batches[index].missing {
            guard generateMissing else { return nil }
            try await prepareMissing()
            try await generate(index)
        } else if recovery.value.batches[index].remote == nil {
            guard let id = recovery.value.batches[index].serverID else {
                throw AIToolError("The outcome of batch \(index) is unknown and no server job id was received. Preserve its submission_key and contact Sky Studio; it will not be submitted again.")
            }
            do {
                let done = try await runner(index).resume(id)
                recovery.value.received(done, at: index)
                try await recovery.save()
            } catch {
                if let failure = (error as? SkyStudioJobError)?.failure, failure.creditsReturned {
                    recovery.value.batches[index].retryable = true
                    recovery.value.batches[index].uncertain = 0
                }
                throw error
            }
        }
        guard let remote = recovery.value.batches[index].remote, let result = SkyStudioJobResult(json: remote) else {
            throw AIToolError("Sky Studio finished without a recoverable voice file; keep the original job id and do not generate it again.")
        }
        if let file = recovery.value.batches[index].rawFile, FileManager.default.fileExists(atPath: file.path) { return (file, result) }
        let ext = result.url.pathExtension.isEmpty ? (result.contentType == "audio/mpeg" ? "mp3" : "wav") : result.url.pathExtension
        let file = recovery.file.deletingLastPathComponent().appendingPathComponent("batch-\(index).\(ext)")
        status.advance(to: .downloading(fraction: nil), typicalSeconds: nil)
        do {
            try await api.download(result.url, to: file) { [weak status] fraction in
                Task { @MainActor in status?.advance(to: .downloading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: nil) }
            }
            recovery.value.batches[index].rawFile = file
            try await recovery.save()
        } catch { throw SkyStudioVoiceProcessingError(stage: .download, underlying: error) }
        return (file, result)
    }

    private func generate(_ index: Int) async throws {
        guard let position = positions[index] else { throw AIToolError("No budget was reserved for this missing batch.") }
        var request = recovery.value.plan.batches[index].request
        // 已确认失败的旧原单另起新 key；从未提交的批次沿用报价时定下的 key。
        if recovery.value.batches[index].retryable { request.idempotencyKey = UUID().uuidString.lowercased() }
        recovery.value.plan.batches[index].request = request
        recovery.value.willSubmit(index)
        let submitted = SkyStudioSubmission()
        var sent = false
        do {
            try await recovery.save()
            try Task.checkCancellation()
            guard canSubmit() else { throw AIToolError("The original project changed; no further voiceover batches were submitted.") }
            sent = true
            let done = try await runner(index).run(request) { [weak self] update in
                if case .status(let server) = update { submitted.mark(server.jobID) }
                Task { @MainActor in self?.update(update, index: index, typical: nil) }
            }
            // 下载、分句或字幕失败都不能撤销云端成功记录，也不能把它退回 missing。
            recovery.value.received(done, at: index)
            let charged = done.billing?.netCharged ?? done.creditsCharged ?? credits[position]
            budget?.settled(position, charged: charged)
            recovery.value.batches[index].charged = charged
            recovery.value.batches[index].uncertain = 0
            try await recovery.save()
        } catch {
            recovery.value.batches[index].serverID = submitted.jobID ?? recovery.value.batches[index].serverID
            if !recovery.value.batches[index].generated {
                let refundable = (error as? SkyStudioJobError)?.canRefund(beforeAccepted: !submitted.value) == true
                if !sent || refundable {
                    budget?.refund(position)
                    recovery.value.batches[index].retryable = true
                } else {
                    budget?.unknown(position)
                    recovery.value.batches[index].uncertain = credits[position]
                }
            }
            throw error
        }
    }

    private func update(_ update: SkyStudioJobRun.Update, index: Int, typical: Double?) {
        switch update {
        case .waitingForSlot: status.advance(to: .queued(position: nil), typicalSeconds: typical)
        case .status(let server):
            switch server.state {
            case .queued?: status.advance(to: .queued(position: server.queuePosition), typicalSeconds: typical)
            case .running?: status.advance(to: .processing, typicalSeconds: typical)
            default: break
            }
        }
    }

    private func runner(_ index: Int) -> SkyStudioJobRun {
        var run = SkyStudioJobRun(api: api, key: key)
        let recovery = recovery
        run.checkpoint = { server in
            try await Self.remember(server.jobID, at: index, recovery: recovery)
        }
        return run
    }

    private static func remember(_ id: String, at index: Int, recovery: SkyStudioVoiceRecovery) async throws {
        recovery.value.batches[index].serverID = id
        try await recovery.save()
    }
}
