import Foundation
import SrtFlowMCPKit

// MARK: - 可恢复旁白的云端批次：一批怎么拿到音频
// 管什么：只为明确 missing 的批次 POST，已有原单只 GET；成品地址先持久化，再下载完整音频。
// 新的一段：整段报价和预留在回任务号之前就做完了（SkyStudioVoiceoverStart），每批照记录里定好的请求交（`params.plan` 是整段的选择）。
// 恢复时补没生成的批次（generate_missing）：照记录里的选择把这几批再报一次价（`params.plan`，SkyCut 声音方案 8.4：恢复不重新选模型）、
// 预留，只换这几批的 `max_credits`；服务器回的选择和记录的不一样就不交。
// **中途换备用**（8.4）：某一批做完说服务器在它里面换了备用（`fallback_used`），还没交的批改带 `voice_plan.fallback.selection`
// （已经做好的、已经交出去的不重做），记进恢复记录；恢复补批次也照这份（`pendingSelection`）。
// 不管什么：几批怎么同时交、按什么顺序领槽（SkyStudioVoiceBatchQueue）；分句、字幕、入轨；统一提交 / 轮询 / 取消仍全部经 SkyStudioJobRun。

@MainActor
final class SkyStudioVoiceCloudBatches {
    typealias Audio = (file: URL, result: SkyStudioJobResult)
    typealias Report = @MainActor @Sendable (SkyStudioVoiceBatchBoard.State) -> Void

    /// 一批这一次怎么拿到音频。
    enum Source: Equatable {
        /// 原音频已经下在恢复目录里。
        case ready
        /// 有原单：只 GET（做完了就下载），不领槽、不花钱。
        case fetch
        /// 没生成过（或明确没扣钱）：领槽、交。
        case submit
        /// 没生成过，这一次没让补（恢复默认只做本机的事）。
        case skip
        /// 交过、结果说不准、又没拿到任务号：不能再交，也查不了。
        case unknown
    }

    private let recovery: SkyStudioVoiceRecovery
    private let api: SkyStudioAPI
    private let readKey: @MainActor () async throws -> String
    /// Key 只在头一回要上网时读一次（恢复时音频都在本机就一次都不读）。
    private var key: Task<String, Error>?
    private let status: SkyStudioMediaStatus
    private let canSubmit: @MainActor () -> Bool
    private let sleep: (@Sendable (Double) async throws -> Void)?
    private var budget: SkyStudioVoiceBudget?
    /// 批次号 → 它在预算里是第几笔。
    private var positions: [Int: Int] = [:]
    private var credits: [Double] = []

    /// `budget`：新的一段在回任务号之前预留好的那一笔（每批一份，顺序同批次）；恢复时是 nil，补批次之前现报价现预留。
    /// `sleep`：等的时候怎么睡（自检换成短的；nil = SkyStudioJobRun 的默认）。
    init(recovery: SkyStudioVoiceRecovery, api: SkyStudioAPI, key: @escaping @MainActor () async throws -> String, status: SkyStudioMediaStatus,
         budget: SkyStudioVoiceBudget? = nil, sleep: (@Sendable (Double) async throws -> Void)? = nil,
         canSubmit: @escaping @MainActor () -> Bool) {
        self.recovery = recovery; self.api = api; readKey = key; self.status = status
        self.sleep = sleep
        self.canSubmit = canSubmit
        if let budget {
            self.budget = budget
            credits = recovery.value.plan.batchCredits
            positions = Dictionary(uniqueKeysWithValues: recovery.value.plan.batches.indices.map { ($0, $0) })
        }
    }

    private func resolvedKey() async throws -> String {
        if let key { return try await key.value }
        let read = readKey
        let task = Task { @MainActor in try await read() }
        key = task
        return try await task.value
    }

    func refundUnused() { budget?.refundUnused() }

    /// 第 `index` 批这一次怎么拿到音频（只看恢复记录和盘上的文件，不碰网络、不读 Key）。
    static func source(_ index: Int, in checkpoint: SkyStudioVoiceCheckpoint, generateMissing: Bool) -> Source {
        let batch = checkpoint.batches[index]
        if let raw = batch.rawFile, FileManager.default.fileExists(atPath: raw.path),
           let remote = batch.remote, SkyStudioJobResult(json: remote) != nil { return .ready }
        if batch.missing { return generateMissing ? .submit : .skip }
        if batch.remote == nil, batch.serverID == nil { return .unknown }
        return .fetch
    }

    /// 已经下好的那一批。
    func saved(_ index: Int) -> Audio? {
        let batch = recovery.value.batches[index]
        guard let raw = batch.rawFile, let remote = batch.remote, let result = SkyStudioJobResult(json: remote) else { return nil }
        return (raw, result)
    }

    static func unknownOutcome(_ index: Int) -> AIToolError {
        AIToolError("The outcome of batch \(index) is unknown and no server job id was received. Preserve its submission_key and contact Sky Studio; it will not be submitted again.")
    }

    /// 恢复时补没生成的那几批：照记录的选择（中途换过备用就是备用的那份）再报一次价、整体预留。新的一段已经预留过，什么都不做。
    func prepareMissing() async throws {
        guard budget == nil else { return }
        let indices = recovery.value.missing
        guard !indices.isEmpty else { return }
        let plan = recovery.value.plan
        let selection = recovery.value.pendingSelection
        let segment = try SkyStudioVoiceRequests.segmentQuote(
            kind: plan.kind, model: plan.model, voice: plan.voice, batches: indices.map { plan.batches[$0].speech.prompt },
            lines: recovery.value.input.lines.map(\.text), plan: selection)
        let quote = try await api.quote(segment, key: resolvedKey())
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
        for (offset, index) in indices.enumerated() {
            recovery.value.plan.batches[index].request.maxCredits = missingCredits[offset]
            recovery.value.plan.batches[index].request.params["plan"] = .object(selection)
        }
        status.credits = missingCredits.reduce(0, +)
    }

    /// 交第 `index` 批、等它做完（拿着调用方按顺序领好的槽），把原单和结果记进恢复记录。下载另在 `download`。
    func generate(_ index: Int, lease: SkyStudioJobSlots.Lease, report: @escaping Report) async throws {
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
            var runner = try await runner(index)
            runner.lease = lease
            guard canSubmit() else { throw AIToolError("The original project changed; no further voiceover batches were submitted.") }
            sent = true
            let done = try await runner.run(request) { update in
                if case .status(let server) = update { submitted.mark(server.jobID) }
                Task { @MainActor in report(Self.state(update)) }
            }
            // 下载、分句或字幕失败都不能撤销云端成功记录，也不能把它退回 missing。
            recovery.value.received(done, at: index)
            let charged = done.billing?.netCharged ?? done.creditsCharged ?? credits[position]
            budget?.settled(position, charged: charged)
            recovery.value.batches[index].charged = charged
            recovery.value.batches[index].uncertain = 0
            if done.voiceOutcome?.fallbackUsed == true { switchToFallback() }
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

    /// 有原单、还没拿到结果的那一批：只 GET 原单（不领槽、不花钱）。
    func recover(_ index: Int, report: @escaping Report) async throws {
        guard recovery.value.batches[index].remote == nil else { return }
        guard let id = recovery.value.batches[index].serverID else { throw Self.unknownOutcome(index) }
        do {
            let done = try await runner(index).resume(id) { update in Task { @MainActor in report(Self.state(update)) } }
            // 原单查回来：照新交的一样记进恢复记录（中途换了备用的也照样改后面还没交的批）。
            recovery.value.received(done, at: index)
            if done.voiceOutcome?.fallbackUsed == true { switchToFallback() }
            try await recovery.save()
        } catch {
            if let failure = (error as? SkyStudioJobError)?.failure, failure.creditsReturned {
                recovery.value.batches[index].retryable = true
                recovery.value.batches[index].uncertain = 0
            }
            throw error
        }
    }

    /// 做好的那一批下到恢复目录（下过就直接用）。
    func download(_ index: Int, report: @escaping Report) async throws -> Audio {
        guard let remote = recovery.value.batches[index].remote, let result = SkyStudioJobResult(json: remote) else {
            throw AIToolError("Sky Studio finished without a recoverable voice file; keep the original job id and do not generate it again.")
        }
        if let file = recovery.value.batches[index].rawFile, FileManager.default.fileExists(atPath: file.path) { return (file, result) }
        let ext = result.url.pathExtension.isEmpty ? (result.contentType == "audio/mpeg" ? "mp3" : "wav") : result.url.pathExtension
        let file = recovery.file.deletingLastPathComponent().appendingPathComponent("batch-\(index).\(ext)")
        report(.downloading(fraction: nil))
        do {
            try await api.download(result.url, to: file) { fraction in
                Task { @MainActor in report(.downloading(fraction: CloudJobPhase.quantized(fraction))) }
            }
            recovery.value.batches[index].rawFile = file
            try await recovery.save()
        } catch { throw SkyStudioVoiceProcessingError(stage: .download, underlying: error) }
        return (file, result)
    }

    /// 服务器在某一批里换了备用：还没交的批（包括明确没扣钱、要重交的）改带备用的那份 plan，后面整段都用它。
    private func switchToFallback() {
        guard let fallback = recovery.value.plan.voicePlan.fallback?.selection else { return }
        for index in recovery.value.missing { recovery.value.plan.batches[index].request.params["plan"] = .object(fallback) }
    }

    private static func state(_ update: SkyStudioJobRun.Update) -> SkyStudioVoiceBatchBoard.State {
        switch update {
        case .waitingForSlot: return .waiting
        case .status(let server):
            switch server.state {
            case .queued?: return .queued(position: server.queuePosition)
            case .running?: return .processing
            default: return .processing
            }
        }
    }

    private func runner(_ index: Int) async throws -> SkyStudioJobRun {
        var run = SkyStudioJobRun(api: api, key: try await resolvedKey())
        if let sleep { run.sleep = sleep }
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
