import Foundation

// MARK: - 一次只能做一个的活，给 AI 排队（导出、转写 / 生成字幕、翻译）
//
// 管什么：导出器只有一个（`VideoEditExporter.shared`）、转写只有一个串行槽（`TranscriptionTask`）、翻译只有一个宿主（`TranslationJobCoordinator`）。
// 以前 AI 遇上占着的直接报「已经在做了」，几个子代理剪几个工程时一个个撞墙、自己轮询重试。现在 AI 起的这三样**排队**：
// 这条道空着就马上做，占着就排上、照样回任务号，`get_job` 报 `status: queued` 和 `queue_position`（1 = 下一个），先来先做
// （docs/plans/2026-10-17-multi-project-ai-editing.md 板 6、K 节）。
// 不管什么：活本身怎么做（各工具的 start 闭包）、任务的账（AIJobs）。
//
// 界面上起的（导出面板、生成字幕面板）不进这条队：它们照旧在道空着时直接开始（按钮在占着时是灰的）；队里的等它们做完再接着排。
// 排队的导出用的是**调用那一刻**的时间线（之后的改动不进这一次成片）；分镜（`shots`）本来就在 MediaReadQueue 上排着，这里不管。

@MainActor
final class AIWorkQueue {
    static let shared = AIWorkQueue()

    enum Lane: String {
        case export, transcription, translation
    }

    private struct Entry {
        let jobID: String
        let lane: Lane
        let start: @MainActor () -> Void
    }

    private var waiting: [Entry] = []
    /// 每条道上 AI 起的、正在做的那一个（任务号）：它的任务还没结束，这条道就不算空 —— 有的活起步是异步的
    /// （翻译先起一个 Task），起完那一下导出器 / 槽还没显出占着，光看它们会接连起两个。
    private var active: [Lane: String] = [:]
    private var pump: Task<Void, Never>?

    private init() {}

    /// 这条道空着、前面也没人排就马上做（回 nil）；否则排上，回排在第几（1 = 下一个）。
    @discardableResult
    func submit(_ lane: Lane, jobID: String, start: @escaping @MainActor () -> Void) -> Int? {
        if laneIsFree(lane), !waiting.contains(where: { $0.lane == lane }) {
            active[lane] = jobID
            start()
            return nil
        }
        waiting.append(Entry(jobID: jobID, lane: lane, start: start))
        schedulePump()
        return position(of: jobID)
    }

    /// 还在排的话排在这条道的第几（1 = 下一个）；已经开始了、或者不在队里是 nil。
    func position(of jobID: String) -> Int? {
        guard let entry = waiting.first(where: { $0.jobID == jobID }) else { return nil }
        let ahead = waiting.prefix { $0.jobID != jobID }.filter { $0.lane == entry.lane }.count
        return ahead + 1
    }

    /// 还没开始就从队里拿掉（cancel_job、停止）：回 true。已经开始了的回 false，由调用方去停那件正在做的事。
    func withdraw(_ jobID: String) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.jobID == jobID }) else { return false }
        waiting.remove(at: index)
        return true
    }

    /// 这条道此刻能不能起新的：AI 上一个起的做完了，界面上也没在做。
    private func laneIsFree(_ lane: Lane) -> Bool {
        if let id = active[lane], AIJobs.shared.job(id)?.status == .running { return false }
        active[lane] = nil
        return Self.isFree(lane)
    }

    /// 那件东西（导出器、转写的槽、翻译的宿主）此刻空不空。
    static func isFree(_ lane: Lane) -> Bool {
        switch lane {
        case .export:
            return !VideoEditExporter.shared.isExporting
        case .transcription:
            if #available(macOS 26.0, *) { return !TranscriptionTask.shared.isRunning }
            return true
        case .translation:
            if #available(macOS 15.0, *), case .running = TranslationJobCoordinator.shared.phase { return false }
            return true
        }
    }

    /// 有人在排就每半秒看一眼：哪条道空了，起那条道排在最前面的（界面上起的活也会占道，没有统一的「做完了」通知可听，看一眼最稳）。
    private func schedulePump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while let self, !self.waiting.isEmpty {
                for lane in [Lane.export, .transcription, .translation] where self.laneIsFree(lane) {
                    guard let index = self.waiting.firstIndex(where: { $0.lane == lane }) else { continue }
                    let next = self.waiting.remove(at: index)
                    self.active[lane] = next.jobID
                    next.start()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.pump = nil
        }
    }
}

/// 一件排队的活起没起（进度、取消都要分「还在排」和「正在做」）。各工具建任务时带一个，start 闭包里置上 `started`。
@MainActor
final class AIQueuedWork {
    var started = false
    weak var job: AIJobs.Job?

    /// cancel_job / 停止：还在排就从队里拿掉、记成取消（`withdrawn` 收拾这件活占着的东西）；已经在做就交给 `stop` 去停那件事。
    func cancel(withdrawn: () -> Void = {}, stop: () -> Void) {
        guard let job else { return }
        if AIWorkQueue.shared.withdraw(job.id) {
            withdrawn()
            AIJobs.shared.finish(job, .cancelled, message: "Cancelled while waiting in line; nothing was started.")
        } else if started {
            stop()
        }
    }
}
