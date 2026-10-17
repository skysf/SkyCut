import Combine
import Foundation
import SrtFlowCore

// MARK: - AI 那一面全 App 一份的东西：看得见还是后台、要用户动手的那句话、要用户点头的问题；每个工程的「这一轮」从这里领
//
// 管什么：`viewMode`；提示条上要用户动手的那一句（`hint`）和要用户点头的问题（`question`，两个按钮，**不弹模态框**）—— 这两样只有
// 横幅订阅（`@Published`）；每个工程一份的「这一轮」（`AIRound`，2026-10-17 起，docs/plans/2026-10-17-multi-project-ai-editing.md 板 4、
// E 节）按短 id 发出去。产品口径见 docs/plans/2026-09-27-mcp.md 第 7、9、10 条，长期约束见 docs/architecture/ai-control-mcp.md 第五节。
// 不管什么：一轮怎么算、停止之后拒绝多久（AIRound）；工具怎么做（AI*Tools）、调用怎么排队（AIToolRouter）。
//
// 提示和问题全 App 一份、每个工程窗口的横幅都摆（谁在看哪个窗口都看得见）；问题回答一次就算数。

@MainActor
final class AISession: ObservableObject {
    static let shared = AISession()

    /// 要用户动手的那一句（比如「在弹出的窗口里点下载」）。有它的时候，正在剪的那个工程的横幅先显示它。
    @Published private(set) var hint: String?
    /// 要用户点头才做的事（花钱超了每日上限、没登记单价的模型）：提示条上问、两个按钮。**不弹模态框**（方案第 9、10 条）。
    @Published private(set) var question: Question?

    struct Question: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let allowTitle: String
        let declineTitle: String
        /// 是谁问的（任务号）：那个任务被取消时把问题一起收回。
        let owner: String
    }

    private var pendingQuestions: [(question: Question, continuation: CheckedContinuation<Bool, Never>)] = []

    /// 看得见（默认）还是后台（方案第 7 条）：后台时 SrtFlow 不摆窗口、不跟着选中 / 挪播放头，改动照样进工程、照样能 ⌘Z。
    /// 这次运行里一直有效，App 重开回到看得见。
    enum ViewMode: String {
        case visible, background
    }

    private(set) var viewMode: ViewMode = .visible

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
    }

    static let roundIdleSeconds = 30.0
    static let stopQuietSeconds = 10.0

    /// 每个工程的「这一轮」（短 id → 那一份）。
    private var rounds: [String: AIRound] = [:]

    private init() {}

    /// 这个工程的「这一轮」（第一次问时建）。
    func round(for project: VideoEditProject) -> AIRound {
        if let round = rounds[project.shortID] { return round }
        let round = AIRound(projectID: project.shortID)
        rounds[project.shortID] = round
        return round
    }

    /// 工程关掉了：它那一份不再留着（短 id 不会再发给别的工程）。
    func forgetRound(of project: VideoEditProject) {
        rounds[project.shortID] = nil
    }

    func setHint(_ text: String?) {
        if hint != text { hint = text }
    }

    /// 在提示条上问用户一句、等他点「允许」（true）或「不要」（false）。同时有几个问题就一个个问。
    /// 用户按停止、或者问的那个任务被取消（`withdrawQuestions`），都算「不要」。
    func ask(_ text: String, allow: String, decline: String, owner: String) async -> Bool {
        let question = Question(text: text, allowTitle: allow, declineTitle: decline, owner: owner)
        return await withCheckedContinuation { continuation in
            pendingQuestions.append((question, continuation))
            if self.question == nil { self.question = question }
        }
    }

    /// 用户按了提示条上的一个按钮。
    func answer(_ allow: Bool) {
        guard !pendingQuestions.isEmpty else { return }
        resolveFirst(allow)
    }

    /// 这个任务问的问题都收回（算「不要」）：任务被取消了，问题就不该还挂在条上。
    func withdrawQuestions(owner: String) {
        let owned = pendingQuestions.filter { $0.question.owner == owner }
        pendingQuestions.removeAll { $0.question.owner == owner }
        for pending in owned { pending.continuation.resume(returning: false) }
        question = pendingQuestions.first?.question
    }

    private func resolveFirst(_ allow: Bool) {
        let first = pendingQuestions.removeFirst()
        question = pendingQuestions.first?.question
        first.continuation.resume(returning: allow)
    }

    /// 客户端报的名字多半是内部代号，换成人认得的。
    static func displayName(for client: String) -> String {
        let lowered = client.lowercased()
        if lowered.contains("claude-code") || lowered.contains("claude code") { return "Claude Code" }
        if lowered.contains("claude") { return "Claude" }
        if lowered.contains("codex") { return "Codex" }
        if lowered.contains("cursor") { return "Cursor" }
        if lowered.contains("chatgpt") || lowered.contains("openai") { return "ChatGPT" }
        return client
    }
}
