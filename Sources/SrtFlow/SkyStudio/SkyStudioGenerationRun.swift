import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - generate_media 的一次生成怎么跑：（已记账）→ 取 Key → 传首帧 → 交给 Sky Studio、等 → 下载 → 结局
//
// 管什么：`generate_media` 起的那个任务从头到尾（`AIJobs` 里的一条，`get_job` 看得到）。2026-10-28 起送 Sky Studio（收费方案第 6 刀 6b），之前送 fal。
// 1. 花积分的把关在起任务之前（`SkyStudioJobGate.decide`，和 upscale_clip 同一处），任务拿到已经记上的那一笔（`SkyStudioHeldCredits`）。
// 2. 取 Key：AI 起的，不弹钥匙串授权框（读不到就请用户去设置里点「允许…」）。
// 3. 图生视频先把首帧 `/uploads` 上去；交任务、照 poll_after_seconds 等（`SkyStudioJobRun`：满了等着再交、停的规矩）；成品下载到「生成」文件夹。
//    阶段（上传、排队带位置、处理、下载带字节比例）记在 `progress`：编辑器顶上的状态行订阅它，`get_job` 跑着时并进 phase 那几个字段，
//    交上了还带 skystudio_job_id。
// 4. 账：没交上、排队中取消了、Sky Studio 说没做成就退回；做完按实收换；交上之后停不下来的、下载出错的不退（积分花了，成品在作品库里）。
// 不管什么：参数怎么读、问价、把关（SkyStudioGenerateTool）；HTTP（SkyStudioAPI）；等的规矩（SkyStudioJobRun）。

@MainActor
final class SkyStudioGenerationRun: ObservableObject, Identifiable {
    let id = UUID()
    private(set) var generation: SkyStudioGeneration
    private(set) var modelTitle: String
    /// 用户同意的价（`/quote` 报的，交任务时当 max_credits）；状态行上「72 credits」。
    private(set) var credits: Double
    private var modelID: String
    private var typicalSeconds: Double
    /// 图生视频的首帧（要先传上去）。
    private let references: SkyStudioReferencePlan
    private let catalog: SkyStudioCatalog
    private let ask: SkyStudioGeneration.Ask
    private let canvas: Double
    private let frameRatio: Double?
    private let allowsFallback: Bool
    private let approvedCeiling: Double
    private let folder: URL
    private let stem: String
    /// 起它的时候这个会话在剪的工程（做出来的文件能不能不问就读，看它的家）。**弱引用**：几个工程同时开着时，工程可能先关、任务后回来
    /// （docs/plans/2026-10-17-multi-project-ai-editing.md 事实第 12 条）；不在了就用主窗口那个。
    private weak var project: VideoEditProject?
    private var anyProject: VideoEditProject { project ?? OpenProjects.shared.primary }

    /// 跑到哪一步了：状态行订阅它，`get_job` 从 `liveDetail` 读同一份；还没开始跑是 nil。
    private let status: SkyStudioMediaStatus
    var progress: CloudJobProgress? { status.progress }
    private var job: AIJobs.Job?
    private var task: Task<Void, Never>?
    private var held: SkyStudioHeldCredits?
    private var submitted = SkyStudioSubmission()
    private var requestSent = false
    private var requestKeys: [String] = []
    private var attempts: [JSONValue] = []
    private var lastFailure: SkyStudioJobFailure?
    private var creditsUnconfirmed = false
    private var serverFinished = false

    /// 同时下载的几个任务别挑到同一个文件名（挑名字和写文件之间隔着一次下载）。
    private static var claimedPaths: Set<String> = []
    static var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowGenerate", isDirectory: true) }

    init(
        generation: SkyStudioGeneration, model: SkyStudioModel, quote: SkyStudioQuote, references: SkyStudioReferencePlan, folder: URL, stem: String,
        project: VideoEditProject, reservation: SkyStudioJobGate.Reservation, catalog: SkyStudioCatalog, ask: SkyStudioGeneration.Ask,
        canvas: Double, frameRatio: Double?, allowsFallback: Bool
    ) {
        self.generation = generation
        modelID = model.id
        modelTitle = model.title
        credits = quote.credits
        typicalSeconds = quote.typicalSeconds ?? generation.typicalSeconds
        self.references = references
        self.catalog = catalog
        self.ask = ask
        self.canvas = canvas
        self.frameRatio = frameRatio
        self.allowsFallback = allowsFallback
        approvedCeiling = quote.credits
        self.folder = folder
        self.stem = stem
        self.project = project
        held = SkyStudioHeldCredits(reservation)
        let label: String
        switch generation.kind {
        case .image: label = L10n("Image")
        case .imageToVideo, .textToVideo: label = L10n("Video")
        case .music: label = L10n("Music")
        case .soundEffect: label = L10n("Sound effect")
        }
        status = SkyStudioMediaStatus(kindLabel: label, modelTitle: model.title, credits: quote.credits, uploads: references.uploads)
    }

    /// 图生视频要先传首帧（状态行上多一个「上传」）。
    var uploads: Bool { references.uploads }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(
            .generate, progress: { nil },
            liveDetail: { [weak self] in
                guard let self else { return [:] }
                var detail = self.progress?.json() ?? [:]
                if self.status.waitingForRefund { detail["phase"] = "waiting_for_refund" }
                if let id = self.submitted.jobID { detail["skystudio_job_id"] = .string(id) }
                return detail
            },
            cancel: { [weak self] in self?.cancel() }
        )
        self.job = job
        status.onCancel = { [weak self] in self?.cancel() }
        SkyStudioGenerationActivity.shared.add(status)
        // 强引用：调用它的工具回了任务号就不再拿着它，任务自己得把它撑到跑完（跑完这个闭包放掉，环就解开了）。
        task = Task { @MainActor in await self.execute() }
        return job
    }

    /// 停止 / cancel_job：任务取消（排着队的替它向 Sky Studio 取消、退钱；开始了的取消不了）。
    func cancel() {
        task?.cancel()
    }

    // MARK: 过程

    private func execute() async {
        // 怎么结束都从状态行上拿掉：结局 AI 会从 get_job 读到并告诉用户。
        defer { SkyStudioGenerationActivity.shared.remove(status) }
        advance(to: .preparing)
        guard !Task.isCancelled else {
            held?.refund()
            return finish(.cancelled, "The generation was stopped before it started; no credits were spent.")
        }
        let key: String
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let found): key = found
        case .failure(let problem):
            held?.refund()
            return finish(.failed, problem.message)
        }

        let api = SkyStudioAPI()
        do {
            if references.uploads { advance(to: .uploading(fraction: nil)) }
            let uploaded = try await SkyStudioReferenceFiles.upload(references, api: api, key: key) { [weak self] fraction in
                Task { @MainActor in self?.advance(to: .uploading(fraction: CloudJobPhase.quantized(fraction))) }
            }
            try Task.checkCancellation()
            let done = try await make(api: api, key: key, uploaded: uploaded)
            guard let result = done.result else { throw SkyStudioJobError.badAnswer("a finished job without a result") }
            let charged = done.creditsCharged ?? credits
            held?.settle(charged: charged)
            serverFinished = true
            let pathExtension = SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: generation.kind)
            let destination = claimDestination(extension: pathExtension)
            defer { Self.claimedPaths.remove(destination.path) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            advance(to: .downloading(fraction: nil))
            try await api.download(result.url, to: destination) { [weak self] fraction in
                Task { @MainActor in self?.advance(to: .downloading(fraction: CloudJobPhase.quantized(fraction))) }
            }
            advance(to: .finishing)
            succeed(destination, result, charged: charged)
        } catch let error as SkyStudioJobError {
            switch error {
            case .stopped(let stop):
                if stop == .nothingCharged { held?.refund() }
                creditsUnconfirmed = stop == .unknown
                finish(.cancelled, "The generation was stopped. " + error.message)
            case .failed:
                if error.canRefund(beforeAccepted: !submitted.value) { held?.refund() } else { creditsUnconfirmed = requestSent }
                finish(.failed, error.message)
            case .request, .badAnswer, .timedOut:
                // 交上之前出的错没花钱；交上之后断了的，活在服务器上照做、做完进作品库。
                if error.canRefund(beforeAccepted: !submitted.value) { held?.refund() } else { creditsUnconfirmed = requestSent }
                finish(.failed, error.message)
            }
        } catch is CancellationError {
            // 传首帧的时候停的没花钱；下载的时候停的，活已经做完了（积分花了，成品在作品库里）。
            if requestSent {
                creditsUnconfirmed = !serverFinished && lastFailure?.creditsReturned != true
                finish(.cancelled, serverFinished ? "The generation was stopped while downloading; it was already made and is in the Sky Studio library."
                    : "Stopped waiting for the original job. No replacement was submitted; check its task and refund status before regenerating.")
            } else {
                held?.refund()
                finish(.cancelled, "The generation was stopped before Sky Studio got it; no credits were spent.")
            }
        } catch let problem as SkyStudioGenerationFrame.Problem {
            held?.refund()
            finish(.failed, problem.message)
        } catch let failure as SkyStudioFailure {
            if !requestSent { held?.refund() }
            creditsUnconfirmed = requestSent && !serverFinished && lastFailure?.creditsReturned != true
            finish(.failed, SkyStudioJobError.request(failure).message)
        } catch {
            if !requestSent { held?.refund() }
            creditsUnconfirmed = requestSent && !serverFinished && lastFailure?.creditsReturned != true
            finish(.failed, "SkyCut could not save the result: \(error.localizedDescription)")
        }
    }

    /// 原单未知就原样抛出；只有真人参考拒绝且已退款，才换一次兼容模型。已上传的素材直接复用。
    private func make(api: SkyStudioAPI, key: String, uploaded: (inputs: [String: String], references: [JSONValue])) async throws -> SkyStudioJobStatus {
        do { return try await attempt(api: api, key: key, uploaded: uploaded) }
        catch let error as SkyStudioJobError {
            var failure = error.failure
            if allowsFallback, let original = failure, original.isRealPersonRefusal, !original.creditsReturned, original.jobID != nil {
                status.waitingForRefund = true
                defer { status.waitingForRefund = false }
                failure = try await SkyStudioJobRun(api: api, key: key).waitForRefund(original)
            }
            lastFailure = failure
            guard allowsFallback, !Task.isCancelled, let failure,
                  let candidate = SkyStudioGenerationFallback.candidate(failure: failure, originalModel: modelID, generation: generation, ask: ask,
                    references: references, catalog: catalog, canvas: canvas, frame: frameRatio, alreadySwitched: !attempts.isEmpty) else {
                if let failure, failure.creditsReturned { throw SkyStudioJobError.failed(failure) }
                throw error
            }
            held?.refund()
            var original: [String: JSONValue] = ["model_id": .string(modelID), "refusal": failure.json]
            if let id = submitted.jobID ?? failure.jobID { original["skystudio_job_id"] = .string(id) }
            attempts.append(.object(original))
            let quote = try await api.quote(candidate.generation.job(model: candidate.model.id), key: key)
            try Task.checkCancellation()
            guard let reservation = SkyStudioJobGate.reserveReplacement(credits: quote.credits, approvedCeiling: approvedCeiling) else {
                throw SkyStudioJobError.failed(SkyStudioJobFailure(message: "The original was refunded. Switching to \(candidate.model.title) costs "
                    + "\(SkyStudioCredits.text(quote.credits)) credits, above the approved \(SkyStudioCredits.text(approvedCeiling)); ask the user before starting it.",
                    fields: ["refunded": true]))
            }
            held = SkyStudioHeldCredits(reservation)
            generation = candidate.generation; modelID = candidate.model.id; modelTitle = candidate.model.title
            credits = quote.credits; typicalSeconds = quote.typicalSeconds ?? generation.typicalSeconds
            submitted = SkyStudioSubmission(); requestSent = false
            status.modelTitle = modelTitle; status.credits = credits; status.reset(typicalSeconds: typicalSeconds)
            lastFailure = nil
            return try await attempt(api: api, key: key, uploaded: uploaded)
        }
    }

    private func attempt(api: SkyStudioAPI, key: String, uploaded: (inputs: [String: String], references: [JSONValue])) async throws -> SkyStudioJobStatus {
        let request = generation.job(model: modelID, maxCredits: credits, uploaded: uploaded.inputs, references: uploaded.references)
        requestKeys.append(request.idempotencyKey)
        requestSent = true
        let submitted = self.submitted
        do {
            return try await SkyStudioJobRun(api: api, key: key).run(request) { [weak self] update in
                let next: CloudJobPhase?
                switch update {
                case .waitingForSlot: next = .queued(position: nil)
                case .status(let server):
                    submitted.mark(server.jobID)
                    switch server.state {
                    case .queued?: next = .queued(position: server.queuePosition)
                    case .running?: next = .processing
                    default: next = nil
                    }
                }
                if let next { Task { @MainActor in self?.advance(to: next) } }
            }
        } catch let error as SkyStudioJobError {
            lastFailure = error.failure
            if let id = error.failure?.jobID { submitted.mark(id) }
            throw error
        }
    }

    // MARK: 结局

    private func succeed(_ file: URL, _ result: SkyStudioJobResult, charged: Double) {
        // SkyCut 自己做的文件：AI 接着把它放上时间线时不该再问「读点名文件夹以外的文件」。
        if !AIWorkspace.shared.allowsReading(file, project: anyProject) { AIReadGrants.shared.remember([file]) }
        let store = SkyStudioSpendStore.shared
        var detail: [String: JSONValue] = [
            "file": .string(AIWorkspace.shared.display(file)),
            "kind": .string(generation.kind.rawValue),
            "model": .string(modelTitle),
            "credits_charged": .number(SkyStudioCredits.number(charged)),
            "spent_today_credits": .number(SkyStudioCredits.number(store.spentToday())),
            "daily_limit_credits": .number(store.dailyLimit),
            "next_step": .string("Put it on the timeline with add_clips using file" + (generation.kind.isSound ? " (track new_audio)." : ".")
                + " It is also kept in the user's Sky Studio library.")
        ]
        if let id = submitted.jobID { detail["skystudio_job_id"] = .string(id) }
        if let width = result.width, let height = result.height {
            detail["width"] = .number(width.rounded())
            detail["height"] = .number(height.rounded())
        }
        if let duration = result.duration { detail["duration"] = AIFormat.seconds(duration) }
        if generation.kind.isVideo {
            detail["note"] = .string("Generated clips may carry their own sound; it plays with the clip. "
                + "Lower or mute the clip's volume (edit_clip) when you add your own music or narration.")
        }
        finish(.done, "Made \(file.lastPathComponent).", detail: .object(detail))
    }

    private func finish(_ status: AIJobs.Status, _ message: String, detail: JSONValue? = nil) {
        guard let job else { return }
        var payload = detail?.objectValue ?? [:]
        // 交上了就带任务号（停不下来的那单、没做成的那单也说得出是哪一单）。
        if let id = submitted.jobID { payload["skystudio_job_id"] = .string(id) }
        payload["model_id"] = .string(modelID)
        payload["submission_keys"] = .array(requestKeys.map(JSONValue.string))
        if !attempts.isEmpty { payload["fallback_attempts"] = .array(attempts) }
        if let lastFailure { payload["failure"] = lastFailure.json }
        if creditsUnconfirmed { payload["credits_unknown"] = true }
        if status == .failed, lastFailure?.isRealPersonRefusal == true, payload["next_step"] == nil {
            payload["next_step"] = .string("Explain the Seedance reference refusal. Recommend MiniMax H3 or Google Omni after checking their complete reference/duration limits "
                + "with get_status models=true. Keep all inputs. " + (creditsUnconfirmed
                    ? "Continue checking the original task/refund; do not generate again while payment is unknown."
                    : "A replacement must stay within the approved price; otherwise ask before starting it."))
        }
        AIJobs.shared.finish(job, status, message: message, detail: .object(payload))
    }

    // MARK: 给状态行看的

    /// 「图片」「视频」「音乐」「音效」：状态行上「Generating <什么> with <模型>」。
    var kindLabel: String {
        switch generation.kind {
        case .image: return L10n("Image")
        case .imageToVideo, .textToVideo: return L10n("Video")
        case .music: return L10n("Music")
        case .soundEffect: return L10n("Sound effect")
        }
    }

    /// 换阶段：同一阶段同一比例不重发（状态行和 get_job 读的是同一份）。
    private func advance(to phase: CloudJobPhase) {
        status.advance(to: phase, typicalSeconds: typicalSeconds)
    }

    private func claimDestination(extension pathExtension: String) -> URL {
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: pathExtension) {
            FileManager.default.fileExists(atPath: $0.path) || Self.claimedPaths.contains($0.path)
        }
        Self.claimedPaths.insert(url.path)
        return url
    }
}
