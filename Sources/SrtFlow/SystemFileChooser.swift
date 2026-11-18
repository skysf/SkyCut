import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - The macOS open / save window, without letting it wedge SkyCut
//
// What it does: opens the system file window (NSOpenPanel / NSSavePanel) for one request — files to open, a folder, a new
// file to save — **non-modally** (`begin`), watches whether the window really appears, lets the person close a window that
// stopped responding, and says when the system window failed so the caller can offer typing a path / dropping files.
// Every open and save window in SkyCut goes through it: the export panel's folder row drives one of its own
// (ExportFolderRow); everything else shares one (SystemFileWindows).
// What it doesn't: what the caller does with the files; the typed-path / drop fallback UI (ExportFolderRow,
// FileWindowHelper); checking a folder (ExportDestinationProbe).
//
// Why (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md; 2026-11-19 for every other window,
// docs/bugfixes/2026-11-19-modal-file-windows-can-wedge-app.md): a non-sandboxed app's open / save panel is drawn by the
// out-of-process `com.apple.appkit.xpc.openAndSavePanelService`. Measured on macOS 26.5 with a probe app:
// - the service hangs while a panel is up under `runModal` → `runModal` never returns and the panel's own buttons are
//   dead (45 s observed, no timeout, no alert);
// - the service hangs before the next panel → `NSOpenPanel()` blocks the main thread for 60 s, then no window appears
//   and `begin` never calls back;
// - with `begin`, a hung service leaves the app responsive, and `cancel()` closes the stuck window at once.
// Rules: docs/architecture/system-file-windows.md.

/// What the person is asked to pick in the macOS window.
struct FileWindowRequest: Equatable {
    enum Kind: Equatable {
        /// Files to open; no `types` = any file.
        case files(types: [UTType], multiple: Bool)
        /// One folder.
        case folder
        /// A new file to write, `name` suggested; `types` names its kind (the extension macOS adds).
        case save(types: [UTType], name: String)
    }

    var kind: Kind
    /// Where the window starts (nil: where macOS last was).
    var start: URL?
    var prompt: String?
    var message: String?
    /// Files whose type macOS doesn't know (.mkv) can be picked too.
    var allowsOtherTypes = false
}

/// The one window a chooser drives (a seam: the checks pass a fake that hangs, vanishes or answers).
@MainActor
protocol FileChooserPanel: AnyObject {
    var isVisible: Bool { get }
    /// Where the window is on screen (the helper panel stands next to it); `.zero` when unknown.
    var frame: NSRect { get }
    /// Shows the window without a modal session; `completion` gets the picked URLs, or nil when it was cancelled.
    func begin(_ completion: @escaping ([URL]?) -> Void)
    func cancel()
}

/// The real system window.
@MainActor
final class SystemFilePanel: FileChooserPanel {
    private let panel: NSSavePanel

    init(_ request: FileWindowRequest) {
        // AppKit connects to its panel service right here; when that service hangs, this line alone holds the main
        // thread for up to about a minute (measured 60 s). Nothing in SkyCut can cut it short, which is why the
        // chooser leaves a record before calling it (SystemFileWindowRecord).
        switch request.kind {
        case .files(let types, let multiple):
            let open = NSOpenPanel()
            open.canChooseFiles = true
            open.canChooseDirectories = false
            open.allowsMultipleSelection = multiple
            if !types.isEmpty { open.allowedContentTypes = types }
            panel = open
        case .folder:
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.allowsMultipleSelection = false
            panel = open
        case .save(let types, let name):
            let save = NSSavePanel()
            if !types.isEmpty { save.allowedContentTypes = types }
            save.nameFieldStringValue = name
            panel = save
        }
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = request.allowsOtherTypes
        if let start = request.start { panel.directoryURL = start }
        if let prompt = request.prompt { panel.prompt = prompt }
        if let message = request.message { panel.message = message }
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    func begin(_ completion: @escaping ([URL]?) -> Void) {
        panel.begin { [panel] response in
            guard response == .OK else { return completion(nil) }
            completion((panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? [])
        }
    }

    func cancel() { panel.cancel(nil) }
}

@MainActor
final class SystemFileChooser: ObservableObject {
    enum Failure: Equatable {
        /// The window never appeared, or went away, and macOS never answered.
        case noWindow
        /// The window came back empty almost at once: AppKit's own failure path, faster than a person can cancel.
        case returnedAtOnce
        /// The person closed a window that stopped responding ("Close It").
        case closedByUser
        /// SkyCut ended (force quit, crash) while a window was open last time.
        case lastRunDidNotFinish
    }

    enum Phase: Equatable {
        case idle
        case choosing
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle
    /// The request being chosen, or the one that failed (the fallback offers another way to answer it).
    private(set) var request: FileWindowRequest?

    private let makePanel: @MainActor (FileWindowRequest) -> FileChooserPanel
    private let record: SystemFileWindowRecord
    private let note: (String) -> Void
    private let appearDeadline: TimeInterval
    private let quickReturn: TimeInterval
    private var panel: FileChooserPanel?
    private var watcher: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - appearDeadline: how long the window may stay away while macOS has not answered before it counts as failed.
    ///   - quickReturn: an empty answer sooner than this after `begin` is AppKit failing, not a person cancelling.
    init(
        makePanel: @escaping @MainActor (FileWindowRequest) -> FileChooserPanel = { SystemFilePanel($0) },
        record: SystemFileWindowRecord = .shared,
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

    /// Where the open window is on screen (`.zero` when there is none).
    var windowFrame: NSRect { panel?.frame ?? .zero }
    /// The system window is on screen now.
    var windowIsVisible: Bool { panel?.isVisible ?? false }

    /// Opens the system window for `request`. `force` skips the detour after a run that ended with a window open (the
    /// "Try Again" button). `onChosen` gets the picked URLs, or nil when the person cancelled; it is not called when the
    /// window failed (the phase says how) or `cancelIfChoosing` closed it.
    func choose(_ request: FileWindowRequest, force: Bool = false, onChosen: @escaping ([URL]?) -> Void) {
        guard phase != .choosing else { return }
        self.request = request
        if !force, record.previousRunDidNotFinish() {
            record.clear()
            note("file window: the last run ended while one was open; offering a typed path first")
            phase = .failed(.lastRunDidNotFinish)
            return
        }
        phase = .choosing
        record.markStarted()
        clearRecordOnQuit()
        note("file window: opening")
        let asked = ProcessInfo.processInfo.systemUptime
        let panel = makePanel(request)
        let made = ProcessInfo.processInfo.systemUptime - asked
        if made >= 2 { note(String(format: "file window: macOS took %.1f s to make it", made)) }
        self.panel = panel
        let began = ProcessInfo.processInfo.systemUptime
        panel.begin { [weak self, weak panel] urls in
            guard let self, let panel, panel === self.panel else { return }
            self.answered(urls, after: ProcessInfo.processInfo.systemUptime - began, onChosen: onChosen)
        }
        watch(panel, since: began)
    }

    /// "Close It": the window is on screen but stopped responding. `cancel()` closes it even when its service hangs.
    func closeStuckWindow() {
        guard phase == .choosing else { return }
        note("file window: closed from SkyCut")
        end(.failed(.closedByUser), cancelWindow: true)
    }

    /// Nobody waits for the window any more (its sheet or panel went away): no window left behind.
    func cancelIfChoosing() {
        guard phase == .choosing else { return }
        end(.idle, cancelWindow: true)
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func answered(_ urls: [URL]?, after elapsed: TimeInterval, onChosen: ([URL]?) -> Void) {
        if let urls, !urls.isEmpty {
            end(.idle, cancelWindow: false)
            onChosen(urls)
        } else if elapsed < quickReturn {
            note(String(format: "file window: came back empty after %.2f s", elapsed))
            end(.failed(.returnedAtOnce), cancelWindow: false)
        } else {
            end(.idle, cancelWindow: false)
            onChosen(nil)
        }
    }

    /// The window has to be on screen; away for `appearDeadline` with no answer = failed (`begin` may never call back).
    private func watch(_ panel: FileChooserPanel, since began: TimeInterval) {
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
                    self.note("file window: not on screen and macOS never answered")
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

/// "A system file window has been open in process X": written before SkyCut asks AppKit for the window and cleared when
/// it answers or SkyCut quits normally. Still there in another process = the last run ended (force quit, crash) with
/// a window open — most likely frozen inside AppKit — so the next attempt starts with the typed path.
struct SystemFileWindowRecord: Sendable {
    /// Identity-class key: keeps the old SrtFlow prefix (docs/architecture/product-name.md). Every open / save window
    /// shares it since 2026-11-19 (it was the export folder window's alone: SrtFlow.export.folderChooserInFlight).
    static let key = "SrtFlow.fileWindowInFlight"
    static let shared = SystemFileWindowRecord(suiteName: nil)

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
