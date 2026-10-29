import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：upscale_clip（把一段的原片送 Sky Studio 放大，做完直接换源）
//
// 管什么：参数读成一次 upscale —— 和面板同一份数（UpscalePanelModel 算范围、档位能不能送），模型和上限照 Sky Studio 的 /models、
// 价问 /quote（收费方案第 6 刀，2026-10-28 起；之前走 fal）；起 `UpscaleJob`（花积分按每日上限把关，在起任务之前：额度内直接记账、
// 超了当场回确认码，SkyStudioJobGate）→ **回任务号**，`get_job` 带阶段；做完**直接换源**（2026-10-02 用户定：AI 起的不弹对比窗口，
// 做完就换、一步撤销；用户随时右键「Compare with Original…」/「Revert」），任务的结局带 replaced_ids / file / 尺寸 / 实收的积分。
// 换源是异步落账：那一下自己包一层 `AIUndoGrouping.step`（scripts/check-mcp.sh 钉着）。Key 不弹钥匙串授权框（AI 起的，没人在看）。
// 不管什么：裁 / 传 / 等 / 下 / 封声（UpscalePipeline）、换源的规则（VideoEditClipUpscale）、积分怎么问（SkyStudioJobGate）、说明文字（MCPGenerationTools）。

@MainActor
enum AIUpscaleTool {
    static func upscale(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        // 小程序没存 Sky Studio 的 Key 就不列这个工具，但客户端可能缓存着旧清单：这里再认一次。
        guard SkyStudioAccount.shared.hasKey else { throw AIToolError(SkyStudioJobKey.Problem.noKey.message) }
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard let clip = state.clip(with: id) else {
            throw AIToolError("\(ids.short(id)) is not a clip; only video clips can be upscaled.")
        }
        guard !clip.isAudioOnly, !clip.isStillImage, let model = UpscalePanelModel(project: project, clipID: id) else {
            throw AIToolError("\(clip.name) is \(clip.isAudioOnly ? "audio" : "a still image"); only video clips can be upscaled.")
        }
        try refuseIfRunning(model.originalURL)
        let generation = project.documentGeneration
        let tierName = try args.choice("tier", from: MCPVocabulary.upscaleTiers)
        let target = try args.choice("target", from: MCPVocabulary.upscaleTargets).flatMap(AIUpscaleNames.target) ?? model.defaultTarget
        let choice = try args.choice("range", from: MCPVocabulary.upscaleRanges).flatMap(AIUpscaleNames.range) ?? model.defaultChoice
        guard model.targetApplies(target) else {
            throw AIToolError(
                "\(clip.name) is \(model.originalInfo.resolutionLabel), already at or above \(target.label) on its short side; nothing to upscale."
            )
        }

        // Sky Studio：Key（不弹框）、有哪些模型、这一段多少积分。
        let key: String
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let found): key = found
        case .failure(let problem): throw AIToolError(problem.message)
        }
        let api = SkyStudioAPI()
        let tiers: [UpscaleTier]
        do {
            tiers = UpscaleTier.all(in: try await SkyStudioCatalogCache.shared.catalog(key: key, api: api))
        } catch {
            throw AIToolError(message(error))
        }
        let tier = try pick(tierName, from: tiers, target: target)
        let row = model.rows(tiers: [tier], choice: choice, target: target)[0]
        if let refusal = row.refusal {
            throw AIToolError("\(tier.id) cannot take this: \(refusal.message)")
        }
        let quote: SkyStudioQuote
        do {
            quote = try await api.quote(row.quote, key: key)
        } catch {
            throw AIToolError(message(error))
        }
        // 问 Sky Studio 的这一两秒里工程可能换了、同一个原片可能被别的调用起了任务。
        guard project.documentGeneration == generation else {
            throw AIToolError("The project changed while SkyCut asked Sky Studio for the price; nothing was started. Call upscale_clip again.")
        }
        try refuseIfRunning(model.originalURL)

        let request = model.request(choice: choice, target: target, tier: tier, quote: quote)
        // 花积分的把关在起任务之前（AI 多开方案板 9）：超了每日上限当场回确认码，AI 在聊天里问用户、带码再调。
        let identity = SkyStudioApproval.identity(job: row.quote, credits: quote.credits, context: [
            "source": try SkyStudioApproval.file(request.originalURL),
            "from": .number(request.range.start), "to": .number(request.range.end),
            "clips": .array(request.range.coveredClipIDs.map(\.uuidString).sorted().map(JSONValue.string)),
            "project": .string(project.shortID)
        ])
        let reservation: SkyStudioJobGate.Reservation
        switch try SkyStudioJobGate.decide(credits: quote.credits, summary: UpscaleJob.summary(of: request), identity: identity, args: args) {
        case .needsConfirmation(let ask): return ask
        case .reserved(let reserved): reservation = reserved
        }

        // 任务：UpscaleJob 跑，AIJobs 里登记一条给 get_job 看（阶段、取消）。
        let job = UpscaleJob(
            request: request, clipIDs: request.range.coveredClipIDs, projectGeneration: project.documentGeneration, title: clip.name,
            approval: .ai(reservation)
        )
        let aiJob = AIJobs.shared.start(
            .upscale, progress: { nil },
            liveDetail: { [weak job] in
                guard let job else { return [:] }
                var detail: [String: JSONValue] = [:]
                if case .running(let progress) = job.state { detail = progress.json() }
                if let id = job.skyStudioJobID { detail["skystudio_job_id"] = .string(id) }
                return detail
            },
            cancel: { [weak job] in
                if let job { UpscaleActivity.shared.remove(job) }
            }
        )
        job.onFinished = { finished in land(finished, aiJob: aiJob, project: project) }
        job.onEnded = { ended in settle(ended, aiJob: aiJob) }
        UpscaleActivity.shared.add(job, opensCompare: false)

        let spend = SkyStudioSpendStore.shared
        let minutes = quote.typicalSeconds.map { CloudJobProgress.minutes($0) }
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(aiJob.id), "clip_id": .string(ids.short(id)),
            "tier": .string(tier.id), "target": .string(AIUpscaleNames.name(of: target)), "range": .string(AIUpscaleNames.name(of: choice)),
            "source_size": .string(model.originalInfo.resolutionLabel),
            "output_size": .string(sizeLabel(UpscalePanelModel.outputSize(quote, fallback: row.estimatedSize))),
            "seconds_sent": AIFormat.seconds(request.range.duration),
            "clips_to_replace": .array(request.range.coveredClipIDs.map { .string(ids.short($0)) }),
            "credits": .number(SkyStudioCredits.number(quote.credits)),
            "daily_limit_credits": .number(spend.dailyLimit), "spent_today_credits": .number(SkyStudioCredits.number(spend.spentToday())),
            "next_step": .string(
                "Tell the user it costs \(SkyStudioCredits.text(quote.credits)) Sky Studio credits"
                    + (minutes.map { " and usually takes about \($0) min" } ?? "") + ". Wait with get_job. When it is done the clips are "
                    + "already replaced (replaced_ids); the original file stays, the user can compare or revert from the clip's context menu, "
                    + "and the upscaled clip is also kept in the user's Sky Studio library."
            )
        ]
        if let minutes { result["typical_minutes"] = .number(Double(minutes)) }
        var notes: [String] = []
        if choice == .thisClip, let longer = model.longerElsewhere {
            notes.append(String(format: "Another clip uses %.1f s of this file; range=longest would cover both places in one job.", longer.duration))
        }
        if let chosen = request.range.chosen, request.range.duration < chosen.duration + 2 * UpscaleRange.handle - 0.05, choice != .wholeFile {
            notes.append("The handles were shortened so the range fits Sky Studio's limit of \(Int((tier.maxSourceSeconds ?? 30).rounded(.down))) s per upscale.")
        }
        if !notes.isEmpty { result["note"] = .string(notes.joined(separator: " ")) }
        return .ok(.object(result))
    }

    private static func refuseIfRunning(_ original: URL) throws {
        if let running = UpscaleActivity.shared.job(forOriginal: original), case .running = running.state {
            throw AIToolError("\(original.lastPathComponent) is already being upscaled; wait for that job with get_job.")
        }
    }

    /// 点名的模型（词表里有、Sky Studio 此刻也有）；没点名就是默认的那个。
    private static func pick(_ name: String?, from tiers: [UpscaleTier], target: UpscaleTarget) throws -> UpscaleTier {
        guard !tiers.isEmpty else { throw AIToolError("Sky Studio offers no upscale model right now.") }
        if let name {
            guard let match = tiers.first(where: { $0.id == name }) else {
                throw AIToolError("Sky Studio does not offer \(name) right now; it offers " + tiers.map(\.id).joined(separator: ", ") + ".")
            }
            return match
        }
        return UpscalePanelModel.defaultTier(in: tiers, target: target) ?? tiers[0]
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? SkyStudioFailure { return SkyStudioJobError.request(failure).message }
        return error.localizedDescription
    }

    // MARK: 结局

    /// 做完：换源（一步撤销）、选中换了的段、没存过的工程存一下、结局记给 AI 的任务；这一行从状态行上拿掉（AI 会告诉用户）。
    private static func land(_ finished: UpscaleJob, aiJob: AIJobs.Job, project: VideoEditProject) {
        defer { UpscaleActivity.shared.remove(finished) }
        guard let outcome = finished.outcome else { return }
        guard finished.projectGeneration == project.documentGeneration else {
            AIJobs.shared.finish(
                aiJob, .done, message: "The upscaled file was made, but the project changed meanwhile; no clip was replaced.",
                detail: .object([
                    "file": .string(AIWorkspace.shared.display(outcome.file)), "replaced_ids": .array([]), "skystudio_job_id": .string(outcome.jobID)
                ])
            )
            return
        }
        let replacement = ClipSourceSwap.Replacement(url: outcome.file, info: outcome.info, record: outcome.record)
        let done = AIUndoGrouping.step(project.effectiveUndoManager) {
            project.applyUpscale(replacement, to: project.clipIDs(usingPicture: finished.request.originalURL))
        }
        let ids = AIShortIDs(state: project.state)
        if !done.isEmpty {
            AISession.shared.round(for: project).noteChange()
            let first = done.compactMap { project.state.clip(with: $0) }.min { $0.timelineStart < $1.timelineStart }
            AIEditorPresenter.reveal(.init(clips: Set(done), time: first?.timelineStart), project: project)
        }
        var detail: [String: JSONValue] = [
            "replaced_ids": .array(done.map { .string(ids.short($0)) }),
            "file": .string(AIWorkspace.shared.display(outcome.file)),
            "width": .number(Double(Int(outcome.info.displaySize.width))), "height": .number(Double(Int(outcome.info.displaySize.height))),
            "duration": AIFormat.seconds(outcome.info.duration),
            "tier": .string(finished.request.tier.id),
            "skystudio_job_id": .string(outcome.jobID),
            "credits_charged": .number(SkyStudioCredits.number(outcome.creditsCharged)),
            "spent_today_credits": .number(SkyStudioCredits.number(SkyStudioSpendStore.shared.spentToday())),
            "elapsed_seconds": .number(outcome.elapsed.rounded()),
            "next_step": .string(done.isEmpty
                ? "No clip could be replaced (the range no longer covers any use of the file); the upscaled file was kept."
                : "The clips now use the upscaled file (one undo step). The original stays next to it; the user can compare or revert "
                    + "from the clip's context menu. get_timeline shows the new source_size.")
        ]
        if !outcome.audioRestored {
            detail["note"] = "The original sound could not be put back (ffmpeg is missing); the upscaled file has no sound."
        }
        let saved = AIProjectTools.saveIfNeverSaved(project, after: .ok(.object(detail), changed: !done.isEmpty))
        AIJobs.shared.finish(aiJob, .done, message: done.isEmpty ? "Upscaled; nothing replaced." : "Upscaled and replaced \(done.count) clip(s).", detail: saved.payload)
    }

    /// 没做成 / 停下来了：把结局记给 AI 的任务（done 在 land 里记）。
    private static func settle(_ ended: UpscaleJob, aiJob: AIJobs.Job) {
        // 交上了才有任务号：停不下来的那单、交上之后没做成的那单，AI 和用户找客服时说得出是哪一单。
        let detail = ended.skyStudioJobID.map { JSONValue.object(["skystudio_job_id": .string($0)]) }
        switch ended.state {
        case .failed(let message):
            AIJobs.shared.finish(aiJob, .failed, message: "Upscale failed: \(message)", detail: detail)
        case .cancelled(let stop):
            AIJobs.shared.finish(aiJob, .cancelled, message: "The upscale was stopped. " + SkyStudioJobError.stopped(stop).message, detail: detail)
        case .running, .done:
            break
        }
    }

    private static func sizeLabel(_ size: CGSize) -> String { "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))" }
}
