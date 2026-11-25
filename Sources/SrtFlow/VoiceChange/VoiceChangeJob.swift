import AVFoundation
import Foundation
import SrtFlowMCPKit

// MARK: - 一次变声的任务：传 → 交 → 等 → 下两个文件 → 一步落地
//
// 管什么（SkyCut 声音方案 4.8 第 3–7 步）：钱的事过了、记上账之后起的那一单。
// 1. 传截好的 WAV（`/uploads` purpose `voice_convert_source`），交 `/jobs`（kind `voice_convert`、`model: auto`、
//    `inputs.source_audio_url`、`params.target_voice`、`params.source`、有的话 `params.target_language`、`max_credits` = 报价）。
//    交和等只经 SkyStudioJobRun：声音池领槽、满了等、**不重放收费 POST**（结果不明的那一笔留在账上、照实说）、只有排着队的能取消。
// 2. 下载两个文件（变声后的人声、分离出来的背景），放原素材旁边（VoiceChangeOutputName，撞名加编号、不覆盖）。
// 3. 落地（VoiceChangeLanding）：原片段静音、两条新音频轨、两段新音频、链接。这是**异步落账**（不是用户事件）：一次 `perform`，
//    外面自己包一层 `AIUndoGrouping.step`——AI 起的、面板起的都走这一份，⌘Z 一步回去（方案 4.9）。
//    工程换了 / 关了、这一段不在了或被动得盖不住了：只留文件，结果里说清楚，**不落到别的工程**。
// 4. 账按服务器的结算证据改（多的退回、没花出去的退回）。
// 任务号立刻回（AI 用 get_job 等）；工具栏的云端任务浮层里有这一行（SkyStudioMediaStatus：上传 / 排队 / 处理 / 下载 / 收尾），
// 没做成留在浮层里等用户关掉。面板起的做完 / 没做成在工程的提示条上说一句；AI 起的由 AI 转告。
// 成品在服务器上留 60 天；本机没有恢复记录（SkyCut 中途退出，这一单的成品要去 Sky Studio 找，见 docs/architecture/voice-library.md）。
// Direct change (skip_separation in the draft, 2026-11-21): only the voice comes back, one file and one new track. A default
// change without its background lands nothing (strict, like a missing voice). separation_failed ends the job failed with
// nothing landed and the source still playing; the message is localized for the user, the AI gets the code and when to retry
// with skip_separation, and the panel opened again on that clip offers the direct change. A failed job's books follow Sky
// Studio's final net charge (separation_failed keeps the separation's part), not the whole reservation.
// 不管什么：问不问、报价（VoiceChangeTool / VoiceChangePanelModel）、请求怎么拼（VoiceChangeOrder / SkyStudioVoiceRequests）。

@MainActor
final class VoiceChangeJob {
    private let origin: VoiceChangeLanding.Origin
    private let source: VoiceChangeSource.Prepared
    private let draft: SkyStudioJobRequest
    private let quote: SkyStudioQuote
    private let target: VoiceChangeTarget
    private let clipName: String
    private let key: String
    private let notifies: Bool
    private let services: VoiceChangeServices
    private let owner: CloudTaskOwner
    private let fallbackFolders: [URL]
    private weak var project: VideoEditProject?
    private var held: SkyStudioHeldCredits
    private let status: SkyStudioMediaStatus
    private var serverID: String?
    /// The job id a refusal came with when Sky Studio had not given one before (a 402 with pending billing): get_job asks it.
    private var originalID: String?
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?
    /// A direct change: read from the draft that was quoted and is sent, so the job can never disagree with the quote.
    private var direct: Bool { SkyStudioVoiceRequests.skipsSeparation(draft) }

    init(origin: VoiceChangeLanding.Origin, source: VoiceChangeSource.Prepared, draft: SkyStudioJobRequest, quote: SkyStudioQuote,
         target: VoiceChangeTarget, clipName: String, key: String, reservation: SkyStudioJobGate.Reservation, project: VideoEditProject,
         notifies: Bool, services: VoiceChangeServices) {
        self.origin = origin
        self.source = source
        self.draft = draft
        self.quote = quote
        self.target = target
        self.clipName = clipName
        self.key = key
        self.notifies = notifies
        self.services = services
        self.project = project
        owner = CloudTasksActivity.owner(of: project)
        fallbackFolders = VoiceChangeOrder.fallbackFolders(for: project, services: services)
        held = SkyStudioHeldCredits(reservation)
        status = SkyStudioMediaStatus(kindLabel: L10n("Voice change"), modelTitle: String(format: L10n("Voice change · %@"), target.name),
                                      credits: reservation.credits, uploads: true, title: clipName, owner: owner, mediaKind: .audio)
    }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(.voiceChange, progress: { nil }, liveDetail: { [weak self] in self?.live() ?? [:] },
                                      cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        // Strong, like SkyStudioGenerationRun: the job outlives its task and get_job may ask Sky Studio after it ended (the
        // project is held weakly, so a closed project is not kept).
        job.refresh = { [self] in await refreshOriginal() }
        status.aiJobID = job.id
        status.onCancel = { [weak self] in self?.task?.cancel() }
        SkyStudioGenerationActivity.shared.add(status)
        VoiceChangeActivity.shared.began(origin.clipID)
        task = Task { @MainActor in await self.execute() }
        return job
    }

    private func execute() async {
        // 截好的那段声音只为这一单：怎么结束都删。没做成的那一行留在浮层里（有 issue 的 remove 不拿掉）。
        defer {
            try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
            SkyStudioGenerationActivity.shared.remove(status)
            VoiceChangeActivity.shared.ended(origin.clipID)
        }
        let done: SkyStudioJobStatus
        do {
            done = try await convert()
        } catch let error as SkyStudioJobError {
            if serverID == nil { originalID = error.failure?.jobID }
            settle(failed: error)
            if error.failure?.code == SkyStudioVoiceCodes.separationFailed { return separationFailed(error) }
            if !Task.isCancelled, let balance = SkyStudioBalanceRefusal.refusal(of: error, accepted: serverID != nil) {
                // The Sky Studio balance, not SkyCut's daily limit: the numbers and where only the user adds credits (MSG1).
                var fields = SkyStudioBalanceRefusal.fields(balance, retry: "call change_voice again")
                fields["failure"] = balance.failure.json
                fields["code"] = .string(SkyStudioBalanceRefusal.code)
                return finish(.failed, SkyStudioVoiceLibraryErrors.message(error), detail: fields, shown: SkyStudioBalanceRefusal.shown(balance))
            }
            return finish(Task.isCancelled ? .cancelled : .failed, SkyStudioVoiceLibraryErrors.message(error))
        } catch {
            // 传的时候、交上之前出的错：一分没花。
            if serverID == nil { held.refund() }
            let stopped = Task.isCancelled || error is CancellationError
            // A refusal the voice library knows (unavailable, too large…) keeps its own words below.
            if !stopped, SkyStudioVoiceLibraryErrors.kind(error) == nil, let failure = SkyStudioUploadFailure.from(error) {
                return finish(.failed, failure.message, detail: failure.fields(retry: "call change_voice again."),
                              shown: SkyStudioUploadWords.shown(failure))
            }
            return finish(stopped ? .cancelled : .failed, stopped && serverID == nil
                ? "The voice change was stopped before Sky Studio accepted it; nothing was charged."
                : SkyStudioVoiceLibraryErrors.uncharged(error))
        }
        // Only a final bill moves the books (VoiceChangeBilling): a result without its files keeps the reservation until one comes.
        VoiceChangeBilling.settle(&held, by: done.billing)
        guard case .conversion(let result)? = done.voiceResult else {
            return finish(.failed, "Sky Studio finished but returned no voice and background files; do not start the same change again "
                + "before checking this job with Sky Studio.", detail: VoiceChangeBilling.charges(done))
        }
        guard direct || result.backgroundURL != nil else {
            return finish(.failed, "Sky Studio finished without the separated background file, so SkyCut changed nothing on the timeline; "
                + "do not start the same change again before checking this job with Sky Studio.", detail: VoiceChangeBilling.charges(done))
        }
        let files: VoiceChangeLanding.Files
        do {
            files = try await download(result)
        } catch {
            return finish(.failed, "Sky Studio changed the voice (the credits were spent), but SkyCut could not save "
                + (direct ? "the voice file" : "the two files") + ": "
                + "\(SkyStudioVoiceLibraryErrors.message(error)) The result stays on Sky Studio for 60 days.", detail: VoiceChangeBilling.charges(done))
        }
        await land(files, result: result, server: done)
    }

    /// A failed or stopped job: the books follow Sky Studio's final net charge when it reports one above zero (separation_failed
    /// keeps the separation's part and returns the rest); otherwise only a refund the error proves (the rule before 2026-11-21).
    private func settle(failed error: SkyStudioJobError) {
        if let charged = error.failure?.billing?.netCharged, charged > 0 { held.settle(charged: charged) }
        else if error.canRefund(beforeAccepted: serverID == nil) { held.refund() }
    }

    /// separation_failed: the speech stayed in the background, so Sky Studio converted nothing. Nothing lands and the source keeps
    /// playing; the user reads the localized line, the AI the code and when to retry with skip_separation; the panel opened again
    /// on this clip starts with the direct change on (VoiceChangeActivity).
    private func separationFailed(_ error: SkyStudioJobError) {
        VoiceChangeActivity.shared.noteSeparationFailed(origin.clipID)
        var detail: [String: JSONValue] = ["code": .string(SkyStudioVoiceCodes.separationFailed)]
        if let failure = error.failure { detail["failure"] = failure.json }
        if let charged = error.failure?.billing?.netCharged { detail["credits_charged"] = .number(SkyStudioCredits.number(charged)) }
        detail["next_step"] = .string("Sky Studio separated the clip, but the speech stayed in the background, so nothing was converted and "
            + "nothing changed on the timeline; only the separation was charged (credits_charged). Do not send the same change again. If the "
            + "clip is a clean voice (AI or TTS speech, an isolated dialogue track, no music or noise), call change_voice again with "
            + "skip_separation=true; otherwise tell the user the separation did not work for this clip.")
        finish(.failed, "Voice separation failed: the speech stayed in the background, so nothing was converted. Only the separation was charged.",
               detail: detail, shown: L10n("Voice separation failed; you can change the voice directly instead."))
    }

    /// 传、交、等。回做完那一刻的状态。
    private func convert() async throws -> SkyStudioJobStatus {
        try Task.checkCancellation()
        let last = CloudPhaseBox()
        let typical = quote.typicalSeconds
        let report: @Sendable (CloudJobPhase) -> Void = { [weak self] phase in
            guard last.swap(phase) else { return }
            Task { @MainActor in self?.status.advance(to: phase, typicalSeconds: typical) }
        }
        report(.uploading(fraction: nil))
        let link = try await services.api.upload(
            fileURL: source.url, contentType: VoiceChangeSource.contentType, purpose: SkyStudioVoiceUpload.conversionSourcePurpose, key: key,
            named: clipName
        ) { fraction in report(.uploading(fraction: CloudJobPhase.quantized(fraction))) }
        var request = draft
        request.inputs["source_audio_url"] = link.absoluteString
        request.maxCredits = quote.credits
        var runner = SkyStudioJobRun(api: services.api, key: key)
        runner.slots = services.voice.slots
        if let sleep = services.voice.jobSleep { runner.sleep = sleep }
        runner.checkpoint = { [weak self] server in await self?.remember(server.jobID) }
        return try await runner.run(request) { [weak self] update in
            switch update {
            case .waitingForSlot: report(.queued(position: nil))
            case .status(let server):
                Task { @MainActor in self?.remember(server.jobID) }
                switch server.state {
                case .queued?: report(.queued(position: server.queuePosition))
                case .running?: report(.processing)
                default: break
                }
            }
        }
    }

    private func remember(_ id: String) { if serverID == nil { serverID = id } }

    private var refreshing = false
    /// get_job on a change that ended without Sky Studio's last word (a 402 that came with a job id and pending billing, a failure
    /// after acceptance): GET that original job, never a new submission, and settle the books by its billing. Before, get_job told the
    /// AI to query the original job but never asked it (MSG1 review, 2026-11-25).
    private func refreshOriginal() async {
        guard !refreshing, let job, job.status == .failed || job.status == .cancelled, let id = serverID ?? originalID else { return }
        refreshing = true
        defer { refreshing = false }
        let server: SkyStudioJobStatus
        do {
            server = try await services.api.job(id, key: key)
        } catch let failure as SkyStudioFailure {
            // A refusal can carry the job's final bill (a 402 billed 6.5): settle by it. A try? here dropped it, so the books kept 9.
            guard let billing = SkyStudioJobError.request(failure).failure?.billing else { return }
            VoiceChangeBilling.settle(&held, by: billing)
            var detail = VoiceChangeBilling.detail(billing)
            detail["billing_note"] = .string(billing.message)
            AIJobs.shared.updateDetail(job, detail)
            return
        } catch { return }
        VoiceChangeBilling.settle(&held, by: server.billing)
        var detail = VoiceChangeBilling.charges(server)
        if let state = server.state { detail["skystudio_status"] = .string(state.rawValue) }
        if let billing = server.billing { detail["billing_note"] = .string(billing.message) }
        AIJobs.shared.updateDetail(job, detail)
    }

    /// 下载两个文件到原素材旁边，量出各自多长。下到一半断了不留半个文件（SkyStudioAPI.download）；只下成一个就把它也删掉。
    /// A direct change downloads the voice alone (no background was made; one sent anyway is not what was asked for).
    private func download(_ result: SkyStudioVoiceConversion) async throws -> VoiceChangeLanding.Files {
        let background = direct ? nil : result.backgroundURL
        let places = VoiceChangeOutputName.destinations(
            original: origin.sourceURL, voiceName: target.name, backgroundLabel: L10n("background (file name)"),
            voiceExtension: VoiceChangeOutputName.pathExtension(contentType: result.contentType, url: result.voiceURL),
            backgroundExtension: VoiceChangeOutputName.pathExtension(contentType: result.backgroundContentType ?? result.contentType,
                                                                     url: background ?? result.voiceURL),
            fallbacks: fallbackFolders
        )
        let typical = quote.typicalSeconds
        let last = CloudPhaseBox()
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            let phase = CloudJobPhase.downloading(fraction: CloudJobPhase.quantized(fraction))
            guard last.swap(phase) else { return }
            Task { @MainActor in self?.status.advance(to: phase, typicalSeconds: typical) }
        }
        status.advance(to: .downloading(fraction: nil), typicalSeconds: typical)
        let voiceShare = background == nil ? 1.0 : 0.5
        do {
            try await fetch(result.voiceURL, to: places.voice) { report($0 * voiceShare) }
            if let background { try await fetch(background, to: places.background) { report(0.5 + $0 / 2) } }
            status.advance(to: .finishing, typicalSeconds: typical)
            var files = VoiceChangeLanding.Files(voice: places.voice, voiceSeconds: try await Self.seconds(of: places.voice))
            if background != nil { files.background = .init(file: places.background, seconds: try await Self.seconds(of: places.background)) }
            return files
        } catch {
            try? FileManager.default.removeItem(at: places.voice)
            if background != nil { try? FileManager.default.removeItem(at: places.background) }
            throw error
        }
    }

    /// 钱已经花了：下载断了再试两次（成品地址 60 天有效、不带 Key）。
    private func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                return try await services.api.download(url, to: destination, onProgress: progress)
            } catch {
                attempt += 1
                guard attempt < 3 else { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func seconds(of file: URL) async throws -> Double {
        let seconds = try await AVURLAsset(url: file).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw AIToolError("SkyCut could not read \(file.lastPathComponent) as audio.") }
        return seconds
    }

    // MARK: 落地

    /// 起它的那个工程还开着、还是那一次打开：是就回它。
    private var ownProject: VideoEditProject? {
        guard let project, project.isCurrentGeneration(owner.generation),
              OpenProjects.shared.all.contains(where: { $0 === project }) else { return nil }
        return project
    }

    private func land(_ files: VoiceChangeLanding.Files, result: SkyStudioVoiceConversion, server: SkyStudioJobStatus) async {
        var detail = VoiceChangeBilling.charges(server)
        detail["voice_file"] = .string(AIWorkspace.shared.display(files.voice))
        if let background = files.background { detail["background_file"] = .string(AIWorkspace.shared.display(background.file)) }
        detail["skip_separation"] = .bool(direct)
        detail["voice"] = .string(target.id)
        detail["voice_name"] = .string(target.name)
        if let language = draft.params["target_language"]?.stringValue { detail["target_language"] = .string(language) }
        if let outcome = server.voiceOutcome {
            if let model = outcome.model { detail["model"] = .string(model) }
            detail["fallback_used"] = .bool(outcome.fallbackUsed)
            if let warnings = outcome.plan?.warnings, !warnings.isEmpty { detail["warnings"] = .array(warnings.map(JSONValue.string)) }
        }
        if let padded = result.paddedSeconds, padded > 0 { detail["padded_seconds"] = .number(padded) }
        let made = [files.voice] + (files.background.map { [$0.file] } ?? [])
        AIReadGrants.shared.remember(made)
        guard let project = ownProject else {
            return keepFiles(detail, files: made.count, why: "the project it was started in is no longer open")
        }
        let voiceID = UUID(), backgroundID = UUID()
        var landed: Result<VoiceChangeLanding.Landed, VoiceChangeLanding.Refusal> = .failure(.clipGone)
        // 异步落账：自己包一层撤销分组（静音 + 两条新轨 + 两段新音频 + 链接 = 一步）。
        AIUndoGrouping.step(project.effectiveUndoManager) {
            _ = project.perform { state in
                landed = VoiceChangeLanding.land(files, origin: origin, voiceID: voiceID, backgroundID: backgroundID, in: &state)
            }
        }
        switch landed {
        case .failure(let refusal):
            keepFiles(detail, files: made.count, why: Self.reason(refusal))
        case .success(let placed):
            VoiceChangeActivity.shared.noteLanded(origin.clipID)
            let ids = AIShortIDs(state: project.state)
            detail["clip_id"] = .string(ids.short(origin.clipID))
            detail["voice_clip_id"] = .string(ids.short(placed.voiceID))
            if let id = placed.backgroundID { detail["background_clip_id"] = .string(ids.short(id)) }
            detail["voice_track"] = .string(AITrackName.name(of: .audio(placed.voiceTrack)))
            if let track = placed.backgroundTrack { detail["background_track"] = .string(AITrackName.name(of: .audio(track))) }
            detail["project"] = .string(project.shortID)
            detail["next_step"] = .string(
                (placed.backgroundID == nil
                    ? "The clip's voice now plays from one new linked audio clip (voice_clip_id); nothing was separated, so there is no "
                        + "background clip. The original clip is muted, not deleted. One undo step puts everything back. Tell the user to listen."
                    : "The clip's voice now plays from two new linked audio clips (voice_clip_id, background_clip_id); the original clip is "
                        + "muted, not deleted. One undo step puts everything back. Tell the user to listen; the background can be turned down "
                        + "on its own track.") + (detail["warnings"] == nil ? "" : " Also tell them what warnings says.")
            )
            if notifies {
                project.notice = String(format: L10n("Changed to the voice “%@”. The original sound is muted; press ⌘Z to undo."), target.name)
                finish(.done, "The voice was changed as one undo step.", detail: detail)
            } else {
                AISession.shared.round(for: project).noteChange()
                AIEditorPresenter.reveal(.init(clips: Set([placed.voiceID] + (placed.backgroundID.map { [$0] } ?? [])),
                                               time: project.state.clip(with: placed.voiceID)?.timelineStart), project: project)
                let saved = await AIProjectTools.saveIfNeverSaved(project, after: .ok(.object(detail), changed: true))
                finish(.done, "The voice was changed as one undo step.", detail: saved.payload.objectValue ?? detail)
            }
        }
    }

    /// 落不了：文件留着，照实说。`files`: how many were made (1 after a direct change).
    private func keepFiles(_ detail: [String: JSONValue], files: Int, why: String) {
        var value = detail
        value["landed"] = false
        value["next_step"] = .string((files == 1 ? "The voice file was made and kept (voice_file)"
                                                 : "The two files were made and kept (voice_file, background_file)")
            + ", but nothing on the timeline was changed because \(why). To use \(files == 1 ? "it, add it" : "them, add them") "
            + "with add_clips and mute the original clip.")
        if notifies, let project = ownProject {
            project.notice = files == 1
                ? L10n("The voice was changed, but the clip was edited meanwhile; the new voice file was saved next to the original and nothing on the timeline was changed.")
                : L10n("The voice was changed, but the clip was edited meanwhile; the two audio files were saved next to the original and nothing on the timeline was changed.")
        }
        finish(.done, "The voice was changed; the files were kept but the timeline was not changed (\(why)).", detail: value)
    }

    private static func reason(_ refusal: VoiceChangeLanding.Refusal) -> String {
        switch refusal {
        case .clipGone: return "the clip is no longer on the timeline"
        case .sourceChanged: return "the clip now uses another source file"
        case .notCovered: return "the clip now uses a part of its source that was not sent for the voice change"
        }
    }

    // MARK: 结果

    private func live() -> [String: JSONValue] {
        var value = status.progress?.json() ?? [:]
        value["provider"] = "Sky Studio"
        value["credits"] = .number(SkyStudioCredits.number(quote.credits))
        if let serverID { value["skystudio_job_id"] = .string(serverID) }
        return value
    }

    /// `shown`: what the user reads in the cloud task row and the notice bar when it differs from the AI's English (a localized
    /// line, such as the separation failure's).
    private func finish(_ outcome: AIJobs.Status, _ message: String, detail: [String: JSONValue] = [:], shown: String? = nil) {
        guard let job else { return }
        var value = detail
        if let serverID, value["skystudio_job_id"] == nil { value["skystudio_job_id"] = .string(serverID) }
        if outcome == .failed {
            // 没做成：留在云端任务浮层里等用户看（有 issue 的那一行不自动拿掉）；面板起的再在提示条上说一句。
            status.issue = shown ?? message
            if notifies { ownProject?.notice = String(format: L10n("Changing the voice of “%@” did not finish. %@"), clipName, shown ?? message) }
        }
        AIJobs.shared.finish(job, outcome, message: message, detail: value.isEmpty ? nil : .object(value))
    }
}
