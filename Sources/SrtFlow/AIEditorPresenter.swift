import AppKit
import SwiftUI

// MARK: - 「看得见」：AI 改到哪，界面就跟到哪
//
// 管什么：AI 开始剪主窗口里那个工程时把剪辑页摆出来（切到剪辑页、窗口放到最前面但**不抢键盘** —— 用户可能正在
// 对话框里打字）；每一步之后选中改到的东西、播放头跳过去、时间线滚过去。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 7、8 条和 docs/plans/2026-10-17-multi-project-ai-editing.md 板 3。
// 不管什么：改什么（AI*Tools）、这一轮的状态（AIRound）、工程窗口怎么摆（OpenProjects）。
//
// **只在开工程时摆一次**（板 3，2026-10-17 用户定，取代 2026-09-27 第 32 条「每一轮开始摆一次」）：几个工程各自一轮一轮地往前跳
// 会乱成一团，用户自己用鼠标挑窗口。开 / 建进主窗口、会话第一次在主窗口那个（这一次打开）上做要摆剪辑页的事、`set_view visible` 各摆一次；
// 之后用户把别的窗口挪上来、最小化它、切去别的栏目，都照他的来。例外只有两种：窗口被关了
// （不开回来 AI 的改动看不见、也进不了 ⌘Z），剪辑页从没出现过（撤销管理器是它交给工程的）。

@MainActor
enum AIEditorPresenter {
    /// 「打开主窗口」的动作（`openWindow` 只在 SwiftUI 视图里拿得到）。主窗口被用户关掉之后，只有它能把窗口开回来。
    /// 两处存：主窗口出现时（MainWindowView），和菜单建好时（`noteMenuOpenWindow`，比窗口还早 —— 窗口从没出现过也开得回来）。
    static var openMainWindow: OpenWindowAction?

    /// 菜单里拿到的「打开主窗口」：菜单一建好就有。只在还没有的时候存（主窗口那一份优先）。
    static func noteMenuOpenWindow(_ action: OpenWindowAction) {
        if openMainWindow == nil { openMainWindow = action }
    }

    /// 刚启动时窗口还没建好，最多等这么久（2026-10-06 盲测：内存吃紧的机器上小程序拉起 App 8 秒后还没有主窗口）。
    static let launchWindowWait: TimeInterval = 10

    /// 改主窗口里的工程之前调。`bringForward`：这是开工程的那一下（开 / 建进主窗口、会话第一次在它上面摆剪辑页、set_view visible）。
    static func prepareEditor(project: VideoEditProject, bringForward: Bool) async throws {
        let windowState = MainWindowState.shared
        // 小程序刚把 App 拉起来：主窗口、「打开主窗口」的动作可能都还没有，等一会儿再说「关着」。
        let deadline = Date().addingTimeInterval(launchWindowWait)
        while mainWindow() == nil, openMainWindow == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var reopened = false
        if let window = mainWindow() {
            if bringForward {
                if windowState.section != .videoEdit { windowState.section = .videoEdit }
                if window.isMiniaturized { window.deminiaturize(nil) }
                // 摆到最前面但不激活 App：键盘留在用户正在打字的地方。
                window.orderFrontRegardless()
            }
        } else if let open = openMainWindow {
            if windowState.section != .videoEdit { windowState.section = .videoEdit }
            open(id: WindowID.main)
            await placeReopenedWindow(project)
            reopened = true
        } else {
            throw AIToolError(
                "SrtFlow's main window is closed and SrtFlow could not open it. Ask the user to open it (File > Edit Video, "
                    + "or \(editVideoShortcut)), then call again."
            )
        }
        // 剪辑页出现时才把窗口的撤销管理器交给工程（VideoEditView.onAppear）；没有它，
        // AI 的改动进不了 ⌘Z。从没出现过的话，这一轮中途也得切过去；刚切过去（或窗口刚开回来、系统又忙）时它还没出现，等一会儿。
        if project.undoManager == nil, windowState.section != .videoEdit { windowState.section = .videoEdit }
        let undoDeadline = Date().addingTimeInterval(reopened ? launchWindowWait : 1)
        while project.undoManager == nil, Date() < undoDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// 剪辑页的快捷键：菜单里「Edit Video」那一项（SrtFlowApp）用的那个键，check-mcp.sh 对账。
    static let editVideoShortcut = "Command-1"

    /// 开回来的窗口放哪：从不激活 App（键盘留在用户那边）。看得见时摆到最前面；后台模式、正在录屏时放到所有窗口后面 ——
    /// 开回来只是为了让改动进得了 ⌘Z，不该盖住用户在看的窗口、也不该被录进去。
    private static func placeReopenedWindow(_ project: VideoEditProject) async {
        for _ in 0..<20 where mainWindow() == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let window = mainWindow() else { return }
        if AISession.shared.viewMode(for: project) == .background || ScreenRecordingCoordinator.shared.isBusy {
            window.orderBack(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// 装着剪辑页的那个窗口。SwiftUI 给 `Window(id:)` 的窗口起的标识符就是 id（有的系统版本后面
    /// 带编号）；认不出来时退回第一个能当主窗口、不是设置窗口的。
    static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.canBecomeMain && $0.contentView != nil }
        if let match = candidates.first(where: {
            let id = $0.identifier?.rawValue ?? ""
            return id == WindowID.main || id.hasPrefix(WindowID.main + "-")
        }) {
            return match
        }
        return candidates.first { !($0.identifier?.rawValue ?? "").lowercased().contains("settings") }
    }

    /// 每一步之后给用户看的：选中哪些、播放头去哪。
    struct Reveal {
        var clips: Set<UUID> = []
        var shapes: Set<UUID> = []
        var texts: Set<UUID> = []
        var filters: Set<UUID> = []
        var cues: Set<UUID> = []
        var time: Double?
    }

    /// 这个工程是后台（`AISession.viewMode(for:)`）时不选中、不挪播放头、不滚时间线 —— 除非 `always`（seek：AI 就是要给用户看这一刻）。
    static func reveal(_ reveal: Reveal, project: VideoEditProject, always: Bool = false) {
        guard always || AISession.shared.viewMode(for: project) == .visible else { return }
        let selectsSomething = !reveal.clips.isEmpty || !reveal.shapes.isEmpty || !reveal.texts.isEmpty
            || !reveal.filters.isEmpty || !reveal.cues.isEmpty
        if selectsSomething {
            project.applyBoxSelection(
                clips: reveal.clips, shapes: reveal.shapes, texts: reveal.texts, cues: reveal.cues, filters: reveal.filters
            )
        }
        guard let time = reveal.time else { return }
        if project.clock.isPlaying { project.clock.pause() }
        project.clock.seek(to: max(0, time))
        scrollTimeline(to: max(0, time), project: project)
    }

    /// 时间线横向滚到能看见这一刻（和播放跟随同一个判据：快出视野了才动，挪到偏左的位置）。
    private static func scrollTimeline(to time: Double, project: VideoEditProject) {
        guard let geometry = TimelineScrollGeometry.live(for: project) else { return }
        let x = time * project.pixelsPerSecond
        let width = Double(geometry.viewportSize.width)
        let offset = geometry.offsetX
        guard width > 80, x < offset + 40 || x > offset + width - 80 else { return }
        geometry.scrollHorizontally(to: max(0, x - width * 0.15), animated: true)
    }
}
