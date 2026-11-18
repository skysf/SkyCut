import AppKit
import Foundation

// MARK: - The export panel's folder chooser: the macOS folder window without letting it wedge SkyCut
//
// What it does: opens the system folder window (NSOpenPanel) for the export panel's "Export to" row **non-modally**
// (`begin`), watches whether the window really appears, lets the person close a window that stopped responding, and
// says when the system window failed so the row can offer typing a path / dropping a folder instead.
// What it doesn't: check the folder (ExportDestinationProbe), draw the row (ExportFolderRow), remember the folder
// (VideoEditExporter.exportFolder).
//
// Why (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): a non-sandboxed app's NSOpenPanel is
// drawn by the out-of-process `com.apple.appkit.xpc.openAndSavePanelService`. Measured on macOS 26.5 with a probe app:
// - the service hangs while a panel is up under `runModal` → `runModal` never returns and the panel's own buttons are
//   dead (45 s observed, no timeout, no alert);
// - the service hangs before the next panel → `NSOpenPanel()` blocks the main thread for 60 s, then no window appears
//   and `begin` never calls back;
// - with `begin`, a hung service leaves the app responsive, and `cancel()` closes the stuck window at once.
// Rules: docs/architecture/export-settings.md, "Export folder window and destination checks".

/// The one window the chooser drives (a seam: the checks pass a fake that hangs, vanishes or answers).
@MainActor
protocol FolderChooserPanel: AnyObject {
    var isVisible: Bool { get }
    /// Shows the window without a modal session; `completion` gets the folder, or nil when it was cancelled.
    func begin(_ completion: @escaping (URL?) -> Void)
    func cancel()
}

/// The real system folder window.
@MainActor
final class SystemFolderPanel: FolderChooserPanel {
    private let panel: NSOpenPanel

    init(startingAt folder: URL) {
        // AppKit connects to its panel service right here; when that service hangs, this line alone holds the main
        // thread for up to about a minute (measured 60 s). Nothing in SkyCut can cut it short, which is why the
        // chooser leaves a record before calling it (ExportFolderChooserRecord).
        panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = L10n("Choose")
        panel.message = L10n("Choose the folder to export into")
    }

    var isVisible: Bool { panel.isVisible }

    func begin(_ completion: @escaping (URL?) -> Void) {
        panel.begin { [panel] response in completion(response == .OK ? panel.url : nil) }
    }

    func cancel() { panel.cancel(nil) }
}

@MainActor
final class ExportFolderChooser: ObservableObject {
    enum Failure: Equatable {
        /// The window never appeared, or went away, and macOS never answered.
        case noWindow
        /// The window came back empty almost at once: AppKit's own failure path, faster than a person can cancel.
        case returnedAtOnce
        /// The person closed a window that stopped responding ("Close It" in the export panel).
        case closedByUser
        /// SkyCut ended (force quit, crash) while the window was open last time.
        case lastRunDidNotFinish
    }

    enum Phase: Equatable {
        case idle
        case choosing
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle

    private let makePanel: @MainActor (URL) -> FolderChooserPanel
    private let record: ExportFolderChooserRecord
    private let note: (String) -> Void
    private let appearDeadline: TimeInterval
    private let quickReturn: TimeInterval
    private var panel: FolderChooserPanel?
    private var watcher: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - appearDeadline: how long the window may stay away while macOS has not answered before it counts as failed.
    ///   - quickReturn: an empty answer sooner than this after `begin` is AppKit failing, not a person cancelling.
    init(
        makePanel: @escaping @MainActor (URL) -> FolderChooserPanel = { SystemFolderPanel(startingAt: $0) },
        record: ExportFolderChooserRecord = .shared,
        note: @escaping (String) -> Void = { MainThreadWatchdog.shared.note($0) },
        appearDeadline: TimeInterval = 3,
        quickReturn: TimeInterval = 1
    ) {
        self.makePanel = makePanel
        self.record = record
        self.note = note
        self.appearDeadline = appearDeadline
        self.quickReturn = quickReturn
    }

    /// Opens the system folder window. `force` skips the detour after a run that ended with the window open
    /// (the "Try Again" button).
    func choose(startingAt folder: URL, force: Bool = false, onChosen: @escaping (URL) -> Void) {
        guard phase != .choosing else { return }
        if !force, record.previousRunDidNotFinish() {
            record.clear()
            note("export folder window: the last run ended while it was open; offering a typed path first")
            phase = .failed(.lastRunDidNotFinish)
            return
        }
        phase = .choosing
        record.markStarted()
        clearRecordOnQuit()
        note("export folder window: opening")
        let asked = ProcessInfo.processInfo.systemUptime
        let panel = makePanel(folder)
        let made = ProcessInfo.processInfo.systemUptime - asked
        if made >= 2 { note(String(format: "export folder window: macOS took %.1f s to make it", made)) }
        self.panel = panel
        let began = ProcessInfo.processInfo.systemUptime
        panel.begin { [weak self, weak panel] url in
            guard let self, let panel, panel === self.panel else { return }
            self.answered(url, after: ProcessInfo.processInfo.systemUptime - began, onChosen: onChosen)
        }
        watch(panel, since: began)
    }

    /// "Close It": the window is on screen but stopped responding. `cancel()` closes it even when its service hangs.
    func closeStuckWindow() {
        guard phase == .choosing else { return }
        note("export folder window: closed from the export panel")
        end(.failed(.closedByUser), cancelWindow: true)
    }

    /// The export panel went away: no folder window left behind that nobody is waiting for.
    func cancelIfChoosing() {
        guard phase == .choosing else { return }
        end(.idle, cancelWindow: true)
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func answered(_ url: URL?, after elapsed: TimeInterval, onChosen: (URL) -> Void) {
        if let url {
            end(.idle, cancelWindow: false)
            onChosen(url)
        } else if elapsed < quickReturn {
            note(String(format: "export folder window: came back empty after %.2f s", elapsed))
            end(.failed(.returnedAtOnce), cancelWindow: false)
        } else {
            end(.idle, cancelWindow: false)
        }
    }

    /// The window has to be on screen; away for `appearDeadline` with no answer = failed (`begin` may never call back).
    private func watch(_ panel: FolderChooserPanel, since began: TimeInterval) {
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            var seen = began
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.panel === panel, self.phase == .choosing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // A hidden app (⌘H) hides the window too: not a failure.
                if panel.isVisible || NSApp?.isHidden == true { seen = now; continue }
                if now - seen >= self.appearDeadline {
                    self.note("export folder window: not on screen and macOS never answered")
                    self.end(.failed(.noWindow), cancelWindow: true)
                    return
                }
            }
        }
    }

    private func end(_ next: Phase, cancelWindow: Bool) {
        watcher?.cancel()
        watcher = nil
        let open = panel
        panel = nil  // before cancel(): its completion runs inside cancel() and must find nothing to answer
        if cancelWindow { open?.cancel() }
        record.clear()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        phase = next
    }

    /// Quitting normally with the window open is not a hang: don't send the next launch on the detour.
    private func clearRecordOnQuit() {
        guard quitObserver == nil else { return }
        let record = record
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in record.clear() }
    }
}

/// "The folder window has been open in process X": written before SkyCut asks AppKit for the window and cleared when
/// it answers or SkyCut quits normally. Still there in another process = the last run ended (force quit, crash) with
/// the window open — most likely frozen inside AppKit — so the next attempt starts with the typed path.
struct ExportFolderChooserRecord: Sendable {
    /// Identity-class key: keeps the old SrtFlow prefix (docs/architecture/product-name.md).
    static let key = "SrtFlow.export.folderChooserInFlight"
    static let shared = ExportFolderChooserRecord(suiteName: nil)

    /// nil = the app's own defaults; the checks pass their own suite.
    let suiteName: String?
    var processID: Int32 = ProcessInfo.processInfo.processIdentifier

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    func markStarted() {
        defaults.set(["pid": Int(processID), "at": Date().timeIntervalSince1970], forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    func previousRunDidNotFinish() -> Bool {
        guard let entry = defaults.dictionary(forKey: Self.key), let pid = entry["pid"] as? Int else { return false }
        return Int32(pid) != processID
    }
}
