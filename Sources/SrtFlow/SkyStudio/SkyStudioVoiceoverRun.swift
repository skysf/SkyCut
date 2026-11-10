import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 云端配旁白 / 克隆：每批先保存，再本地处理，最后一次入轨
// 管什么：现有长任务接口、恢复调度、失败阶段与入轨回执；所有批次的原音频 / 映射 / 进度永久留在恢复目录。
// 新的一段在回任务号之前已经报过价、预留过积分（SkyStudioVoiceoverStart，2026-11-10 声音 PR 3 挪过去的）：任务里只剩（要转写、模型没装的
// 先明着装模型，声音 PR 5）记恢复记录、交、等、切、落地；退本机也只在那之前（付费请求交出去之后不再退本机）。
// 两步走（声音 PR 4，SkyCut 声音方案 8.2）：先把要的几批**同时**拿到本机（SkyStudioVoiceBatchQueue：按顺序领槽、同时交，回来的顺序不管），
// 再按原来的顺序切句、对字幕，全部好了一次落地。中途换了备用的，结果写清哪几句是哪个模型读的。
// 不管什么：报价与认声音（SkyStudioVoiceoverStart）、几批怎么交（SkyStudioVoiceBatchQueue / SkyStudioVoiceCloudBatches）、
// 切句与字幕对齐（SkyStudioVoiceRender）、文件合同（SkyStudioVoiceCheckpoint）。

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
    /// 几批各在哪一步（状态行、get_job）。
    private var board: SkyStudioVoiceBatchBoard?
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
        let batches = recovery.value.plan.batches
        let wanted = batches.indices.filter { index in batches[index].speech.parts.contains { recovery.value.outputs[$0.line] == nil } }
        try checkProject()
        stage = .cloudGeneration
        let audio = try await gather(wanted, done: batches.indices.filter { !wanted.contains($0) }, recovery: recovery)
        // 按原来的顺序切句：一句可能跨两批，前面那批缺着（这一次没让补）就停在那里，后面的留到补齐了再切。
        for index in wanted {
            guard let (file, result) = audio[index] else { break }
            batchIndex = index
            try Task.checkCancellation()
            try checkProject()
            stage = .localSplit
            status.advance(to: .finishing, typicalSeconds: nil)
            try await render.append(index, file: file, result: result)
        }
        guard recovery.value.ready else {
            try await recovery.save()
            // 中途备用的一次性费用还在等答复（普通 resume）：同一个问题、同一张令牌再给一遍（SkyStudioVoiceFallbackFee）。
            if let waiting = await SkyStudioVoiceFallbackFee.waiting(recovery, services: services) { extra.merge(waiting) { _, new in new } }
            return finish(.failed, "Available audio was recovered. Some batches have not been generated; resume with generate_missing=true to generate only those batches.")
        }
        stage = .insertion
        try await land(outputs: render.complete())
    }

    /// 要的那几批各拿到本机（SkyStudioVoiceBatchQueue）：下好的直接用，有原单的只 GET，没生成的按顺序领槽、同时交。
    private func gather(_ wanted: [Int], done: [Int], recovery: SkyStudioVoiceRecovery) async throws -> [Int: SkyStudioVoiceCloudBatches.Audio] {
        let sources = wanted.map { (index: $0, source: SkyStudioVoiceCloudBatches.source($0, in: recovery.value, generateMissing: generateMissing)) }
        let queue = SkyStudioVoiceBatchQueue(cloud: cloudBatches(recovery), slots: services.slots, kind: recovery.value.plan.kind,
                                             count: recovery.value.batches.count)
        queue.onChange = { [weak self] board in self?.show(board) }
        do { return try await queue.gather(sources, done: done) }
        catch {
            if let failed = queue.failure?.index { batchIndex = failed }
            throw error
        }
    }

    private func show(_ board: SkyStudioVoiceBatchBoard) {
        self.board = board
        status.show(board)
        if let first = board.first { batchIndex = first }
    }

    private func checkProject() throws {
        guard projectUnchanged else {
            throw SkyStudioVoiceProcessingError(stage: .insertion, underlying: AIToolError("The original project was closed or changed; recover into that project after reopening it."))
        }
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
            if failure.code == SkyStudioVoiceCodes.fallbackNeedsOneTime, let recovery {
                // 默认模型出错、备用要先花一次性费用（SkyCut 声音方案 4.5）：这一批停下、没扣钱，别的批照常收好；补上价、记下、问用户
                // （SkyStudioVoiceFallbackFee：resume + confirm_token 建、resume + skip_one_time 用原来的模型重试）。问不了就只说重试的办法。
                extra["next_step"] = .string("One batch failed on Sky Studio and its fallback first needs a one-time fee (failure.one_time); "
                    + "nothing was charged for that batch and the other batches are kept. SkyCut could not price that fee now. "
                    + "Tell the user. To retry the missing batches with the same model, call add_voiceover resume=recovery_file "
                    + "generate_missing=true. Never send the original lines again.")
                if let asked = await SkyStudioVoiceFallbackFee.ask(failure, recovery: recovery, services: services) {
                    extra.merge(asked) { _, new in new }
                }
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
        // 先记下为什么换了（get_job 的 voice.note）：新的预留留不下、之后哪一步没做成，AI 都看得到整段换了读法。
        input.choice.note = [input.choice.note, replanned.note].compactMap { $0 }.joined(separator: " ")
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
        let key = prepared.key
        cloud = SkyStudioVoiceCloudBatches(recovery: recovery, api: services.api, key: { key }, status: status, budget: prepared.budget,
                                           sleep: services.jobSleep, canSubmit: { [weak self] in self?.projectUnchanged == true })
        self.prepared = nil
        guard projectUnchanged else { throw AIToolError("The original project was closed or changed; nothing was charged.") }
        stage = .checkpoint
        try await recovery.save()
        AIReadGrants.shared.remember([recoveryFile])
        stage = .cloudGeneration
    }

    /// 恢复的任务：Key 等到真要上网时才读（音频都在本机就一次都不读）。
    private func cloudBatches(_ recovery: SkyStudioVoiceRecovery) -> SkyStudioVoiceCloudBatches {
        if let cloud { return cloud }
        let cloud = SkyStudioVoiceCloudBatches(recovery: recovery, api: services.api, key: services.key, status: status,
                                             sleep: services.jobSleep, canSubmit: { [weak self] in self?.projectUnchanged == true })
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
        // 声音说明以恢复记录为准（报价时写下的：认声音、服务器的 warnings、语速）；中途换了备用的再加一句（SkyCut 声音方案 8.4）。
        input.choice.note = recovery.value.input.note
        if recovery.value.lineModels != nil {
            input.choice.note = [input.choice.note, Self.mixedModelsNote].compactMap { $0 }.joined(separator: " ")
        }
        if let lines = recovery.value.estimatedSplitLines {
            input.choice.note = [input.choice.note, Self.estimatedSplitNote(lines)].compactMap { $0 }.joined(separator: " ")
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
            try await recovery.save() // 先记稳定身份，再允许改工程。
        }
        try Task.checkCancellation()
        guard projectUnchanged else { throw AIToolError("The original project changed before insertion; all voice files were kept.") }
        var result = try AIUndoGrouping.step(project.effectiveUndoManager) { try AIVoiceoverTool.apply(plan, project) }
        AISession.shared.round(for: project).noteChange()
        result = AIProjectTools.saveIfNeverSaved(project, after: result)
        extra = result.payload.objectValue ?? [:]
        extra["project"] = .string(project.shortID)
        if recovery?.value.lineModels != nil {
            extra["next_step"] = .string("Before the user listens, tell them what voice.note says: line_models lists which model read each line.")
        }
        if recovery?.value.estimatedSplitLines != nil {
            extra["next_step"] = .string([extra["next_step"]?.stringValue,
                "Tell the user what voice.note says about estimated_split_line_indices before they listen."].compactMap { $0 }.joined(separator: " "))
        }
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
        // 几批同时跑：好了几批、几批在跑、几批等空位（不造百分比）。
        if let board, board.total > 1 { value.merge(board.json) { _, new in new } }
        value["submission_keys"] = .array(recovery?.value.plan.batches.map { .string($0.request.idempotencyKey) } ?? [])
        // 声音和要转告的话运行中、没做成之后也报（落地的结果里有它自己的一份，在 extra 里、盖过这一份）：任务里重新报过价
        // （装不上转写模型，整段换了读的模型）之后，AI 光看新的 voice_plan 不知道为什么换了。
        var voice: [String: JSONValue] = ["name": .string(input.choice.name), "quality": .string(input.choice.qualityName)]
        if let note = input.choice.note, !note.isEmpty { voice["note"] = .string(note) }
        value["voice"] = .object(voice)
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

    /// 中途换了备用（`line_models` 里各句不全是同一个模型）：前后可能听得出差别，要统一只能整段重读（另报价）。
    static let mixedModelsNote = "Sky Studio switched to its fallback model part-way, so some lines were read by another model "
        + "(line_models) and may sound slightly different. To make them match, narrate the whole script again (it is quoted again first)."

    /// 句界是按字数估的那几句（`estimated_split_line_indices`）：一句的头尾可能带进旁边那句的一点声音，叫用户先听一下。
    static func estimatedSplitNote(_ lines: [Int]) -> String {
        "SkyCut had no word times for \(lines.count) lines read in one request (estimated_split_line_indices, zero-based) and this Mac "
            + "cannot transcribe this language, so it cut between them at the pauses nearest to where the character counts put them. "
            + "A cut may be slightly off: tell the user to listen to where those lines start and end."
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
