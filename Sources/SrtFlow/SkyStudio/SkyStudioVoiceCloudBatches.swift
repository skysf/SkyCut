import Foundation
import SrtFlowMCPKit

// MARK: - 可恢复旁白的云端批次
// 管什么：只为明确 missing 的批次报价 / 预留 / POST，已有原单只 GET；成品地址先持久化，再下载完整音频。
// 不管什么：分句、字幕、入轨；统一提交 / 轮询 / 取消仍全部经 SkyStudioJobRun。

@MainActor
final class SkyStudioVoiceCloudBatches {
    private let recovery: SkyStudioVoiceRecovery
    private let input: AIVoiceoverInput
    private let api: SkyStudioAPI
    private let key: String
    private let status: SkyStudioMediaStatus
    private let canSubmit: @MainActor () -> Bool
    /// 新任务在报价之前做好的参考录音（SkyStudioVoiceoverRun.prepareReference）；恢复的任务是 nil，传参考时再做。
    private let reference: VoiceReferenceSample.Sample?
    private var budget: SkyStudioVoiceBudget?
    private var positions: [Int: Int] = [:]
    private var quotes: [SkyStudioQuote] = []

    init(recovery: SkyStudioVoiceRecovery, input: AIVoiceoverInput, api: SkyStudioAPI, key: String, status: SkyStudioMediaStatus,
         reference: VoiceReferenceSample.Sample? = nil, canSubmit: @escaping @MainActor () -> Bool) {
        self.recovery = recovery; self.input = input; self.api = api; self.key = key; self.status = status
        self.reference = reference; self.canSubmit = canSubmit
    }

    func refundUnused() { budget?.refundUnused() }

    func prepareMissing() async throws {
        guard budget == nil else { return }
        let indices = recovery.value.missing
        guard !indices.isEmpty else { return }
        quotes = []
        for index in indices { quotes.append(try await api.quote(recovery.value.plan.batches[index].request, key: key)) }
        guard let reserved = SkyStudioVoiceBudget.reserve(quotes) else {
            throw SkyStudioVoiceBudgetProblem(credits: quotes.reduce(0) { $0 + $1.credits })
        }
        budget = reserved
        positions = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        status.credits = quotes.reduce(0) { $0 + $1.credits }
    }

    /// 参考录音只传一次（44.1 kHz 单声道、10 秒–3 分钟，VoiceReferenceSample）。新任务用报价之前做好的那一份；
    /// 恢复的任务这时才做，用了哪一段补进恢复记录的声音说明（已经有了就不重复），落地时随 voice.note 告诉 AI。
    private func uploadReferenceIfNeeded() async throws {
        guard let clone = input.clone, recovery.value.referenceURL == nil else { return }
        let sample: VoiceReferenceSample.Sample
        if let reference, FileManager.default.fileExists(atPath: reference.url.path) {
            sample = reference
        } else {
            let folder = recovery.file.deletingLastPathComponent()
            sample = try await VoiceReferenceSample.prepare(from: clone.url, start: clone.start, end: clone.end, folder: folder)
            let summary = sample.summary(name: clone.url.lastPathComponent)
            if recovery.value.input.note?.contains(summary) != true {
                recovery.value.input.note = [recovery.value.input.note, summary].compactMap { $0 }.joined(separator: " ")
            }
        }
        status.advance(to: .uploading(fraction: nil), typicalSeconds: nil)
        recovery.value.referenceURL = try await api.upload(fileURL: sample.url, contentType: VoiceReferenceSample.contentType,
                                                            purpose: VoiceReferenceSample.uploadPurpose, key: key)
        try await recovery.save()
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
        let ext = result.url.pathExtension.isEmpty ? (recovery.value.plan.clones ? "wav" : "mp3") : result.url.pathExtension
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
        try await uploadReferenceIfNeeded()
        var request = recovery.value.plan.batches[index].request
        request.maxCredits = quotes[position].credits
        if let reference = recovery.value.referenceURL { request.inputs["reference_audio_url"] = reference.absoluteString }
        // 已确认失败的旧原单另起新 key；从未提交的批次沿用最初记录的 key。
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
            let charged = done.billing?.netCharged ?? done.creditsCharged ?? quotes[position].credits
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
                    recovery.value.batches[index].uncertain = quotes[position].credits
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
