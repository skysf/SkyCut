import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 云端配旁白 / 克隆：每批先保存，再本地处理，最后一次入轨
// 管什么：现有长任务接口、恢复调度、失败阶段与入轨回执；所有批次的原音频 / 映射 / 进度永久留在恢复目录。
// 不管什么：请求与预算（SkyStudioVoiceCloudBatches）、切句与字幕对齐（SkyStudioVoiceRender）、文件合同（SkyStudioVoiceCheckpoint）。

@MainActor
final class SkyStudioVoiceoverRun {
    private var input: AIVoiceoverInput
    private weak var project: VideoEditProject?
    let status: SkyStudioMediaStatus
    private let services: SkyStudioVoiceServices
    private let generateMissing: Bool
    private let recoveryFile: URL
    private var recovery: SkyStudioVoiceRecovery?
    private var cloud: SkyStudioVoiceCloudBatches?
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?
    private var locale: Locale?
    private var batchIndex = 0
    private var stage = SkyStudioVoiceCheckpoint.Stage.cloudGeneration
    private var extra: [String: JSONValue] = [:]

    init(input: AIVoiceoverInput, project: VideoEditProject, recovery: SkyStudioVoiceRecovery? = nil,
         generateMissing: Bool = true, services: SkyStudioVoiceServices? = nil) {
        self.input = input
        self.project = project
        self.recovery = recovery
        self.generateMissing = generateMissing
        self.services = services ?? SkyStudioVoiceServices()
        recoveryFile = (recovery?.file ?? input.folder.appendingPathComponent("Voiceover-\(UUID().uuidString).recovery").appendingPathComponent("voiceover-recovery.json"))
            .standardizedFileURL.resolvingSymlinksInPath()
        status = SkyStudioMediaStatus(kindLabel: L10n("Voiceover"), modelTitle: recovery?.value.plan.model.title ?? "Sky Studio", credits: nil,
            uploads: input.clone != nil, owner: CloudTasksActivity.owner(of: project), mediaKind: .audio)
    }

    func start() -> AIToolResult {
        if let id = SkyStudioVoiceRecovery.active[recoveryFile.path] { return .ok(["status": "started", "job_id": .string(id)]) }
        let job = AIJobs.shared.start(.voiceover, progress: { nil }, liveDetail: { [weak self] in self?.detail() ?? [:] }, cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        SkyStudioVoiceRecovery.active[recoveryFile.path] = job.id
        status.aiJobID = job.id
        status.onCancel = { [weak self] in self?.task?.cancel() }
        SkyStudioGenerationActivity.shared.add(status)
        task = Task { @MainActor in await self.execute() }
        return .ok([
            "status": "started", "job_id": .string(job.id), "provider": "Sky Studio", "recovery_file": .string(recoveryFile.path),
            "next_step": "Wait with get_job. Cloud cloning may queue for several minutes. On failure preserve recovery_file; call add_voiceover resume=recovery_file for local recovery, never repeat the original lines. Only generate_missing=true may pay for missing batches."
        ])
    }

    private func execute() async {
        defer {
            cloud?.refundUnused()
            SkyStudioVoiceRecovery.active[recoveryFile.path] = nil
            SkyStudioGenerationActivity.shared.remove(status)
        }
        status.advance(to: .preparing, typicalSeconds: nil)
        do {
            try Task.checkCancellation()
            if recovery == nil, !(try await prepareNew()) { return }
            guard let recovery else { throw AIToolError("The voiceover recovery record could not be created.") }
            if let applied = recovery.value.applied {
                recovery.value.issue = nil
                extra = applied.objectValue ?? [:]
                return finish(.done, "This voiceover was already inserted; no audio or subtitles were added again.")
            }
            try await process(recovery)
        } catch { await fail(error) }
    }

    private func process(_ recovery: SkyStudioVoiceRecovery) async throws {
        recovery.value.issue = nil
        // 成句文件被外部删除时只从保留的原始音频重建，不能重新生成。
        for (line, output) in recovery.value.outputs where !FileManager.default.fileExists(atPath: output.url.path) {
            recovery.value.outputs[line] = nil
        }
        let render = SkyStudioVoiceRender(input: input, recovery: recovery, locale: locale,
            transcribe: services.transcribe, localeProvider: services.locale)
        for index in recovery.value.plan.batches.indices {
            batchIndex = index
            try Task.checkCancellation()
            guard projectUnchanged else { throw SkyStudioVoiceProcessingError(stage: .insertion, underlying: AIToolError("The original project was closed or changed; recover into that project after reopening it.")) }
            let speech = recovery.value.plan.batches[index].speech
            if speech.parts.allSatisfy({ recovery.value.outputs[$0.line] != nil }) { continue }
            if recovery.value.batches[index].missing, !generateMissing { break }
            status.reset(typicalSeconds: nil)
            stage = .cloudGeneration
            let audio: (URL, SkyStudioJobResult)?
            if let raw = recovery.value.batches[index].rawFile, FileManager.default.fileExists(atPath: raw.path),
               let remote = recovery.value.batches[index].remote, let result = SkyStudioJobResult(json: remote) {
                audio = (raw, result)
            } else {
                audio = try await cloudBatches().audio(index, generateMissing: generateMissing)
            }
            guard let (file, result) = audio else { break }
            stage = .localSplit
            status.advance(to: .finishing, typicalSeconds: nil)
            try await render.append(index, file: file, result: result)
        }
        guard recovery.value.ready else {
            try await recovery.save()
            return finish(.failed, "Available audio was recovered. Some batches have not been generated; resume with generate_missing=true to generate only those batches.")
        }
        stage = .insertion
        try await land(outputs: render.complete())
    }

    private func fail(_ error: Error) async {
        let cancelled = Self.isCancellation(error)
        let failureStage = (error as? SkyStudioVoiceProcessingError)?.stage ?? stage
        extra["failure_stage"] = .string(failureStage.rawValue)
        if let recovery {
            recovery.value.issue = .init(stage: failureStage, batch: batchIndex, message: message(error))
            if failureStage == .subtitleAlignment {
                // 失败的词表不能变成永久缓存；已完成句子仍保持不动。
                for index in recovery.value.batches.indices where recovery.value.plan.batches[index].speech.parts.contains(where: { recovery.value.outputs[$0.line] == nil }) {
                    recovery.value.batches[index].analysis = nil
                }
            }
            do { try await recovery.save() }
            catch { extra["checkpoint_issue"] = .string(error.localizedDescription) }
        } else {
            extra["completed_line_indices"] = []
            extra["pending_recovery_line_indices"] = []
            extra["not_generated_line_indices"] = .array(input.lines.indices.map { .number(Double($0)) })
            extra["recovery_state"] = "not_started"
            extra["next_step"] = "No cloud generation was submitted. Resolve the reported setup problem, then retry the original add_voiceover call."
        }
        if let failure = (error as? SkyStudioJobError)?.failure {
            extra["failure"] = failure.json
            if failure.code == "insufficient_credits" {
                extra["recharge_url"] = (failure.rechargeURL ?? SkyStudioAccount.shared.stored?.me.skycut.rechargeURL).map { .string($0.absoluteString) } ?? .null
            }
        }
        if let blocked = error as? SkyStudioVoiceBudgetProblem {
            extra.merge(SkyStudioJobGate.budgetBlocked(credits: blocked.credits, store: .shared).payload.objectValue ?? [:]) { _, new in new }
        }
        finish(cancelled ? .cancelled : .failed, message(error))
    }

    /// 只有付费请求之前可用普通本机退档；本地失败后的恢复绝不重新选声或生成。
    private func prepareNew() async throws -> Bool {
        let key: String
        let plan: SkyStudioVoicePlan
        do {
            key = try await services.key()
            let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
            let kind = input.clone == nil ? "voice" : "voice_clone"
            guard let model = catalog.models(kind: kind).first else { throw AIToolError("Sky Studio offers no \(kind) model right now.") }
            plan = try SkyStudioVoicePlan.make(lines: input.lines.map(\.text), model: model, voice: input.choice.name, language: input.language)
            if plan.clones, plan.batches.contains(where: { $0.speech.parts.count > 1 }) { locale = try await services.locale(input.language) }
        } catch is CancellationError { throw CancellationError() }
        catch { try await fallback(message(error)); return false }
        guard projectUnchanged, let project else { throw AIToolError("The original project was closed or changed; nothing was charged.") }
        if input.speed != 1 {
            input.choice.note = [input.choice.note, "The Sky Studio voice speaks at its own pace; speed was ignored."].compactMap { $0 }.joined(separator: " ")
        }
        let recovery = SkyStudioVoiceRecovery(input: input, project: project, plan: plan, file: recoveryFile)
        self.recovery = recovery
        stage = .checkpoint
        try await recovery.save()
        AIReadGrants.shared.remember([recoveryFile])
        status.modelTitle = plan.model.title
        cloud = SkyStudioVoiceCloudBatches(recovery: recovery, input: input, api: services.api, key: key, status: status,
                                         canSubmit: { [weak self] in self?.projectUnchanged == true })
        stage = .cloudGeneration
        do { try await cloud?.prepareMissing() }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SkyStudioFailure { try await fallback(message(failure)); return false }
        return true
    }

    private func cloudBatches() async throws -> SkyStudioVoiceCloudBatches {
        if let cloud { return cloud }
        guard let recovery else { throw AIToolError("Missing recovery record.") }
        let key = try await services.key()
        let cloud = SkyStudioVoiceCloudBatches(recovery: recovery, input: input, api: services.api, key: key, status: status,
                                             canSubmit: { [weak self] in self?.projectUnchanged == true })
        self.cloud = cloud
        return cloud
    }

    private func fallback(_ note: String) async throws {
        try Task.checkCancellation()
        input = try input.localFallback(note)
        guard let project, projectUnchanged else { throw AIToolError("The original project was closed before the voiceover started.") }
        stage = .fileWrite
        let plan = try await AIVoiceoverTool.plan(input, project)
        if let recovery {
            for (line, spoken) in plan.spoken.enumerated() {
                recovery.value.outputs[line] = .init(url: spoken.output.url, duration: spoken.output.duration, words: spoken.output.words)
            }
        }
        try Task.checkCancellation()
        stage = .insertion
        try await land(plan: plan, project: project)
    }

    private func land(outputs: [AISpeechSynthesis.Output]) async throws {
        guard let project, projectUnchanged, let recovery else { throw AIToolError("The voice files were made, but the original project is no longer open; use recovery_file after reopening it.") }
        let existing = recovery.value.landingIDs.filter { project.state.clip(with: $0) != nil }
        if !existing.isEmpty {
            guard existing.count == recovery.value.landingIDs.count else { throw AIToolError("Some clips from this voiceover are already present. No audio or subtitles were duplicated; keep the existing insertion and inspect the timeline.") }
            recovery.value.applied = ["already_inserted": true]
            try await recovery.save()
            return finish(.done, "The saved insertion is already on the timeline; nothing was added again.")
        }
        var plan = try await AIVoiceoverTool.plan(input, project, outputs: outputs, playhead: recovery.value.input.playhead)
        if !recovery.value.landingIDs.isEmpty {
            guard recovery.value.landingIDs.count == plan.spoken.count else { throw AIToolError("The saved voiceover insertion does not match its lines.") }
            for index in plan.spoken.indices {
                guard let clip = ClipboardIdentity.renewed(plan.spoken[index].clip, id: recovery.value.landingIDs[index]) else {
                    throw AIToolError("The saved voiceover clip identity could not be restored; nothing was inserted.")
                }
                plan.spoken[index].clip = clip
            }
        }
        try Task.checkCancellation()
        try await land(plan: plan, project: project)
    }

    private func land(plan: AIVoiceoverTool.Plan, project: VideoEditProject) async throws {
        if let recovery {
            if recovery.value.landingIDs.isEmpty { recovery.value.landingIDs = plan.spoken.map(\.clip.id) }
            try await recovery.save() // 云端与普通退档共用：先记稳定身份，再允许改工程。
        }
        try Task.checkCancellation()
        guard projectUnchanged else { throw AIToolError("The original project changed before insertion; all voice files were kept.") }
        var result = try AIUndoGrouping.step(project.effectiveUndoManager) { try AIVoiceoverTool.apply(plan, project) }
        AISession.shared.round(for: project).noteChange()
        result = AIProjectTools.saveIfNeverSaved(project, after: result)
        extra = result.payload.objectValue ?? [:]
        extra["project"] = .string(project.shortID)
        if let recovery {
            recovery.value.applied = result.payload
            recovery.value.projectPath = project.documentURL?.standardizedFileURL.path
            try await recovery.save()
        }
        finish(.done, "The voiceover was added as one undo step.")
    }

    private func detail() -> [String: JSONValue] {
        var value = status.progress?.json() ?? [:]
        value.merge(recovery?.value.detail(recoveryFile: recoveryFile.path) ?? [:]) { _, new in new }
        let ids = recovery?.value.batches.compactMap(\.serverID) ?? []
        value["skystudio_job_ids"] = .array(ids.map(JSONValue.string))
        if let last = ids.last { value["skystudio_job_id"] = .string(last) }
        value["batch_index"] = .number(Double(batchIndex + 1))
        value["batch_count"] = .number(Double(recovery?.value.batches.count ?? 0))
        value["submission_keys"] = .array(recovery?.value.plan.batches.map { .string($0.request.idempotencyKey) } ?? [])
        value.merge(extra) { _, new in new }
        return value
    }

    private func finish(_ state: AIJobs.Status, _ text: String) {
        guard let job else { return }
        if state == .failed { status.issue = text }
        AIReadGrants.shared.remember([recoveryFile] + (recovery?.value.outputs.values.map(\.url) ?? []))
        AIJobs.shared.finish(job, state, message: text, detail: .object(detail()))
    }

    private func message(_ error: Error) -> String {
        if let error = error as? AIToolError { return error.message }
        if let error = error as? SkyStudioJobError { return error.message }
        if let error = error as? SkyStudioFailure { return SkyStudioJobError.request(error).message }
        return error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if let wrapped = error as? SkyStudioVoiceProcessingError { return isCancellation(wrapped.underlying) }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        if case .stopped? = error as? SkyStudioJobError { return true }
        return false
    }

    private var projectUnchanged: Bool {
        guard let project else { return false }
        return project.isCurrentGeneration(input.generation) && OpenProjects.shared.all.contains(where: { $0 === project })
    }
}
