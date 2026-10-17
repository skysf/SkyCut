import Combine
import Foundation
import SrtFlowCore

// MARK: - AI 那一面全 App 一份的东西：看得见还是后台、要用户动手的那句话、要用户点头的问题；每个工程的「这一轮」从这里领
//
// 管什么：`viewMode`；提示条上要用户动手的那一句（`hint`：macOS 的下载框、钥匙串授权框 —— 苹果不给代点，只能请用户点；只有横幅订阅）；
// 每个工程一份的「这一轮」（`AIRound`，2026-10-17 起，docs/plans/2026-10-17-multi-project-ai-editing.md 板 4、E 节）按短 id 发出去。
// 要用户点头的事（花钱超了额度、删文件、读别处的文件）一律走聊天里的确认码（`AIConfirmations`，板 9），不在提示条上问。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 7、9、10 条，长期约束见 docs/architecture/ai-control-mcp.md 第五节。
// 不管什么：一轮怎么算、停止之后拒绝多久（AIRound）；工具怎么做（AI*Tools）、调用怎么排队（AIToolRouter）。
//
// 提示全 App 一份、每个工程窗口的横幅都摆（谁在看哪个窗口都看得见）。

@MainActor
final class AISession: ObservableObject {
    static let shared = AISession()

    /// 要用户动手的那一句（比如「在弹出的窗口里点下载」）。有它的时候，正在剪的那个工程的横幅先显示它。
    @Published private(set) var hint: String?
    /// 看得见（默认）还是后台（方案第 7 条）：后台时 SrtFlow 不摆窗口、不跟着选中 / 挪播放头，改动照样进工程、照样能 ⌘Z。
    /// 这次运行里一直有效，App 重开回到看得见。2026-10-17 起**按工程记**，另外每个会话有一个默认（之后开 / 建 / 收下的工程照它；
    /// docs/plans/2026-10-17-multi-project-ai-editing.md F 节）。没人设过的（用户自己的工程）是看得见。
    enum ViewMode: String {
        case visible, background
    }

    /// 每个会话的默认看法（会话号 → 看法）。
    private var sessionViews: [String: ViewMode] = [:]
    /// 每个工程的看法（短 id → 看法）。
    private var projectViews: [String: ViewMode] = [:]

    func viewMode(for project: VideoEditProject) -> ViewMode { projectViews[project.shortID] ?? .visible }

    func defaultViewMode(session: String) -> ViewMode { sessionViews[session] ?? .visible }

    func setViewMode(_ mode: ViewMode, for project: VideoEditProject) { projectViews[project.shortID] = mode }

    func setDefaultViewMode(_ mode: ViewMode, session: String) { sessionViews[session] = mode }

    /// 主窗口里那个工程：哪个会话在它的哪一次打开上已经摆过窗口了（方案板 3：开工程时摆一次 —— 开 / 建进主窗口、会话第一次在它上面做
    /// 要摆剪辑页的事、set_view visible）。键 = 短 id + 打开的代号 + 会话号：内容换了、换了会话剪，各算一次「开」。
    private var shown: Set<String> = []

    /// 记下「这个会话在这个工程的这一次打开上摆过窗口了」；第一次回 true（该摆）。
    func claimFirstShow(of project: VideoEditProject, session: String) -> Bool {
        shown.insert("\(project.shortID)#\(project.documentGeneration)#\(session)").inserted
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

    /// 工程关掉了：它那一份「这一轮」和看法不再留着（短 id 不会再发给别的工程）。
    func forgetRound(of project: VideoEditProject) {
        rounds[project.shortID] = nil
        projectViews[project.shortID] = nil
    }

    func setHint(_ text: String?) {
        if hint != text { hint = text }
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
