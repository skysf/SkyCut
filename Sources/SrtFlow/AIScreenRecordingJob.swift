import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - AI 起的一段录制：任务号、录到哪了、结局怎么写
//
// 管什么：record_screen 的录制在 AIJobs 里那一条（get_job 看状态、录了几秒、在等用户做什么；cancel_job / 横幅上的停止 =
// 停下来、留着）、到点自己停（duration）、结局写给 AI（文件、片段 id、残缺的原因、下一步）、落地那一下的附带事
// （算这一轮的一处改动、没存过的工程存一下）。入轨那一次 perform 包一步撤销由会话的 landing 管（AIScreenRecordingTool 给）。
// AI 去停一段手动起的录制、去处置用户的残缺结果时，也临时挂一个它来收结局。
// 不管什么：怎么录（ScreenRecordingCoordinator）、参数（AIScreenRecordingRequest）。

@available(macOS 15.0, *)
@MainActor
final class AIScreenRecordingJob: ScreenRecordingObserver {
    private(set) var job: AIJobs.Job!
    private let project: VideoEditProject
    private let sourceDescription: String
    private let duration: Double?
    private let isDrag: Bool
    /// 在等用户做的事（允许麦克风）；nil = 没在等。拖区域的那句按协调者的状态现算（`waitingText`）。
    var waiting: String?
    /// 开录之前就知道的提醒（麦克风没授权所以没录……），写进结局。
    var notes: [String] = []
    private(set) var startedAt: Date?
    private(set) var hasEnteredCoordinator = false
    private var completionDetails: [String: JSONValue] = [:]

    func enteredCoordinator() { hasEnteredCoordinator = true }

    init(project: VideoEditProject, sourceDescription: String, duration: Double? = nil, isDrag: Bool = false) {
        self.project = project
        self.sourceDescription = sourceDescription
        self.duration = duration
        self.isDrag = isDrag
        job = AIJobs.shared.start(
            .screenRecording, progress: { nil },
            liveDetail: { [weak self] in self?.liveDetail() ?? [:] },
            waitingForUser: { [weak self] in self?.waitingText() },
            // 取消 = 停下来、留着：录下来的东西从不扔（docs/plans/2026-10-03-screen-recording-mcp.md 第 11 条）。
            // 只停自己这一段 —— 用户这会儿手动开的另一段不归这个任务管；还没交给协调者（在等麦克风授权）就不开了。
            cancel: { [weak self] in
                guard let self else { return }
                if self.isCurrentSession {
                    Task { @MainActor in await ScreenRecordingCoordinator.shared.stop(cause: AICallContext.current == nil ? .activity : .cancelJob) }
                } else if self.startedAt == nil {
                    self.cancelBeforeStart(cause: AICallContext.current == nil ? .activity : .cancelJob)
                }
            }
        )
    }

    /// 协调者手里的会话还是不是这个任务的。
    var isCurrentSession: Bool { ScreenRecordingCoordinator.shared.session.observer === self }

    /// 等到真开录、或者要用户动手、或者结束了（start 用：开录之后马上回去，AI 好接着操作电脑）。
    func waitUntilUnderway(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while job.status == .running, startedAt == nil, waitingText() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func waitingText() -> String? {
        if let waiting { return waiting }
        if isDrag, isCurrentSession, case .choosingSource = ScreenRecordingCoordinator.shared.state {
            return "Ask the user to drag the area to record on the screen and press Record (Escape cancels)."
        }
        return nil
    }

    private func liveDetail() -> [String: JSONValue] {
        let coordinator = ScreenRecordingCoordinator.shared
        var detail: [String: JSONValue] = ["source": .string(sourceDescription)]
        guard isCurrentSession else { return detail }
        detail["state"] = .string(AIScreenRecordingWords.state(coordinator.state))
        if case .recording(let at) = coordinator.state { detail["recorded_seconds"] = .number(Date().timeIntervalSince(at).rounded()) }
        if case .countingDown(let remaining) = coordinator.state { detail["countdown"] = .number(Double(remaining)) }
        if let duration { detail["stops_after_seconds"] = .number(duration) }
        return detail
    }

    /// 没开成（协调者忙、参数在开录前才发现不对）：直接记失败。
    func fail(_ message: String) {
        finishBeforeStart(status: .failed, cause: .setupError, reason: message)
    }

    /// 只取消尚未交给协调者的尝试；已开始 / 已结束的录制不由这条路改写。
    func cancelBeforeStart(cause: ScreenRecordingReceipt.Stop = .mcp) {
        guard !hasEnteredCoordinator, startedAt == nil else { return }
        finishBeforeStart(status: .cancelled, cause: cause, reason: nil)
    }

    private func finishBeforeStart(status: ScreenRecordingReceipt.Status, cause: ScreenRecordingReceipt.Stop, reason: String?) {
        guard job.status == .running else { return }
        waiting = nil
        let receipt = ScreenRecordingReceipt(
            id: "pending-" + job.id, jobID: job.id, ownerSession: job.session, status: status, stop: cause,
            projectID: project.shortID, projectName: project.projectName, projectGeneration: project.documentGeneration,
            background: OpenProjects.shared.isHeadless(project), reason: reason
        )
        ScreenRecordingFeedback.shared.publish(receipt)
        AIJobs.shared.finish(job, status.jobStatus, message: receipt.message, detail: receipt.json)
    }

    // MARK: ScreenRecordingObserver

    /// 发布回执前完成落地的附带事，工程名取自动保存后的真实名字；UI 和 MCP 使用同一份最终身份。
    func prepareCompletion(_ outcome: ScreenRecordingOutcome) {
        guard job.status == .running, case .added = outcome else { return }
        AISession.shared.round(for: project).noteChange()
        completionDetails = AIProjectTools.saveIfNeverSaved(project, after: .ok([:], changed: true)).payload.objectValue ?? [:]
    }

    func recordingStarted(session: UUID, alreadyRecorded: TimeInterval) {
        startedAt = Date()
        guard let duration else { return }
        // 文件在这一刻之前就开始写了：只等剩下的那一截（见协议的说明）。
        let remaining = max(0, duration - alreadyRecorded)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            let coordinator = ScreenRecordingCoordinator.shared
            guard let self, self.job.status == .running, self.isCurrentSession, case .recording = coordinator.state else { return }
            await coordinator.stop(cause: .duration)
        }
    }

    func recordingEnded(_ outcome: ScreenRecordingOutcome, receipt: ScreenRecordingReceipt) {
        guard job.status == .running else { return }
        waiting = nil
        var detail = receipt.json.objectValue ?? [:]
        detail["source"] = .string(sourceDescription)
        if !notes.isEmpty { detail["note"] = .string(notes.joined(separator: " ")) }
        if case .added = outcome {
            detail["next_step"] = "It is on the timeline (one undo step). Check it with look; use edit_clip to trim if needed."
            detail.merge(completionDetails) { current, _ in current }
            AIJobs.shared.finish(job, receipt.status.jobStatus, message: receipt.message, detail: .object(detail))
        } else {
            if receipt.waitingForDecision {
                detail["next_step"] = "Use record_screen action=resolve decision=add or keep."
            }
            AIJobs.shared.finish(job, receipt.status.jobStatus, message: receipt.message, detail: .object(detail))
        }
    }
}
