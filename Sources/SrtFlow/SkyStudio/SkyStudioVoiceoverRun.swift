import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 云端配旁白 / 克隆：回任务号，完成后入轨一整步撤销
// 管什么：先报价与预留总额、上传一次参考音频、按批交活并查到结局、下载与按句落盘，最后统一交给 AIVoiceoverTool.apply。
// 不管什么：批次 / 字幕 / 几何的算法；阻塞音频读写、积分账与 HTTP 各经已有适配层。额度不够的普通配音退本机，克隆报错。

@MainActor
final class SkyStudioVoiceoverRun {
    private var input: AIVoiceoverInput
    private weak var project: VideoEditProject?
    let status: SkyStudioMediaStatus
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?
    private var budget: SkyStudioVoiceBudget?
    private var serverIDs: [String] = []
    private var requestKeys: [String] = []
    private var batchIndex = 0
    private var batchCount = 0
    private var made: [URL] = []
    private var keptBatch: URL?
    private var activeRaw: URL?

    init(input: AIVoiceoverInput, project: VideoEditProject) {
        self.input = input
        self.project = project
        status = SkyStudioMediaStatus(kindLabel: L10n("Voiceover"), modelTitle: "Sky Studio", credits: nil,
            uploads: input.clone != nil, owner: CloudTasksActivity.owner(of: project), mediaKind: .audio)
    }

    func start() -> AIToolResult {
        let job = AIJobs.shared.start(.voiceover, progress: { nil }, liveDetail: { [weak self] in self?.detail() ?? [:] }, cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        status.aiJobID = job.id
        status.onCancel = { [weak self] in self?.task?.cancel() }
        SkyStudioGenerationActivity.shared.add(status)
        task = Task { @MainActor in await self.execute() }
        return .ok([
            "status": .string("started"), "job_id": .string(job.id), "provider": .string("Sky Studio"),
            "next_step": .string("Wait with get_job until done, failed or cancelled. SkyCut checks the price and daily budget first; ordinary narration falls back to a local voice when unavailable. "
                + "Cloud voice cloning may queue for several minutes. On completion, all lines and subtitles are added together as one undo step. Do not call add_voiceover again while this job is running.")
        ])
    }

    private func execute() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow-cloud-voice-\(UUID().uuidString)")
        defer {
            budget?.refundUnused()
            try? FileManager.default.removeItem(at: folder)
            SkyStudioGenerationActivity.shared.remove(status)
        }
        status.advance(to: .preparing, typicalSeconds: nil)
        do {
            try Task.checkCancellation()
            let key: String
            switch await SkyStudioJobKey.key(.silent) {
            case .success(let found): key = found
            case .failure(let problem): return try await fallback(problem.message)
            }
            let api = SkyStudioAPI()
            let plan: SkyStudioVoicePlan
            let quotes: [SkyStudioQuote]
            let locale: Locale?
            do {
                let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: api)
                let kind = input.clone == nil ? "voice" : "voice_clone"
                guard let model = catalog.models(kind: kind).first else { throw AIToolError("Sky Studio offers no \(kind) model right now.") }
                plan = try SkyStudioVoicePlan.make(lines: input.lines.map(\.text), model: model, voice: input.choice.name, language: input.language)
                if plan.clones, plan.batches.contains(where: { $0.speech.parts.count > 1 }) {
                    locale = try await SkyStudioVoiceAudio.splitLocale(language: input.language)
                } else if plan.clones, input.subtitles {
                    locale = try? await SkyStudioVoiceAudio.splitLocale(language: input.language)
                } else { locale = nil }
                var offered: [SkyStudioQuote] = []
                for batch in plan.batches {
                    try Task.checkCancellation()
                    offered.append(try await api.quote(batch.request, key: key))
                }
                quotes = offered
            } catch is CancellationError { throw CancellationError() }
            catch { return try await fallback(message(error)) }
            try Task.checkCancellation()
            let total = quotes.reduce(0) { $0 + $1.credits }
            guard projectUnchanged else { throw AIToolError("The project was closed or changed before generation started; nothing was charged.") }
            guard let reserved = SkyStudioVoiceBudget.reserve(quotes) else {
                return try await fallback("The Sky Studio voice was not used: \(SkyStudioCredits.text(total)) credits would exceed the daily limit. The user can raise it in SkyCut Settings → Sky Studio.")
            }
            budget = reserved
            status.modelTitle = plan.model.title
            status.credits = total
            batchCount = plan.batches.count
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var reference: URL?
            if let clone = input.clone {
                let sample = try await VoiceReferenceSample.file(from: clone.url, start: clone.start, seconds: clone.seconds, folder: folder)
                status.advance(to: .uploading(fraction: nil), typicalSeconds: nil)
                reference = try await api.upload(fileURL: sample, contentType: "audio/wav", purpose: "audio", key: key) { [weak self] fraction in
                    Task { @MainActor in self?.status.advance(to: .uploading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: nil) }
                }
            }
            let render = SkyStudioVoiceRender(input: input, plan: plan, locale: locale)
            for index in plan.batches.indices {
                try Task.checkCancellation()
                guard projectUnchanged else { throw AIToolError("The project was closed or changed; no further voiceover batches were submitted.") }
                batchIndex = index
                status.reset(typicalSeconds: quotes[index].typicalSeconds)
                var request = plan.batches[index].request
                request.maxCredits = quotes[index].credits
                if let reference { request.inputs["reference_audio_url"] = reference.absoluteString }
                requestKeys.append(request.idempotencyKey)
                let submitted = SkyStudioSubmission()
                let done: SkyStudioJobStatus
                do {
                    done = try await SkyStudioJobRun(api: api, key: key).run(request) { [weak self] update in
                        if case .status(let server) = update { submitted.mark(server.jobID) }
                        Task { @MainActor in self?.update(update, typical: quotes[index].typicalSeconds) }
                    }
                } catch let error as SkyStudioJobError {
                    remember(submitted.jobID)
                    switch error {
                    case .failed(let failure) where failure.creditsReturned: budget?.refund(index)
                    case .stopped(.nothingCharged): budget?.refund(index)
                    case .request(.server(let failure)) where !submitted.value && Self.refusedBeforeCharging(failure.code): budget?.refund(index)
                    default: budget?.unknown(index)
                    }
                    throw error
                }
                remember(done.jobID)
                budget?.settled(index, charged: done.creditsCharged ?? quotes[index].credits)
                guard let result = done.result else { throw AIToolError("Sky Studio finished without a voice file.") }
                let ext = result.url.pathExtension.isEmpty ? (plan.clones ? "wav" : "mp3") : result.url.pathExtension
                let raw = folder.appendingPathComponent("batch-\(index).\(ext)")
                activeRaw = raw
                status.advance(to: .downloading(fraction: nil), typicalSeconds: quotes[index].typicalSeconds)
                try await api.download(result.url, to: raw) { [weak self] fraction in
                    Task { @MainActor in self?.status.advance(to: .downloading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: quotes[index].typicalSeconds) }
                }
                status.advance(to: .finishing, typicalSeconds: quotes[index].typicalSeconds)
                do { try await render.append(plan.batches[index], file: raw, result: result) }
                catch {
                    made = render.outputs.sorted { $0.key < $1.key }.map(\.value.url)
                    throw error
                }
                made = render.outputs.sorted { $0.key < $1.key }.map(\.value.url)
                activeRaw = nil
                try? FileManager.default.removeItem(at: raw)
            }
            let outputs = try render.complete()
            try Task.checkCancellation()
            if input.speed != 1 {
                input.choice.note = [input.choice.note, "The Sky Studio voice speaks at its own pace; speed was ignored (SkyCut's or a Mac voice can change it)."].compactMap { $0 }.joined(separator: " ")
            }
            try await land(outputs: outputs)
        } catch {
            preserveRaw()
            let cancelled = Self.isCancellation(error)
            finish(cancelled ? .cancelled : .failed, message(error), payload: .object(detail()))
        }
    }

    private func fallback(_ note: String) async throws {
        try Task.checkCancellation()
        guard input.clone == nil else { throw AIToolError(note) }
        input = try input.localFallback(note)
        guard let project else { throw AIToolError("The project was closed before the voiceover started.") }
        let plan = try await AIVoiceoverTool.plan(input, project)
        made = plan.spoken.map(\.output.url)
        try Task.checkCancellation()
        land(plan: plan, project: project)
    }

    private func land(outputs: [AISpeechSynthesis.Output]) async throws {
        guard let project else {
            return finish(.done, "The voice files were made, but the project was closed; no lines were added.", payload: .object(detail()))
        }
        guard project.isCurrentGeneration(input.generation) else {
            return finish(.done, "The voice files were made, but the project changed; no lines were added.", payload: .object(detail()))
        }
        let plan = try await AIVoiceoverTool.plan(input, project, outputs: outputs)
        try Task.checkCancellation()
        land(plan: plan, project: project)
    }

    private func land(plan: AIVoiceoverTool.Plan, project: VideoEditProject) {
        guard projectUnchanged else {
            return finish(.done, "The voice files were made, but the project was closed or changed; no lines were added.", payload: .object(detail()))
        }
        do {
            var result = try AIUndoGrouping.step(project.effectiveUndoManager) { try AIVoiceoverTool.apply(plan, project) }
            AISession.shared.round(for: project).noteChange()
            result = AIProjectTools.saveIfNeverSaved(project, after: result)
            var payload = result.payload.objectValue ?? [:]
            for (key, value) in detail() { payload[key] = value }
            payload["project"] = .string(project.shortID)
            finish(.done, "The voiceover was added as one undo step.", payload: .object(payload))
        } catch { finish(.failed, message(error), payload: .object(detail())) }
    }

    private func detail() -> [String: JSONValue] {
        var value = status.progress?.json() ?? [:]
        value["skystudio_job_ids"] = .array(serverIDs.map(JSONValue.string))
        if let last = serverIDs.last { value["skystudio_job_id"] = .string(last) }
        value["batch_index"] = .number(Double(batchIndex + 1))
        value["batch_count"] = .number(Double(batchCount))
        value["credits_charged"] = .number(SkyStudioCredits.number(budget?.charged ?? 0))
        if let budget, budget.uncertain > 0 {
            value["credits_unknown"] = .number(SkyStudioCredits.number(budget.uncertain))
            value["submission_keys"] = .array(requestKeys.map(JSONValue.string))
            value["next_step"] = "Submission or cancellation outcome is uncertain. Keep polling known jobs; do not generate again. Contact Sky Studio with these submission keys if no server job id was returned."
        }
        value["files"] = .array(made.map { .string(AIWorkspace.shared.display($0)) })
        if let keptBatch { value["complete_batch_file"] = .string(AIWorkspace.shared.display(keptBatch)) }
        return value
    }

    private func update(_ update: SkyStudioJobRun.Update, typical: Double?) {
        switch update {
        case .waitingForSlot: status.advance(to: .queued(position: nil), typicalSeconds: typical)
        case .status(let server):
            remember(server.jobID)
            switch server.state {
            case .queued?: status.advance(to: .queued(position: server.queuePosition), typicalSeconds: typical)
            case .running?: status.advance(to: .processing, typicalSeconds: typical)
            default: break
            }
        }
    }

    private func remember(_ id: String?) {
        if let id, !serverIDs.contains(id) { serverIDs.append(id) }
    }

    private func preserveRaw() {
        guard let raw = activeRaw, FileManager.default.fileExists(atPath: raw.path) else { return }
        try? FileManager.default.createDirectory(at: input.folder, withIntermediateDirectories: true)
        let destination = ExportFileName.unoccupied(in: input.folder, stem: L10n("Complete voiceover"), pathExtension: raw.pathExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        do { try FileManager.default.moveItem(at: raw, to: destination); keptBatch = destination }
        catch { return }
    }

    private func finish(_ state: AIJobs.Status, _ message: String, payload: JSONValue) {
        guard let job else { return }
        if state == .failed || (budget?.uncertain ?? 0) > 0 { status.issue = message }
        AIReadGrants.shared.remember(made + (keptBatch.map { [$0] } ?? []))
        AIJobs.shared.finish(job, state, message: message, detail: payload)
    }

    private func message(_ error: Error) -> String {
        if let error = error as? AIToolError { return error.message }
        if let error = error as? SkyStudioJobError { return error.message }
        if let error = error as? SkyStudioFailure { return SkyStudioJobError.request(error).message }
        return error.localizedDescription
    }

    private var projectUnchanged: Bool {
        guard let project else { return false }
        return project.isCurrentGeneration(input.generation) && OpenProjects.shared.all.contains(where: { $0 === project })
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? SkyStudioJobError, case .stopped = failure { return true }
        return false
    }

    private static func refusedBeforeCharging(_ code: String) -> Bool {
        ["invalid_key", "upgrade_required", "insufficient_credits", "price_changed", "invalid_request", "rate_limited", "too_many_jobs"].contains(code)
    }
}
