import Combine
import Foundation
import SrtFlowCore

// MARK: - 一个工程上 AI 的「这一轮」：谁在剪、改了几处、用户按了停止没有
//
// 管什么：横幅上那点状态（`@Published`，只有这个工程窗口里的横幅订阅）、「撤销这一轮」的快照、停止之后拒绝调用的那段时间。
// **每个工程一份**（2026-10-17 起，docs/plans/2026-10-17-multi-project-ai-editing.md 板 4、E 节）：剪 5 条时停一条，别的照剪；
// 撤销这一轮只退这个工程上这一轮的改动。由 `AISession.round(for:)` 发、按短 id 认（短 id 这一次运行里不重用）。
// 不管什么：看得见还是后台、要用户点头的问题和要用户动手的那句话（全 App 一份，`AISession`）；工具怎么做（AI*Tools）。
// 产品口径：docs/plans/2026-09-27-mcp.md 第 9、10 条；长期约束：docs/architecture/ai-control-mcp.md 第五节。
//
// **「一轮」按时间划分**：服务器看不到对话，只能这么判断 —— AI 开始改这个工程时开一轮，连续 `AISession.roundIdleSeconds` 秒
// 没有新调用就算这一轮结束（横幅换成「改了 N 处 · 撤销这一轮」）。这个会话不碰工程的调用（`get_job` 等导出）也算还在剪。
//
// **停止**：用户按下之后，AI 接下来落在这个工程上的调用一律回「用户按了停止」，直到它安静 `AISession.stopQuietSeconds` 秒 ——
// AI 收到拒绝会停下来问用户，用户再说话时已经过了这段时间，新的一轮照常开。这个工程在跑的任务当场取消（导出、生成字幕、翻译、
// upscale、生成；这个会话不碰工程的任务记在它最后打开的工程上，停那个工程时一起停）。
//
// **Saved versions** (2026-11-17, docs/architecture/project-versions.md): the first change of a round saves what the project looked
// like when the round began (`beforeVersion`, the id the AI and the banner name); the end of the round (idle or Stop) saves what it
// looks like then; "Undo This Round" saves the state it leaves first. Each only when the project changed since its newest version
// (ProjectVersionStore). In-memory "Undo This Round" stays as it was; the versions are what survive a restart and older rounds.

@MainActor
final class AIRound: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case finished
        case stopped
    }

    /// 这一轮落在哪个工程上（短 id）。
    let projectID: String

    @Published private(set) var phase: Phase = .idle
    /// 横幅上的客户端名字（「Claude」「Codex」……）。
    @Published private(set) var clientName = ""
    /// 这一轮改了几处（每个改动工程的调用算一处）。
    @Published private(set) var changeCount = 0
    /// The saved version that holds this round's starting point (v3), once the round's first change saved it. nil before that, and
    /// when there is none (the project was empty when the round began, or it could not be written).
    @Published private(set) var beforeVersion: String?
    /// Saving the starting point is done (or impossible); a never-saved project is retried once the router saved it.
    private var beforeVersionSettled = false

    private var snapshot: TimelineState?
    /// 快照属于工程的哪一次打开（主窗口那个的内容被换掉了，快照就没意义了）。
    private var snapshotGeneration: Int?
    private var lastCallAt = Date.distantPast
    private var idleTask: Task<Void, Never>?

    init(projectID: String) {
        self.projectID = projectID
    }

    /// 这一轮的快照是不是这个工程的这一次打开（代号全 App 不重号，`DocumentGenerations`）。
    func canUndoRound(_ project: VideoEditProject) -> Bool {
        snapshot != nil && changeCount > 0 && snapshotGeneration == project.documentGeneration
    }

    // MARK: 调用进来

    /// 用户按了停止、AI 还在连续调用这个工程：回这一句。安静够久了就放行（新的一轮）。
    func refusalAfterStop() -> String? {
        guard phase == .stopped else { return nil }
        let quiet = Date().timeIntervalSince(lastCallAt)
        lastCallAt = Date()
        if quiet < AISession.stopQuietSeconds {
            return "The user pressed Stop on project \(projectID) in SkyCut. Nothing was changed. "
                + "Stop calling tools for it and ask the user what to do next."
        }
        phase = .idle
        return nil
    }

    /// 一个落在这个工程上的调用进来了。
    func noteCall(client: String?) {
        lastCallAt = Date()
        if let client, !client.isEmpty { clientName = AISession.displayName(for: client) }
        if phase == .working { scheduleRoundEnd() }
    }

    /// 剪它的会话还在调用（不碰工程的：等导出、看文件……）：这一轮还没完。
    func noteActivity() {
        if phase == .working { scheduleRoundEnd() }
    }

    /// 要改工程之前调：没在一轮里就开一轮，先把此刻的时间线存下来（「撤销这一轮」退回到这里）。
    func beginIfNeeded(project: VideoEditProject) {
        guard phase != .working else { return }
        startOver(from: project)
        phase = .working
        scheduleRoundEnd()
    }

    func noteChange() {
        changeCount += 1
        settleBeforeVersion()
    }

    /// The round's first change: save the starting point as a version (only when the project changed since its newest version;
    /// that one is reused otherwise). Called again by the router after it saved a never-saved project (AIRoundVersions.reporting).
    func settleBeforeVersion() {
        guard !beforeVersionSettled, changeCount > 0, let snapshot, let snapshotGeneration,
              let project = OpenProjects.shared.project(shortID: projectID),
              project.documentGeneration == snapshotGeneration else { return }
        let saved = ProjectVersionStore.for(project).save(snapshot, kind: .beforeRound)
        // Untitled: no place for versions yet, try again once it has a file. Empty or failed: no starting version this round.
        guard saved != .notSaved(.untitled) else { return }
        beforeVersion = saved.version?.id
        beforeVersionSettled = true
    }

    /// AI 刚开 / 建好这个工程（或者往主窗口里装了别的内容）：快照换成它此刻的样子，「撤销这一轮」只退之后的改动。
    func rebase(project: VideoEditProject) {
        startOver(from: project)
    }

    private func startOver(from project: VideoEditProject) {
        snapshot = project.state
        snapshotGeneration = project.documentGeneration
        changeCount = 0
        if beforeVersion != nil { beforeVersion = nil }  // published: the toolbar observes this round
        beforeVersionSettled = false
    }

    // MARK: 用户的按钮

    func stop() {
        let changed = phase == .working && changeCount > 0
        phase = .stopped
        lastCallAt = Date()
        idleTask?.cancel()
        AIJobs.shared.cancel(stoppingWith: projectID)
        if changed { saveEndVersion() }
    }

    /// 把工程退回这一轮开始之前（一步，可以再 ⌘Z 回来）。**原样**换回快照：不走 `perform`，那里收尾的磁吸 / 联动会把
    /// 快照再改一遍（docs/bugfixes/2026-10-02-undo-round-repacks-v1.md）。
    @discardableResult
    func undoRound(project: VideoEditProject) -> Bool {
        guard canUndoRound(project), let snapshot else { return false }
        // What the round made stays reachable after a restart: it becomes a version before the project goes back.
        ProjectVersionStore.for(project).save(project.state, kind: .beforeGoingBack)
        project.restoreTimeline(snapshot)
        changeCount = 0
        if phase == .finished { phase = .idle }
        return true
    }

    func dismiss() {
        guard phase != .working else { return }
        phase = .idle
    }

    private func scheduleRoundEnd() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AISession.roundIdleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.finishRound()
        }
    }

    /// No call for `roundIdleSeconds`: the round is over. A round that changed the project saves what it looks like now.
    func finishRound() {
        guard phase == .working else { return }
        phase = changeCount > 0 ? .finished : .idle
        if changeCount > 0 { saveEndVersion() }
    }

    /// The round's end state as a version: only for the document the round began on (the user may have opened another file into
    /// the main window meanwhile), and only when it differs from the newest version.
    private func saveEndVersion() {
        guard let project = OpenProjects.shared.project(shortID: projectID),
              project.documentGeneration == snapshotGeneration else { return }
        ProjectVersionStore.for(project).save(project.state, kind: .afterRound)
    }
}
