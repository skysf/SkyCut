import Foundation

// MARK: - 开着的工程（2026-10-17 起不再是单例）
//
// 管什么：App 里开着哪些剪辑工程、主窗口剪辑页里是哪一个（`primary`，用户的那一个）、菜单和拷贝粘贴作用在哪一个（`focused`）、
// 每个工程的短 id（AI 用的 p1、p2…）、工程的代号怎么发（`DocumentGenerations`：全 App 不重号）。
// 不管什么：一个工程里面的事（VideoEditProject）；工程窗口（下一刀）；AI 的会话归属和按工程排队（AI 那一层）。
//
// 为什么：以前工程是单例 `VideoEditProject.shared`、只有主窗口那一个。AI 一个会话同时剪几个工程
// （docs/plans/2026-10-17-multi-project-ai-editing.md）要先能开几个。这一刀只把单例拆掉、行为不变：开着的还只有主窗口那一个。
// 长期约束：docs/architecture/open-projects.md。

@MainActor @Observable
final class OpenProjects {
    static let shared = OpenProjects()

    /// 主窗口剪辑页里的那一个（用户的）。永远有一个：启动时是空的 Untitled，打开 / 新建工程是换它的内容（同以前）。
    private(set) var primary: VideoEditProject

    /// 开着的全部工程。现在只有主窗口那一个；工程窗口、后台工程是下一刀的事。
    var all: [VideoEditProject] { [primary] }

    /// 菜单（⌘S、拷贝粘贴）作用的那一个：键盘焦点所在的剪辑页的工程。现在只有主窗口的剪辑页。
    var focused: VideoEditProject { primary }

    /// 发过哪些短 id（下一个工程接着往下发）。
    @ObservationIgnored private var shortIDs = ProjectShortIDs()

    private init() {
        var ids = ProjectShortIDs()
        primary = VideoEditProject(shortID: ids.next())
        shortIDs = ids
    }
}

/// 工程的短 id：`p1`、`p2`……按开的先后发，这一次运行里不重用（关掉的号不再发给别人，免得 AI 拿旧号改到新工程上）。
struct ProjectShortIDs: Equatable {
    private(set) var issued = 0

    mutating func next() -> String {
        issued += 1
        return "p\(issued)"
    }
}

/// 工程代号（`VideoEditProject.documentGeneration`）从这里发：**全 App 一个计数，几个工程不重号**。
///
/// 代号被当作「这一个工程的这一次打开」的身份跨对象比较：AI 会话记着的工程（`AIProjectBinding.token`）、路由记的谁换了工程、
/// 「撤销这一轮」的快照、导出面板的标题、upscale 任务、录屏请求和崩溃恢复的记录。每个工程各从 0 数的话，两个工程会撞号，
/// 被判成同一个。
@MainActor
enum DocumentGenerations {
    private static var last = 0

    static func next() -> Int {
        last += 1
        return last
    }
}
