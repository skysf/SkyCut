import AppKit
import SwiftUI

// MARK: - 工程窗口：主窗口以外的剪辑工程各自一个窗口（2026-10-17 起）
//
// 管什么：一个 AppKit 自己建的窗口，里面是同一个剪辑页（`VideoEditView`）；window delegate 交出**工程自己的**撤销管理器 ——
// ⌘Z、编辑菜单、工具栏的撤销按钮撤的都是这个工程的，挂上 / 摘下窗口不丢历史；层叠排开、摆到前面一次但不激活 App；
// 关窗之前先过 `prepareToCloseDocument`（落盘、未命名的问存不存），关了告诉注册表。
// 不管什么：开哪个工程、关窗之后工程去哪（OpenProjects）；剪辑页本身。
//
// 为什么不用 SwiftUI 的 WindowGroup：SwiftUI 的窗口（`AppKitWindow`）不问 delegate 要撤销管理器，⌘Z 只撤得到窗口自己的那个；
// AppKit 的窗口按 `windowWillReturnUndoManager` 交出工程的那一个，SwiftUI 的工具栏（`sceneBridgingOptions`）、sheet、
// `@Environment(\.undoManager)` 也都跟着对（2026-10-17 探针，docs/architecture/open-projects.md 第三节）。

@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate {
    let project: VideoEditProject
    /// 窗口关掉了（注册表据此收拾这个工程）。
    private let onClosed: (VideoEditProject) -> Void

    init(project: VideoEditProject, onClosed: @escaping (VideoEditProject) -> Void) {
        self.project = project
        self.onClosed = onClosed
        let host = NSHostingView(rootView: ProjectWindowRoot(project: project).appLanguage())
        // 剪辑页的工具栏（工程菜单、素材库开关、录屏、字幕、导出）和标题都是 SwiftUI 写的：交给这个窗口。
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentMinSize = NSSize(width: 900, height: 580)   // 同剪辑页的最小尺寸
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // **先挂 delegate 再放内容**：窗口头一回被问撤销管理器时才问 delegate、之后就记住那一个；SwiftUI 的内容一放进来就会问，
        // 那时还没 delegate 的话窗口自己建一个，⌘Z 就撤不到工程的（2026-10-17 冒烟撞上的）。
        window.delegate = self
        window.contentView = host
        // 窗口给的撤销管理器就是工程自己的（下面的 delegate）；别再指着主窗口的那个（它可能是从主窗口挪出来的）。
        project.undoManager = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ProjectWindowController is built in code") }

    /// 层叠在上一个窗口右下方（第一个放正中），摆到最前面一次、不激活 App（键盘留在用户正在打字的地方，方案板 3）；
    /// `inFront` 是 false 时放到所有窗口后面（AI 的后台模式）。返回下一个窗口该从哪儿层叠。
    func present(cascadingFrom point: NSPoint, inFront: Bool = true) -> NSPoint {
        guard let window else { return point }
        if point == .zero { window.center() }
        let next = window.cascadeTopLeft(from: point)
        if inFront { window.orderFrontRegardless() } else { window.orderBack(nil) }
        return next
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { project.ownUndoManager }

    /// 关窗前落盘；未命名又剪了东西的问存不存，点了取消就不关。
    func windowShouldClose(_ sender: NSWindow) -> Bool { project.prepareToCloseDocument() }

    func windowWillClose(_ notification: Notification) { onClosed(project) }

    // 菜单（⌘S、拷贝粘贴）作用在键窗口的工程上（OpenProjects.focused）。
    func windowDidBecomeKey(_ notification: Notification) { OpenProjects.shared.projectWindowBecameKey(project) }
    func windowDidResignKey(_ notification: Notification) { OpenProjects.shared.projectWindowResignedKey(project) }
}

/// 工程窗口的根：剪辑页 + 窗口标题跟着工程名走。
private struct ProjectWindowRoot: View {
    let project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VideoEditView(project: project, host: .projectWindow)
            .navigationTitle(project.projectName)
    }
}
