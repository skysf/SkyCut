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
    /// 主窗口以外开着的工程，按开的先后：在自己的窗口里，或者在后台、没有窗口（AI 的后台模式；不建播放器 / 合成 / 音频引擎，方案板 8）。
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
    // 小视图按它观察「后台 / 有窗口」；开窗后任务卡片的后台标记要立即更新。
    private var windows: [ObjectIdentifier: ProjectWindowController] = [:]
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

    /// 装着这个工程的窗口：主窗口那个是主窗口，别的是它自己的工程窗口（后台工程没有窗口，是 nil）。
    func window(of project: VideoEditProject) -> NSWindow? {
        project === primary ? AIEditorPresenter.mainWindow() : windows[ObjectIdentifier(project)]?.window
    }

    /// 在后台、没有窗口（主窗口以外、没挂窗口的）。
    func isHeadless(_ project: VideoEditProject) -> Bool {
        project !== primary && windows[ObjectIdentifier(project)] == nil
    }

    /// 有剪辑页在显示它（主窗口那个永远算）：后台工程不建预览（`VideoEditProject.scheduleRebuild` 问这一句）。
    func showsEditor(_ project: VideoEditProject) -> Bool {
        project === primary || windows[ObjectIdentifier(project)] != nil
    }

    // MARK: 开、关

    /// 主窗口以外的工程放哪：自己的窗口（`inFront`：摆到最前面一次，否则放到别的窗口后面），或者后台（没有窗口）。
    enum Placement: Equatable {
        case window(inFront: Bool)
        case background
    }

    /// 打开这个文件（主窗口以外）。它已经开着就回它（看得见时把它的窗口摆出来）；开到顶了、文件打不开回 nil（原因写在 `failure`）。
    @discardableResult
    func open(_ url: URL, placement: Placement = .window(inFront: true)) async -> VideoEditProject? {
        failure = nil
        if let open = project(openAt: url) {
            if placement == .window(inFront: true) { reveal(open) }
            return open
        }
        guard all.count < Self.limit else {
            failure = "SkyCut keeps at most \(Self.limit) projects open. Close one first."
            return nil
        }
        let project = VideoEditProject(shortID: shortIDs.next())
        await project.openProject(at: url)
        guard let opened = project.documentURL, ProjectFileIdentity.same(opened, url) else {
            failure = project.notice ?? "SkyCut could not open \(url.lastPathComponent)."
            return nil
        }
        // 打开的那几秒里别处也开了它：用先开的那一份。
        if let earlier = self.project(openAt: url), earlier !== project {
            reveal(earlier)
            return earlier
        }
        others.append(project)
        place(project, placement)
        return project
    }

    /// 新建一个空工程、马上存成 `url`、放进它自己的窗口或者后台（AI 的 new_project 在主窗口不空的时候）。存不下回 nil（原因在 `failure`）。
    func newProject(savingAs url: URL, placement: Placement) -> VideoEditProject? {
        failure = nil
        guard all.count < Self.limit else {
            failure = "SkyCut keeps at most \(Self.limit) projects open. Close one first."
            return nil
        }
        let project = VideoEditProject(shortID: shortIDs.next())
        guard project.saveDocument(as: url) else {
            failure = project.notice ?? "SkyCut could not save the new project to \(url.path)."
            return nil
        }
        others.append(project)
        place(project, placement)
        return project
    }

    /// 关掉主窗口以外的一个工程（AI 的 close_project、用户在「AI 在剪的工程」里点关掉）：先落盘（落不下就不关、回 false，原因在工程的
    /// `notice`），再关窗口（有的话）、收拾。主窗口那个不在这里关（它永远在，换成一个空的 Untitled 由调用方做）。
    func close(_ project: VideoEditProject) -> Bool {
        guard project !== primary, others.contains(where: { $0 === project }) else { return false }
        guard project.prepareToCloseDocument() else { return false }
        if let controller = windows[ObjectIdentifier(project)] {
            controller.close()   // 程序关窗不问 windowShouldClose，windowWillClose 照来 → windowClosed 收拾
        } else {
            finishClosing(project)
        }
        return true
    }

    /// 给后台工程挂上窗口（AI 的 set_view visible、用户点「打开窗口」）：建窗口、重建一次预览；已经有窗口就看情况摆出来。
    func showWindow(for project: VideoEditProject, inFront: Bool) {
        guard isHeadless(project), others.contains(where: { $0 === project }) else {
            if inFront { reveal(project) }
            return
        }
        attachWindow(to: project, inFront: inFront)
        project.scheduleRebuild()
    }

    /// 摘掉工程窗口、工程转到后台接着开着（AI 的 set_view background）：预览的播放器、音频引擎、优化媒体停掉，照样自动存盘。
    func moveToBackground(_ project: VideoEditProject) {
        windows[ObjectIdentifier(project)]?.closeKeepingProject()
    }

    /// AI 正在剪它（归一个 5 分钟内调用过的会话，这一次打开的）：用户关掉它的窗口时工程留着、转到后台（方案 A.6）。
    func aiIsEditing(_ project: VideoEditProject) -> Bool {
        let sessions = AIProjectSessions.shared
        guard let owner = sessions.owner(of: project), owner.token == sessions.stamp(project).token else { return false }
        return sessions.ownership.isActive(owner.session, at: Date())
    }

    /// 主窗口里的工程换成一个空的 Untitled（AI 关掉它在主窗口里剪的那个：主窗口永远有一个工程）。调用方先替它落好盘。
    /// 返回 false = 没换成（录屏中、存盘失败：`newProject` 的把关拒了），原因在 `primary.notice`。
    func resetPrimary() -> Bool {
        let before = primary.documentGeneration
        primary.newProject()
        return primary.documentGeneration != before
    }

    // MARK: 用户新建 / 打开（文件菜单、工程菜单、最近打开、双击工程文件）

    /// 用户要在这个窗口里打开别的工程：这个窗口里的工程 AI 正在剪，就不换掉它、开到一个新的工程窗口里。
    /// 方案 A.5 原来想把 AI 的工程挪出去；反过来开新窗口简单得多：AI 的短 id、撤销历史都不动，Mac 上一个文档一个窗口本来就是常态。
    func userOpen(_ url: URL, from project: VideoEditProject) async {
        guard aiIsEditing(project) else {
            await project.openProject(at: url)
            return
        }
        if await open(url, placement: .window(inFront: true)) == nil { project.notice = failure }
    }

    /// 用户要新建工程：同上，AI 正在剪这个窗口里的工程就开一个新的未命名工程窗口。
    func userNew(from project: VideoEditProject) {
        guard aiIsEditing(project) else {
            project.newProject()
            return
        }
        guard all.count < Self.limit else {
            project.notice = String(format: L10n("SkyCut keeps at most %lld projects open. Close one first."), Self.limit)
            return
        }
        let fresh = VideoEditProject(shortID: shortIDs.next())
        others.append(fresh)
        place(fresh, .window(inFront: true))
    }

    /// 把工程的窗口摆到前面、交出键盘（用户在「AI 在剪的工程」里点的：他就是要去那个窗口）；后台工程先挂上窗口。
    func focus(_ project: VideoEditProject) {
        if isHeadless(project) { showWindow(for: project, inFront: true) }
        if project === primary { MainWindowState.shared.section = .videoEdit }
        guard let window = window(of: project) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// 上一次 `open` / `newProject` 为什么没开成（给 AI 转述的英文；界面上要用时再按 L10n 换）。
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

    /// 刚开 / 建好的工程放上去：要窗口就挂一个（挂上之后重建预览：开的时候它还没窗口，`scheduleRebuild` 跳过了），后台就什么都不建。
    private func place(_ project: VideoEditProject, _ placement: Placement) {
        guard case .window(let inFront) = placement else { return }
        attachWindow(to: project, inFront: inFront)
        project.scheduleRebuild()
    }

    private func attachWindow(to project: VideoEditProject, inFront: Bool) {
        let controller = ProjectWindowController(project: project) { [weak self] closed, keepsProject in
            self?.windowClosed(closed, keepsProject: keepsProject)
        }
        windows[ObjectIdentifier(project)] = controller
        cascade = controller.present(cascadingFrom: cascade, inFront: inFront)
    }

    /// 工程窗口关掉了。`keepsProject`：工程转到后台接着开着（AI 还在剪 / set_view background），只停预览；否则
    /// （`windowShouldClose` 已经替它落了盘）这个工程关掉、收拾干净。
    private func windowClosed(_ project: VideoEditProject, keepsProject: Bool) {
        windows[ObjectIdentifier(project)] = nil
        if keyProjectWindow === project { keyProjectWindow = nil }
        if keepsProject {
            ProjectTeardown.stopPreview(project)
            return
        }
        finishClosing(project)
    }

    private func finishClosing(_ project: VideoEditProject) {
        others.removeAll { $0 === project }
        AIProjectSessions.shared.release(project)   // 谁在剪它都不再归谁（AI 下一步按 id 找会被告知它关了）
        AISession.shared.forgetRound(of: project)   // 它的「这一轮」不再留着
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
    /// 工程转到后台（摘掉窗口、工程还开着）：只停预览那一套 —— 播放器的条目、实时音频引擎、优化媒体的转码；文档、撤销历史、任务都留着。
    static func stopPreview(_ project: VideoEditProject) {
        project.cancelLiveEdit()
        project.clock.pause()
        project.clock.detach()
        project.audioEngineHost.stop()
        project.optimizedMedia.reset()
    }

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
