import Combine
import Foundation

// MARK: - 工具栏任务入口的轻量汇总
// 只订阅两份活动清单和它们的任务；只有汇总 / 分组变化才叫醒入口，不订阅工程或播放器。
// 每行自己订阅任务的细节；处理计时只在浮层打开时运行。
@MainActor
final class CloudTasksActivity: ObservableObject {
    static let shared = CloudTasksActivity()
    @Published private(set) var grouping = CloudTaskGrouping(entries: [])
    var summary: CloudTaskSummary { grouping.summary }
    private(set) var generations: [SkyStudioMediaStatus] = []
    private(set) var upscales: [UpscaleJob] = []
    private var lists: AnyCancellable?
    private var children: [AnyCancellable] = []
    private var refreshScheduled = false

    /// 只在起任务时截取身份；之后不能按当前焦点或同一对象换过的内容重新认领。
    static func owner(of project: VideoEditProject) -> CloudTaskOwner {
        CloudTaskOwner(generation: project.documentGeneration, token: AIProjectBinding.token(generation: project.documentGeneration),
                       shortID: project.shortID, title: project.projectName)
    }

    static func project(for owner: CloudTaskOwner) -> VideoEditProject? {
        OpenProjects.shared.all.first { $0.documentGeneration == owner.generation }
    }

    private init() {
        let generation = SkyStudioGenerationActivity.shared
        lists = generation.$runs.combineLatest(UpscaleActivity.shared.$jobs)
            .sink { [weak self] runs, jobs in
                self?.bind(generations: runs, upscales: jobs)
            }
    }

    private func bind(generations: [SkyStudioMediaStatus], upscales: [UpscaleJob]) {
        self.generations = generations
        self.upscales = upscales
        children = generations.map { run in
            run.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
        } + upscales.map { job in
            job.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // @Published 先通知再赋值：下一轮读，不能把阶段 / 金额一直落后一拍。
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// MCP 随时现取，不能等下一拍 @Published 才得到本次调用结束时的阶段。
    func snapshot() -> CloudTaskGrouping {
        let entries = generations.map { run in
            CloudTaskGrouping.Entry(owner: run.owner, task: .init(id: run.id, active: run.issue == nil,
                queued: !run.waitingForRefund && run.progress?.phase.step == .queued,
                attention: run.issue != nil, credits: run.credits))
        } + upscales.map { job -> CloudTaskGrouping.Entry in
            let active: Bool
            let queued: Bool
            let attention: Bool
            let completed: Bool
            switch job.state {
            case .running(let progress): active = true; queued = progress.phase.step == .queued; attention = false; completed = false
            case .done: active = false; queued = false; attention = false; completed = true
            case .failed: active = false; queued = false; attention = true; completed = false
            case .cancelled(let stop): active = false; queued = false; attention = stop != .nothingCharged; completed = false
            }
            return .init(owner: job.owner, task: .init(id: job.id, active: active, queued: queued, attention: attention,
                credits: job.request.credits, completed: completed))
        }
        return CloudTaskGrouping(entries: entries)
    }

    private func refresh() {
        let next = snapshot()
        if next != grouping { grouping = next }
    }
}
