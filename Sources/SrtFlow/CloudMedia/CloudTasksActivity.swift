import Combine
import Foundation

// MARK: - 工具栏任务入口的轻量汇总
// 只订阅两份活动清单和它们的任务，不读工程 / 播放器；只有汇总变化才叫醒入口。
// 每行自己订阅任务的细节；处理计时只在浮层打开时运行。
@MainActor
final class CloudTasksActivity: ObservableObject {
    static let shared = CloudTasksActivity()
    @Published private(set) var summary = CloudTaskSummary(entries: [])
    private(set) var generations: [SkyStudioMediaStatus] = []
    private(set) var upscales: [UpscaleJob] = []
    private var lists: AnyCancellable?
    private var children: [AnyCancellable] = []
    private var refreshScheduled = false

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

    private func refresh() {
        let entries = generations.map { run in
            CloudTaskSummary.Entry(id: run.id, active: run.issue == nil,
                queued: !run.waitingForRefund && run.progress?.phase.step == .queued,
                attention: run.issue != nil, credits: run.credits)
        } + upscales.map { job -> CloudTaskSummary.Entry in
            let active: Bool
            let queued: Bool
            let attention: Bool
            switch job.state {
            case .running(let progress): active = true; queued = progress.phase.step == .queued; attention = false
            case .done: active = false; queued = false; attention = false
            case .failed: active = false; queued = false; attention = true
            case .cancelled(let stop): active = false; queued = false; attention = stop != .nothingCharged
            }
            return .init(id: job.id, active: active, queued: queued, attention: attention, credits: job.request.credits)
        }
        let next = CloudTaskSummary(entries: entries)
        if next != summary { summary = next }
    }
}
