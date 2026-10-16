import AppKit
import Foundation

// MARK: - 开着的工程（2026-10-17 起不再是单例）
//
// 管什么：App 里开着哪些剪辑工程、主窗口剪辑页里是哪一个（`primary`，用户的那一个）、别的工程和它们的窗口（`others`，
// 各自一个 `ProjectWindowController`）、菜单和拷贝粘贴作用在哪一个（`focused`：键窗口是哪个工程的窗口）、每个工程的短 id
// （AI 用的 p1、p2…）、同一个文件只开一份、同时最多开几个、关一个工程怎么收拾、工程的代号怎么发（`DocumentGenerations`）。
// 不管什么：一个工程里面的事（VideoEditProject）；窗口本身（ProjectWindowController）；AI 的会话归属和按工程排队（AI 那一层）。
//
// 为什么：以前工程是单例 `VideoEditProject.shared`、只有主窗口那一个。AI 一个会话同时剪几个工程
// （docs/plans/2026-10-17-multi-project-ai-editing.md）要先能开几个。长期约束：docs/architecture/open-projects.md。

@MainActor @Observable
final class OpenProjects {
    static let shared = OpenProjects()

    /// 主窗口剪辑页里的那一个（用户的）。永远有一个：启动时是空的 Untitled，打开 / 新建工程是换它的内容（同以前）。
    private(set) var primary: VideoEditProject
    /// 主窗口以外开着的工程，按开的先后。现在每个都在自己的窗口里（后台工程是方案的第 ③ 刀）。
    private(set) var others: [VideoEditProject] = []
    /// 键窗口是哪个工程窗口（主窗口、别的窗口是 nil）。菜单据此亮灭、⌘S 存谁（工程窗口变成 / 不再是键窗口时更新）。
    private(set) var keyProjectWindow: VideoEditProject?

    /// 开着的全部（退出时每一个都要落定）。
    var all: [VideoEditProject] { [primary] + others }

    /// 菜单（⌘S、拷贝粘贴）作用的那一个：键窗口是工程窗口就是它的工程，否则是主窗口那个。
    var focused: VideoEditProject { keyProjectWindow ?? primary }

    /// 同时开着的最多几个（主窗口那个也算；方案板 2：每个看得见的工程背后是一个播放器 + 一个音频引擎）。
    static let limit = 8

    /// 发过哪些短 id（下一个工程接着往下发）。
    @ObservationIgnored private var shortIDs = ProjectShortIDs()
    @ObservationIgnored private var windows: [ObjectIdentifier: ProjectWindowController] = [:]
    /// 下一个工程窗口从哪儿层叠（0 = 第一个放正中）。
    @ObservationIgnored private var cascade = NSPoint.zero

    private init() {
        var ids = ProjectShortIDs()
        primary = VideoEditProject(shortID: ids.next())
        shortIDs = ids
        // 素材在工程开着的时候也可能被改名 / 挪走，去访达动文件必然让 App 失焦 —— 一激活就把每个开着的工程重核对一遍，
        // 块名和丢失提示当场跟上。挂在注册表上（一个观察者），工程关了不留观察者。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in for project in OpenProjects.shared.all { project.revalidateMediaLocations() } }
        }
    }

    /// 按短 id 找（AI 传的 `project`）。
    func project(shortID: String) -> VideoEditProject? {
        all.first { $0.shortID == shortID }
    }

    /// 这个文件开着没有（同一个文件只开一份：两份同时自动存盘会互相盖掉）。
    func project(openAt url: URL) -> VideoEditProject? {
        all.first { project in project.documentURL.map { ProjectFileIdentity.same($0, url) } ?? false }
    }

    /// 装着这个工程的窗口：主窗口那个是主窗口，别的是它自己的工程窗口（没有窗口就是 nil）。
    func window(of project: VideoEditProject) -> NSWindow? {
        project === primary ? AIEditorPresenter.mainWindow() : windows[ObjectIdentifier(project)]?.window
    }

    // MARK: 开、关

    /// 在一个新的工程窗口里打开这个文件。它已经开着就把那个窗口摆出来、回它；开到顶了、文件打不开回 nil（原因写在 `failure`）。
    @discardableResult
    func openInWindow(_ url: URL) async -> VideoEditProject? {
        failure = nil
        if let open = project(openAt: url) {
            reveal(open)
            return open
        }
        guard all.count < Self.limit else {
            failure = "SrtFlow keeps at most \(Self.limit) projects open. Close one first."
            return nil
        }
        let project = VideoEditProject(shortID: shortIDs.next())
        await project.openProject(at: url)
        guard let opened = project.documentURL, ProjectFileIdentity.same(opened, url) else {
            failure = project.notice ?? "SrtFlow could not open \(url.lastPathComponent)."
            return nil
        }
        // 打开的那几秒里别处也开了它：用先开的那一份。
        if let earlier = self.project(openAt: url), earlier !== project {
            reveal(earlier)
            return earlier
        }
        others.append(project)
        attachWindow(to: project)
        return project
    }

    /// 上一次 `openInWindow` 为什么没开成（给 AI 转述的英文；界面上要用时再按 L10n 换）。
    @ObservationIgnored private(set) var failure: String?

    /// 把这个工程的窗口摆到前面（不激活 App）。主窗口那个就摆主窗口。
    func reveal(_ project: VideoEditProject) {
        window(of: project)?.orderFrontRegardless()
    }

    /// 键窗口里是不是这个工程的剪辑页（主窗口还要停在剪辑页那一栏）。存盘前让输入框辞职只许动它自己的。
    func editorIsKey(_ project: VideoEditProject) -> Bool {
        guard let key = NSApp.keyWindow, key === window(of: project) else { return false }
        return project !== primary || MainWindowState.shared.section == .videoEdit
    }

    private func attachWindow(to project: VideoEditProject) {
        let controller = ProjectWindowController(project: project) { [weak self] closed in self?.windowClosed(closed) }
        windows[ObjectIdentifier(project)] = controller
        cascade = controller.present(cascadingFrom: cascade)
    }

    /// 工程窗口关掉了（`windowShouldClose` 已经替它落了盘）：这个工程关掉、收拾干净。
    private func windowClosed(_ project: VideoEditProject) {
        windows[ObjectIdentifier(project)] = nil
        if keyProjectWindow === project { keyProjectWindow = nil }
        others.removeAll { $0 === project }
        ProjectTeardown.close(project)
    }

    // MARK: 键窗口

    func projectWindowBecameKey(_ project: VideoEditProject) { keyProjectWindow = project }

    func projectWindowResignedKey(_ project: VideoEditProject) {
        if keyProjectWindow === project { keyProjectWindow = nil }
    }

    // MARK: 全 App 一份的开关

    /// 工具栏的吸附 / 联动 / 播放跟随是全 App 一份的记忆（EditorToggles）：一个工程窗口里拨了，别的开着的工程跟着拨
    /// （它们的 didSet 再调回来时值已经一样，就停了）。
    func sync<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<VideoEditProject, Value>, from source: VideoEditProject) {
        let value = source[keyPath: keyPath]
        for project in all where project !== source && project[keyPath: keyPath] != value {
            project[keyPath: keyPath] = value
        }
    }
}

/// 关一个工程（不是换内容）时把它的运行时状态收拾干净：落盘已经由调用方做过（`prepareToCloseDocument`）。
/// 以前只有一个永不释放的单例，这些从来不用收拾；几个工程开开关关时漏一样就是泄漏（实时音频引擎的喂样线程自己留着自己）
/// 或者把别的工程的活停了。
@MainActor
enum ProjectTeardown {
    static func close(_ project: VideoEditProject) {
        let closing = project.documentGeneration
        project.cancelLiveEdit()
        project.invalidateDocumentGeneration()  // 作废后台导入、只取消它自己的转写和翻译
        project.autosaveTask?.cancel()
        project.clock.pause()
        project.clock.detach()
        project.audioEngineHost.stop()
        project.optimizedMedia.reset()
        UpscaleActivity.shared.cancelAll(projectGeneration: closing)
        project.effectiveUndoManager?.removeAllActions()
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

/// 两个路径是不是同一个工程文件：规范化之后、跟着符号链接走，路径一样就是同一个（和「重新打开当前工程只 flush」同一个判法）。
enum ProjectFileIdentity {
    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 剪辑页装在哪：主窗口的剪辑页（工程是 `primary`，撤销管理器借主窗口的），还是一个工程窗口（撤销管理器是工程自己的）。
enum EditorHost {
    case mainWindow
    case projectWindow
}

/// 工程代号（`VideoEditProject.documentGeneration`）从这里发：**全 App 一个计数，几个工程不重号**。
///
/// 代号被当作「这一个工程的这一次打开」的身份跨对象比较：AI 会话记着的工程（`AIProjectBinding.token`）、路由记的谁换了工程、
/// 「撤销这一轮」的快照、导出面板的标题、upscale 任务、录屏请求和崩溃恢复的记录、转写 / 翻译绑着哪个工程。每个工程各从 0 数
/// 的话，两个工程会撞号，被判成同一个。
@MainActor
enum DocumentGenerations {
    private static var last = 0

    static func next() -> Int {
        last += 1
        return last
    }
}
