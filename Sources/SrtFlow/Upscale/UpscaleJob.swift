import Foundation

// MARK: - 用户点了「开始」之后的那个任务：记账 → 取 Key → 跑流水线 → 按实收对账
//
// 管什么：面板起的，面板上的报价（/quote 的积分）就是用户的确认（upscale 方案第 10 条：记进积分的账、超限只标红不拦），不再问；
// AI 起的（upscale_clip）在起任务之前按每日积分上限把关过了（SkyStudioJobGate.decide，超了是聊天里的确认码），任务拿到已经记上的那一笔（`Approval.ai`）。
// 取 Sky Studio 的 Key：面板起的可以弹钥匙串授权框（用户刚点了按钮，`keyPrompt` 让界面说一句），AI 起的不弹（读不到就请用户去设置里点「允许…」）；
// 跑 `UpscalePipeline`，阶段（含上传 / 下载的字节比例、这一阶段过了多久）发给界面；做完按实收（credits_charged）改账。
// 没花出去的退回账上：没交上（裁、传的时候停了 / 出错）、排队中取消了、Sky Studio 说没做成（它自己退钱）。账的那一笔是 `SkyStudioHeldCredits`（和生成共用）。
// 交上之后停不下来的（已经开始了、取消没送到）照实说：积分花了，成品照样进用户的 Sky Studio 作品库。
// 做完**不替换**：对比窗口里用户点了 Replace 才换（upscale 方案第 15 条）。2026-10-28 起走 Sky Studio（收费方案第 6 刀），之前走 fal。
// 不管什么：裁 / 传 / 等 / 下 / 封声（UpscalePipeline）、换源（VideoEditProject+Upscale）、界面。

@MainActor
final class UpscaleJob: ObservableObject, Identifiable {
    enum State: Equatable {
        /// 跑着：阶段、这一阶段从什么时候起、这一档通常要多久（CloudJobProgress）。
        case running(CloudJobProgress)
        case done
        case failed(String)
        /// 停下来了：积分花没花（排队中 / 交上之前停的没花；已经开始的花了，成品照样进作品库）。
        case cancelled(SkyStudioJobError.Stop)
    }

    /// 花钱怎么把关：面板上的报价就是用户的确认（直接记账）；AI 起的（upscale_clip）在起任务之前按每日积分上限把关过了
    /// （SkyStudioJobGate.decide），这里拿到的是已经记上的那一笔。
    enum Approval {
        case panel
        case ai(SkyStudioJobGate.Reservation)
    }

    let id = UUID()
    let request: UpscaleRequest
    /// 做的是哪一段（状态行上「Upscaling <名字> with …」）。
    let title: String
    /// 范围被盖住、做完要换的段。
    let clipIDs: [UUID]
    /// 这段所在的工程（做完换源时核对还是不是它）。
    let projectGeneration: Int
    let approval: Approval

    @Published private(set) var state: State
    @Published private(set) var outcome: UpscaleOutcome?
    /// macOS 正在问要不要让 SkyCut 用钥匙串里的 Key（只有面板起的会问；界面提醒用户点「始终允许」）。
    @Published private(set) var keyPrompt = false
    /// 做完（拿到文件）时叫一声：UpscaleActivity 用它弹对比窗口，upscale_clip 用它直接换源。
    var onFinished: ((UpscaleJob) -> Void)?
    /// 怎么结束都叫一声（done 在 onFinished 之后；failed / cancelled）：upscale_clip 用它把结局记给 AI 的任务。
    var onEnded: ((UpscaleJob) -> Void)?

    private var task: Task<Void, Never>?
    /// 记在本机积分账上的那一笔（没花出去退回、做完按实收换）。
    private var held: SkyStudioHeldCredits?
    /// 交上了没有（交上之后积分扣了，没做成服务器退）：回调在别的线程上，带锁。
    private let submitted = SkyStudioSubmission()
    /// Sky Studio 的任务号，交上了才有：upscale_clip 的 get_job 报给 AI（对账、找客服时说得出是哪一单，停不下来的那单也一样）。
    var skyStudioJobID: String? { submitted.jobID }

    init(request: UpscaleRequest, clipIDs: [UUID], projectGeneration: Int, title: String, approval: Approval = .panel) {
        self.request = request
        self.clipIDs = clipIDs
        self.projectGeneration = projectGeneration
        self.title = title
        self.approval = approval
        state = .running(CloudJobProgress(phase: .preparing, typicalSeconds: request.typicalSeconds))
    }

    static var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowUpscale", isDirectory: true) }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in await self.execute() }
    }

    func cancel() {
        // 只取消还在跑的：做完之后 `UpscaleActivity.remove`（换源、丢弃、AI 收尾）也会经过这里。
        guard case .running = state else { return }
        task?.cancel()
    }

    /// 「Topaz Starlight · 4K · 7.0 s」：确认码绑着它（SkyStudioJobGate）。
    static func summary(of request: UpscaleRequest) -> String {
        "\(request.tier.title) · \(request.target.label) · " + String(format: "%.1f s", request.range.duration)
    }

    private func execute() async {
        // 1. 账。
        switch approval {
        case .panel:
            // 面板上已经确认过，直接记上报价。
            held = .recording(request.credits)
        case .ai(let reservation):
            // AI 起的：起任务之前已经按每日上限把关、记上了（SkyStudioJobGate.decide）。
            held = SkyStudioHeldCredits(reservation)
        }
        guard !Task.isCancelled else { return end(.cancelled(.nothingCharged), refunding: true) }

        // 2. Key：面板起的可以弹授权框，AI 起的不弹。
        let mode: SkyStudioJobKey.Mode
        if case .panel = approval { mode = .prompting } else { mode = .silent }
        let keyResult = await SkyStudioJobKey.key(mode, willAsk: { [weak self] in self?.keyPrompt = true })
        keyPrompt = false
        let key: String
        switch keyResult {
        case .success(let found): key = found
        case .failure(let problem): return end(.failed(problem.message), refunding: true)
        }

        // 3. 流水线。
        let submitted = self.submitted
        do {
            let result = try await UpscalePipeline.run(
                request, api: SkyStudioAPI(), key: key, ffmpeg: MediaToolchain.shared.runtime?.url, workFolder: Self.workFolder,
                onSubmitted: { submitted.mark($0) }
            ) { [weak self] phase in
                Task { @MainActor in
                    guard let self, case .running(let progress) = self.state else { return }
                    self.state = .running(progress.advanced(to: phase))
                }
            }
            held?.settle(charged: result.creditsCharged)
            outcome = result
            state = .done
            onFinished?(self)
            onEnded?(self)
        } catch let error as SkyStudioJobError {
            switch error {
            case .stopped(let stop):
                end(.cancelled(stop), refunding: stop == .nothingCharged)
            case .failed:
                end(.failed(error.message), refunding: error.canRefund(beforeAccepted: !submitted.value))
            case .request, .badAnswer, .timedOut:
                // 交上之前出的错没花钱；交上之后断了的，活在服务器上照做、做完进作品库。
                end(.failed(error.message), refunding: error.canRefund(beforeAccepted: !submitted.value))
            }
        } catch is CancellationError {
            // 裁、传的时候停的没花钱；下载、封声的时候停的，活已经做完了（积分花了，成品在作品库里）。
            end(.cancelled(submitted.value ? .alreadyStarted : .nothingCharged), refunding: !submitted.value)
        } catch let error as UpscalePipelineError {
            end(.failed(error.message), refunding: !submitted.value)
        } catch let failure as SkyStudioFailure {
            end(.failed(SkyStudioJobError.request(failure).message), refunding: !submitted.value)
        } catch {
            end(.failed(error.localizedDescription), refunding: !submitted.value)
        }
    }

    private func end(_ final: State, refunding: Bool) {
        if refunding { held?.refund() }
        state = final
        onEnded?(self)
    }
}

/// 面板要为哪一段打开（右键菜单、检查器都走这里）。
struct UpscalePanelTarget: Identifiable, Equatable {
    let id: UUID
}

/// 对比窗口看什么：做完还没处理的任务（点替换才换源），或已经换过源的一段（原片 vs 现在用的）。
enum UpscaleCompareTarget: Identifiable, Equatable {
    case job(UpscaleJob)
    case clip(UUID)

    var id: String {
        switch self {
        case .job(let job): return "job-" + job.id.uuidString
        case .clip(let id): return "clip-" + id.uuidString
        }
    }

    static func == (lhs: UpscaleCompareTarget, rhs: UpscaleCompareTarget) -> Bool { lhs.id == rhs.id }
}

/// 正在做 / 做完还没处理的 upscale 任务，以及界面上要摆出来的面板和对比窗口（界面从这里读；切工程时清掉）。
@MainActor
final class UpscaleActivity: ObservableObject {
    static let shared = UpscaleActivity()
    @Published private(set) var jobs: [UpscaleJob] = []
    @Published var panel: UpscalePanelTarget?
    @Published var compare: UpscaleCompareTarget?

    /// `opensCompare`：面板起的做完先弹对比窗口（方案第 15 条）；AI 起的（upscale_clip）自己接 `onFinished` 直接换源，不弹。
    func add(_ job: UpscaleJob, opensCompare: Bool = true) {
        jobs.append(job)
        if opensCompare {
            job.onFinished = { [weak self] finished in
                // 已经在看别的就不抢。
                guard let self, self.jobs.contains(where: { $0.id == finished.id }), self.compare == nil else { return }
                self.compare = .job(finished)
            }
        }
        job.start()
    }

    func remove(_ job: UpscaleJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        if compare == .job(job) { compare = nil }
    }

    /// 这个原片有没有在做 / 做完还没处理的任务。
    func job(forOriginal url: URL) -> UpscaleJob? {
        jobs.first { $0.request.originalURL == url }
    }

    func present(panelFor clipID: UUID) { panel = UpscalePanelTarget(id: clipID) }

    /// 关 / 换一个工程时调：只作废**那个工程那一次打开**起的任务（工程代号全 App 不重号）；别的工程的照做。
    /// 面板和对比窗口各自只在自己的工程里摆（UpscalePresenter 按工程认），这里只收掉指着作废任务的那个对比窗口。
    func cancelAll(projectGeneration: Int) {
        let closing = jobs.filter { $0.projectGeneration == projectGeneration }
        for job in closing { job.cancel() }
        jobs.removeAll { $0.projectGeneration == projectGeneration }
        if case .job(let shown)? = compare, shown.projectGeneration == projectGeneration { compare = nil }
    }
}
