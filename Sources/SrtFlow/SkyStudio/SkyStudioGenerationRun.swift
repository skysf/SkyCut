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
    let generation: SkyStudioGeneration
    let modelTitle: String
    /// 用户同意的价（`/quote` 报的，交任务时当 max_credits）；状态行上「72 credits」。
    let credits: Double
    private let modelID: String
    private let typicalSeconds: Double
    /// 图生视频的首帧（要先传上去）。
    private let frame: URL?
    private let folder: URL
    private let stem: String
    /// 起它的时候这个会话在剪的工程（做出来的文件能不能不问就读，看它的家）。**弱引用**：几个工程同时开着时，工程可能先关、任务后回来
    /// （docs/plans/2026-10-17-multi-project-ai-editing.md 事实第 12 条）；不在了就用主窗口那个。
    private weak var project: VideoEditProject?
    private var anyProject: VideoEditProject { project ?? OpenProjects.shared.primary }

    /// 跑到哪一步了：状态行订阅它，`get_job` 从 `liveDetail` 读同一份；还没开始跑是 nil。
    private let status: SkyStudioMediaStatus
    var progress: FalJobProgress? { status.progress }
    private var job: AIJobs.Job?
    private var task: Task<Void, Never>?
    private var held: SkyStudioHeldCredits?
    private let submitted = SkyStudioSubmission()

    /// 同时下载的几个任务别挑到同一个文件名（挑名字和写文件之间隔着一次下载）。
    private static var claimedPaths: Set<String> = []
    static var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowGenerate", isDirectory: true) }

    init(
        generation: SkyStudioGeneration, model: SkyStudioModel, quote: SkyStudioQuote, frame: URL?, folder: URL, stem: String,
        project: VideoEditProject, reservation: SkyStudioJobGate.Reservation
    ) {
        self.generation = generation
        modelID = model.id
        modelTitle = model.title
        credits = quote.credits
        typicalSeconds = quote.typicalSeconds ?? generation.typicalSeconds
        self.frame = frame
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
        status = SkyStudioMediaStatus(kindLabel: label, modelTitle: model.title, credits: quote.credits, uploads: frame != nil)
    }

    /// 图生视频要先传首帧（状态行上多一个「上传」）。
    var uploads: Bool { frame != nil }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(
            .generate, progress: { nil },
            liveDetail: { [weak self] in
                guard let self else { return [:] }
                var detail = self.progress?.json() ?? [:]
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
        let submitted = self.submitted
        do {
            let imageURL = try await uploadFrame(api: api, key: key)
            try Task.checkCancellation()
            let request = generation.job(model: modelID, imageURL: imageURL, maxCredits: credits)
            let done = try await SkyStudioJobRun(api: api, key: key).run(request) { [weak self] update in
                let next: FalJobPhase?
                switch update {
                case .waitingForSlot:
                    next = .queued(position: nil)
                case .status(let status):
                    submitted.mark(status.jobID)
                    switch status.state {
                    case .queued?: next = .queued(position: status.queuePosition)
                    case .running?: next = .processing
                    default: next = nil   // 做完了：下一步就是下载
                    }
                }
                if let next { Task { @MainActor in self?.advance(to: next) } }
            }
            guard let result = done.result else { throw SkyStudioJobError.badAnswer("a finished job without a result") }
            let charged = done.creditsCharged ?? credits
            held?.settle(charged: charged)
            let pathExtension = SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: generation.kind)
            let destination = claimDestination(extension: pathExtension)
            defer { Self.claimedPaths.remove(destination.path) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            advance(to: .downloading(fraction: nil))
            try await api.download(result.url, to: destination) { [weak self] fraction in
                Task { @MainActor in self?.advance(to: .downloading(fraction: FalJobPhase.quantized(fraction))) }
            }
            advance(to: .finishing)
            succeed(destination, result, charged: charged)
        } catch let error as SkyStudioJobError {
            switch error {
            case .stopped(let stop):
                if stop == .nothingCharged { held?.refund() }
                finish(.cancelled, "The generation was stopped. " + error.message)
            case .failed:
                // Sky Studio 说没做成：它自己退钱（只退一次）。
                held?.refund()
                finish(.failed, error.message)
            case .request, .badAnswer, .timedOut:
                // 交上之前出的错没花钱；交上之后断了的，活在服务器上照做、做完进作品库。
                if !submitted.value { held?.refund() }
                finish(.failed, error.message)
            }
        } catch is CancellationError {
            // 传首帧的时候停的没花钱；下载的时候停的，活已经做完了（积分花了，成品在作品库里）。
            if submitted.value {
                finish(.cancelled, "The generation was stopped while downloading; it was already made, so the credits are spent and the "
                    + "result is in the user's Sky Studio library.")
            } else {
                held?.refund()
                finish(.cancelled, "The generation was stopped before Sky Studio got it; no credits were spent.")
            }
        } catch let problem as SkyStudioGenerationFrame.Problem {
            held?.refund()
            finish(.failed, problem.message)
        } catch let failure as SkyStudioFailure {
            if !submitted.value { held?.refund() }
            finish(.failed, SkyStudioJobError.request(failure).message)
        } catch {
            if !submitted.value { held?.refund() }
            finish(.failed, "SkyCut could not save the result: \(error.localizedDescription)")
        }
    }

    /// 图生视频：把首帧传上去，回 `/jobs` 的 inputs 要的地址；别的种类没有首帧。
    private func uploadFrame(api: SkyStudioAPI, key: String) async throws -> URL? {
        guard let frame else { return nil }
        advance(to: .uploading(fraction: nil))
        let prepared = try SkyStudioGenerationFrame.prepare(frame, workFolder: Self.workFolder)
        defer { prepared.cleanUp() }
        return try await api.upload(fileURL: prepared.url, contentType: prepared.contentType, purpose: "image", key: key) { [weak self] fraction in
            Task { @MainActor in self?.advance(to: .uploading(fraction: FalJobPhase.quantized(fraction))) }
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
            detail["note"] = .string("MiniMax H3 clips carry their own sound (room tone, foley, music); it plays with the clip. "
                + "Lower or mute the clip's volume (edit_clip) when you add your own music or narration.")
        }
        finish(.done, "Made \(file.lastPathComponent).", detail: .object(detail))
    }

    private func finish(_ status: AIJobs.Status, _ message: String, detail: JSONValue? = nil) {
        guard let job else { return }
        var payload = detail
        // 交上了就带任务号（停不下来的那单、没做成的那单也说得出是哪一单）。
        if payload == nil, let id = submitted.jobID { payload = .object(["skystudio_job_id": .string(id)]) }
        AIJobs.shared.finish(job, status, message: message, detail: payload)
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
    private func advance(to phase: FalJobPhase) {
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
