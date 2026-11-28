import AppKit
import SwiftUI

// MARK: - The window of SkyCut › Check for Updates…
//
// What it does: the small window a check started from the app menu opens. A utility panel: it floats above SkyCut's own
// windows, is off screen while SkyCut isn't active (never above other apps), moves aside by its title bar or background,
// and is never modal, so SkyCut keeps working while a slow check waits. It shows checking (a spinner, Cancel) or the
// answer, as AppUpdateCheckFlow decides: straight on a quick answer, else the answer in place of the checking state. It
// never takes the keyboard (it becomes key only when clicked) and is never brought forward by an update. A newer version is then followed live (AppUpdateCheckDisplay: its download, verified
// and ready, a download that didn't finish), in place. Cancel stops the check; the close button only hides the window: the
// check goes on, and a download is never stopped by the window. While a download runs, the app menu's item brings the
// window back on it (`showDownload`, no check). Every call comes from a run-loop turn (AppUpdater's effects through
// RunLoop.main.perform, the buttons and the menu, a run-loop timer, SkyCut becoming active), never from inside a Swift
// task. The panel is made when it is first needed and kept for the run, so it opens where the person last left it.
// What it doesn't: check (AppUpdater), decide what shows when (AppUpdateCheckFlow), the words (AppUpdateCheckContent).
// Rules: docs/architecture/app-updates.md "What the person sees".

@MainActor
final class AppUpdateCheckWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppUpdateCheckWindow()

    /// What the window draws (kept while it is off screen, so it never draws empty).
    @Published private(set) var content: AppUpdateCheckFlow.Shows = .checking
    /// The running version, read when the check starts.
    @Published private(set) var running = ""

    private var flow = AppUpdateCheckFlow()
    private var panel: NSPanel?
    /// Placed once (the middle of the screen SkyCut is on); afterwards where the person left it.
    private var placed = false
    private var timer: Timer?
    private var activation: NSObjectProtocol?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// AppUpdater's `.openCheckWindow`: the person chose Check for Updates… or Try Again.
    func open() {
        running = AppUpdater.shared.running?.description ?? ""
        _ = makePanel()   // made while the check runs: showing it costs nothing later
        apply(flow.chosen(at: Self.now))
    }

    /// AppUpdater's `.answer`.
    func show(_ answer: AppUpdateCheckAnswer) { apply(flow.answered(answer, at: Self.now)) }

    /// The app menu's item while a download runs: the window shows that download, wherever it was. No check starts.
    func showDownload() {
        guard let offer = AppUpdater.shared.state.offer else { return }
        running = AppUpdater.shared.running?.description ?? ""
        _ = makePanel()
        apply(flow.showing(.downloading(offer)))
    }

    /// The window's buttons. None of them stops a download: closing the window leaves it running, as the automatic one does.
    func perform(_ action: AppUpdateCheckAction) {
        switch action {
        case .cancel: apply(flow.cancelled())
        case .dismiss: apply(flow.closed())
        case .tryAgain: AppUpdater.shared.check(from: .menu)   // its `.openCheckWindow` turns this window to checking
        case .downloadAndInstall: AppUpdater.shared.downloadAndInstall()   // the window stays and shows the download
        case .openDownloadPage:
            apply(flow.closed())
            NSWorkspace.shared.open(AppUpdateFeed.downloadPageURL)
        // As the pill's popover: now if nothing runs, else the window shows what the restart waits for.
        case .restart: AppUpdater.shared.requestRestart()
        case .cancelRestart: AppUpdater.shared.cancelRestart()
        }
    }

    /// Escape (once the person has clicked the window): the close button, in every state. It hides the window and never
    /// cancels a check, a download or a restart that waits.
    func escape() { perform(.dismiss) }

    /// The close button only hides the window: a check in flight goes on (hiding is not cancelling).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        apply(flow.closed())
        return false
    }

    private func apply(_ step: AppUpdateCheckFlow.Step) {
        if let shows = flow.shows, shows != content { content = shows }
        if step.stopsCheck { AppUpdater.shared.cancelCheck() }
        if step.closes { panel?.orderOut(nil) }
        if step.opens { present() }
        // A tick only re-reads the flow, so a timer that is no longer needed may still fire.
        if let time = step.tickAt { schedule(at: time) }
    }

    private func tick() { apply(flow.tick(at: Self.now)) }

    private func schedule(at time: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0, time - Self.now), repeats: false) { _ in
            MainActor.assumeIsolated { AppUpdateCheckWindow.shared.tick() }
        }
        // Common modes: it also fires while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// On screen, never key: the keyboard stays where the person is working. The panel becomes key only when the person
    /// clicks it (then Return and Escape reach it). While SkyCut isn't active it waits for SkyCut to come back.
    private func present() {
        guard NSApp.isActive else { return waitForActivation() }
        let panel = makePanel()
        place(panel)
        panel.orderFront(nil)
    }

    private func waitForActivation() {
        guard activation == nil else { return }
        // No queue: delivered inside AppKit's own activation handling, then shown one run-loop turn later.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: nil) { _ in
            RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateCheckWindow.shared.activated() } }
        }
    }

    private func activated() {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        guard flow.shows != nil, let panel, !panel.isVisible else { return }
        place(panel)
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = Self.panel(around: NSHostingView(rootView: AppUpdateCheckWindowRoot(window: self).appLanguage()))
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// The window around its content (the renders build theirs here too).
    static func panel(around host: NSView) -> NSPanel {
        let panel = AppUpdateCheckPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                        styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                                        backing: .buffered, defer: true)
        panel.title = L10n("Software Update")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true          // above SkyCut's own windows…
        panel.hidesOnDeactivate = true        // …and off screen while SkyCut isn't active: never above other apps
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false            // never reopened by the next launch
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // Only the close button: the others would show disabled.
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.contentView = host
        return panel
    }

    /// The title in the in-app language; the first time, centred a little above the middle of the screen SkyCut is on.
    private func place(_ panel: NSPanel) {
        panel.title = L10n("Software Update")
        guard !placed else { return }
        placed = true
        let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return panel.center() }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + (visible.height - size.height) * 0.62))
    }
}

/// The check window's panel. Escape reaches it as AppKit's cancelOperation (views may only take Return:
/// checks/instant-tooltip-wiring.sh). A taller content grows it downward, its top edge staying; one moved low on the screen
/// is then lifted just enough to stay whole on it (never on the person's own drags: those keep the size).
final class AppUpdateCheckPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        AppUpdateCheckWindow.shared.escape()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if frame.height > self.frame.height, let visible = (screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - frame.height)
        }
        super.setFrame(frame, display: flag)
    }
}

/// The window's root: what it shows now, a found release followed live from the updater (never a project or the clock).
struct AppUpdateCheckWindowRoot: View {
    @ObservedObject var window: AppUpdateCheckWindow
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        AppUpdateCheckContent(display: AppUpdateCheckDisplay.make(window.content, state: updater.state, mode: updater.mode),
                              running: window.running) { window.perform($0) }
    }
}
