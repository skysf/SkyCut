import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 云端配旁白 / 克隆：每批先保存，再本地处理，最后一次入轨
// 管什么：现有长任务接口、恢复调度、失败阶段与入轨回执；所有批次的原音频 / 映射 / 进度永久留在恢复目录。
// 新的一段在回任务号之前已经报过价、预留过积分（SkyStudioVoiceoverStart，2026-11-10 声音 PR 3 挪过去的）：任务里只剩（要转写、模型没装的
// 先明着装模型，声音 PR 5）记恢复记录、交、等、切、落地；退本机也只在那之前（付费请求交出去之后不再退本机）。
// 不管什么：报价与认声音（SkyStudioVoiceoverStart）、请求与预算（SkyStudioVoiceCloudBatches）、切句与字幕对齐（SkyStudioVoiceRender）、
// 文件合同（SkyStudioVoiceCheckpoint）。

@MainActor
final class SkyStudioVoiceoverRun {
    private var input: AIVoiceoverInput
    private weak var project: VideoEditProject?
    let status: SkyStudioMediaStatus
    private let services: SkyStudioVoiceServices
    /// 新的一段：回任务号之前做完的报价、预留、Key；恢复的任务是 nil。
    private var prepared: SkyStudioVoiceoverPrepared?
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
    /// 交第一批之前在本机做的那一步（装转写模型），get_job 的 `local_step` / `local_step_percent`。
    private var localStep: String?
    private var localStepPercent: Int?

    init(input: AIVoiceoverInput, project: VideoEditProject, prepared: SkyStudioVoiceoverPrepared? = nil, recovery: SkyStudioVoiceRecovery? = nil,
         generateMissing: Bool = true, services: SkyStudioVoiceServices? = nil) {
        self.input = input
        self.project = project
        self.prepared = prepared
        self.recovery = recovery
        self.generateMissing = generateMissing
        self.services = services ?? SkyStudioVoiceServices()
        locale = prepared?.locale
        recoveryFile = (recovery?.file ?? input.folder.appendingPathComponent("Voiceover-\(UUID().uuidString).recovery").appendingPathComponent("voiceover-recovery.json"))
            .standardizedFileURL.resolvingSymlinksInPath()
        let title = prepared?.modelTitle ?? recovery?.value.plan.voicePlan.model ?? "Sky Studio"
        status = SkyStudioMediaStatus(kindLabel: L10n("Voiceover"), modelTitle: title, credits: prepared?.plan.batchCredits.reduce(0, +),
            uploads: false, owner: CloudTasksActivity.owner(of: project), mediaKind: .audio)
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
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(job.id), "provider": "Sky Studio", "recovery_file": .string(recoveryFile.path),
            "next_step": "Wait with get_job. On failure preserve recovery_file; call add_voiceover resume=recovery_file for local recovery, never repeat the original lines. Only generate_missing=true may pay for missing batches."
        ]
        if let prepared {
            var voice: [String: JSONValue] = ["name": .string(input.choice.name), "quality": .string(input.choice.qualityName)]
            if prepared.installsTranscription {
                result["next_step"] = .string("SkyCut first installs this Mac's speech model for "
                    + "\(SkyStudioVoicePick.languageName(input.language)) (get_job local_step), before anything is paid. "
                    + (result["next_step"]?.stringValue ?? ""))
            }
            if let note = input.choice.note {
                voice["note"] = .string(note)
                result["next_step"] = .string("Before the user listens, tell them what voice.note says. " + (result["next_step"]?.stringValue ?? ""))
            }
            if input.subtitles, let timing = prepared.plan.reading?.timing { result["subtitle_timing"] = .string(timing.rawValue) }
            result["voice"] = .object(voice)
            result["voice_plan"] = prepared.plan.voicePlan.json
            result["batches"] = .number(Double(prepared.plan.batches.count))
            result["credits"] = .number(prepared.plan.batchCredits.reduce(0, +))
            if let expected = prepared.quote.creditsExpected { result["credits_expected"] = .number(expected) }
        }
        return .ok(.object(result))
    }

    private func execute() async {
        defer {
            // 预留还没交给云端批次就停了（一开始就取消、工程关了）：在这里退回。交过去之后只在云端批次那一份里退，不会退两次。
            if var unused = prepared?.budget { unused.refundUnused(); prepared = nil }
            cloud?.refundUnused()
            SkyStudioVoiceRecovery.active[recoveryFile.path] = nil
            SkyStudioGenerationActivity.shared.remove(status)
        }
        status.advance(to: .preparing, typicalSeconds: nil)
        do {
            try Task.checkCancellation()
            if recovery == nil {
                try await installTranscription()
                try await prepareNew()
            }
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
        let transcription = services.transcription
        let render = SkyStudioVoiceRender(input: input, recovery: recovery, locale: locale, transcribe: services.transcribe,
            localeProvider: { language in try SkyStudioVoiceTranscription.locale(await transcription(language), language: language) })
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
        // 结构化的原因（比如参考录音人声不够的 reason / voiced_seconds / missing_seconds）照样交给 get_job，不只留一句话。
        if let tool = error as? AIToolError { extra.merge(tool.details) { current, _ in current } }
        if let blocked = error as? SkyStudioVoiceBudgetProblem {
            extra.merge(SkyStudioJobGate.budgetBlocked(credits: blocked.credits, store: .shared).payload.objectValue ?? [:]) { _, new in new }
        }
        finish(cancelled ? .cancelled : .failed, message(error))
    }

    /// 回任务号时说好要先装本机转写模型的：交第一批之前装（状态行「准备本机转写」，get_job 的 local_step）。装不上就当这台 Mac
    /// 转写不了：照「不能转写」重新分批、报价、预留（还一分没花），voice.note 说为什么（SkyCut 声音方案第七节：下载失败当作不能转写）。
    private func installTranscription() async throws {
        guard let current = prepared, current.installsTranscription, let locale = current.locale else { return }
        localStep = "installing_speech_model"
        status.stepNote = L10n("Preparing transcription")
        defer { localStep = nil; localStepPercent = nil; status.stepNote = nil }
        do {
            try await services.install(locale) { [weak self] fraction in self?.installed(fraction) }
            prepared?.installsTranscription = false
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            try await withoutTranscription(failure: message(error))
        }
    }

    private func installed(_ fraction: Double) {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        guard localStep != nil, percent != localStepPercent else { return }
        localStepPercent = percent
        status.stepNote = String(format: L10n("Preparing transcription %d%%"), percent)
    }

    /// 装不上转写模型：按「转写不了」再报一次价，先退旧的预留、再留新的。预留是值类型，在 `prepared` 上原地退（不能退一份拷贝，
    /// 不然结束时又退一遍）；新的留不下（每日上限）就什么都不留、按额度不够停下。
    private func withoutTranscription(failure: String) async throws {
        guard let current = prepared else { return }
        let replanned = try await SkyStudioVoiceoverStart.withoutTranscription(current, input: input, failure: failure, services: services)
        prepared?.budget.refundUnused()
        guard let budget = SkyStudioVoiceBudget.reserve(replanned.plan.batchCredits) else {
            prepared = nil
            throw SkyStudioVoiceBudgetProblem(credits: replanned.plan.batchCredits.reduce(0, +))
        }
        prepared?.plan = replanned.plan
        prepared?.quote = replanned.quote
        prepared?.budget = budget
        prepared?.locale = nil
        prepared?.installsTranscription = false
        locale = nil
        if let catalog = current.catalog { prepared?.modelTitle = SkyStudioVoiceoverStart.modelTitle(replanned.plan, catalog: catalog) }
        input.choice.note = [input.choice.note, replanned.note].compactMap { $0 }.joined(separator: " ")
        status.credits = replanned.plan.batchCredits.reduce(0, +)
        if let title = prepared?.modelTitle { status.modelTitle = title }
    }

    /// 新的一段：报价和预留回任务号之前就做完了（SkyStudioVoiceoverStart），这里先把预留交给云端批次（任务结束时没花出去的退回），
    /// 再写下恢复记录。付费请求交出去之后不再退本机；本地失败后的恢复绝不重新选声或生成。
    private func prepareNew() async throws {
        guard let prepared else { throw AIToolError("The voiceover's quote is missing; nothing was charged.") }
        guard let project else { throw AIToolError("The original project was closed before the voiceover started; nothing was charged.") }
        let recovery = SkyStudioVoiceRecovery(input: input, project: project, plan: prepared.plan, file: recoveryFile)
        self.recovery = recovery
        cloud = SkyStudioVoiceCloudBatches(recovery: recovery, api: services.api, key: prepared.key, status: status, budget: prepared.budget,
                                           canSubmit: { [weak self] in self?.projectUnchanged == true })
        self.prepared = nil
        guard projectUnchanged else { throw AIToolError("The original project was closed or changed; nothing was charged.") }
        stage = .checkpoint
        try await recovery.save()
        AIReadGrants.shared.remember([recoveryFile])
        stage = .cloudGeneration
    }

    private func cloudBatches() async throws -> SkyStudioVoiceCloudBatches {
        if let cloud { return cloud }
        guard let recovery else { throw AIToolError("Missing recovery record.") }
        let key = try await services.key()
        let cloud = SkyStudioVoiceCloudBatches(recovery: recovery, api: services.api, key: key, status: status,
                                             canSubmit: { [weak self] in self?.projectUnchanged == true })
        self.cloud = cloud
        return cloud
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
        // 声音说明以恢复记录为准（报价时写下的：认声音、服务器的 warnings、语速）。
        input.choice.note = recovery.value.input.note
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
            try await recovery.save() // 先记稳定身份，再允许改工程。
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
        if let localStep {
            value["local_step"] = .string(localStep)
            if let localStepPercent { value["local_step_percent"] = .number(Double(localStepPercent)) }
        }
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
