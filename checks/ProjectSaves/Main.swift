import AppKit
import Foundation
import SrtFlowCore
@testable import SrtFlow

// A project's own file is written off the main thread with a deadline (ProjectFileWriter), and closing, switching, Save As
// and Quit never wait on a drive on the main thread (docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md), on
// real App objects in an isolated bundle (scripts/check-project-saves.sh). The disk is a fake drive where it has to be slow,
// stuck or failing (`fileWriter.perform`): a stuck write waits on a gate the check opens, never longer than 3 s, so a write
// that runs on the main thread shows up as a long main-thread gap instead of hanging the check.
// - SaveChecks.swift: autosave, flush at the deadline, edits during a write, coalescing, a failing drive, a moved file.
// - CloseQuitChecks.swift: switching away, Save As, the AI's save_project, closing at once, Quit.
// - EditWhileClosingChecks.swift: an edit made while New / close / Quit is writing; Quit looking again; "Quit Anyway" and a
//   document opened since in the same project; a stale save window.
// - ReplaceChecks.swift: a file already at a chosen place is replaced only when the person confirmed it for that URL.
// - OffMainWriteChecks.swift: the subtitle editor's writes and a saved version's media never wait on the main thread.
// - UntitledMarkersChecks.swift: an untitled project with only a ruler marker and its note is asked about before it closes.

@MainActor
final class Checks {
    private(set) var count = 0
    private(set) var failures = 0

    func require(_ condition: Bool, _ message: String) {
        count += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

@main enum ProjectSaveChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.projectsavescheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Use the isolated project saves check bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        guard let workPath = ProcessInfo.processInfo.environment["SRTFLOW_PROJECT_SAVES_CHECK_DIR"] else {
            fatalError("SRTFLOW_PROJECT_SAVES_CHECK_DIR is required")
        }
        let root = URL(fileURLWithPath: workPath, isDirectory: true).resolvingSymlinksInPath()
        // Short deadlines: the check waits half a second where the App waits 15 s (Quit: 0.3 s where it waits 3 s).
        ProjectFileWriter.deadline = 0.5
        ProjectQuit.grace = 0.3
        let checks = Checks()
        await SaveChecks.run(checks, root: root)
        await CloseQuitChecks.run(checks, root: root)
        await EditWhileClosingChecks.run(checks, root: root)
        await ReplaceChecks.run(checks, root: root)
        await OffMainWriteChecks.run(checks, root: root)
        await UntitledMarkersChecks.run(checks, root: root)
        print("Project saves: \(checks.count) assertions, \(checks.failures) failures")
        exit(checks.failures == 0 ? 0 : 1)
    }
}

/// A project saved into the check's folder, in the background (no window).
@MainActor func makeProject(_ name: String, in root: URL) -> VideoEditProject {
    guard let project = OpenProjects.shared.newProject(
        savingAs: root.appendingPathComponent("\(name).skycut"), placement: .background
    ) else { fatalError("could not make \(name): \(OpenProjects.shared.failure ?? "")") }
    return project
}

/// One edit the file must carry: a title with `marker` as its text.
@MainActor func edit(_ project: VideoEditProject, _ marker: String) {
    _ = project.perform(rebuildsPreview: false) { state in
        state.textOverlays.append(TextOverlay(text: marker, timelineStart: 0, duration: 1, row: state.textOverlays.count))
    }
}

/// The project file on disk holds `marker`.
func fileHolds(_ url: URL?, _ marker: String) -> Bool {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.contains("\"\(marker)\"")
}

/// Polls every 20 ms until `condition` or `seconds` pass.
@MainActor func until(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > end { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// A drive the check controls: writes wait until the check opens the gate (at most 3 s), and are counted.
final class FakeDrive: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var started = 0
    private let failure: String?

    init(failing failure: String? = nil, opened: Bool = false) {
        self.failure = failure
        self.opened = opened
    }

    var perform: @Sendable (ProjectFileWriteRequest) -> ProjectFileWriteResult {
        { [self] request in
            condition.lock()
            started += 1
            let end = Date().addingTimeInterval(3)
            while !opened, condition.wait(until: end) {}
            condition.unlock()
            if let failure { return .failed(failure) }
            return ProjectFileWriter.write(request)
        }
    }

    /// How many writes reached the drive.
    var writes: Int {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The longest time the main thread was unavailable while measuring (the same meter as checks/ExportProfile's): a plain
/// thread posts a block to the main queue every 20 ms and times how long each took to run.
final class MainThreadGap: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: TimeInterval = 0
    private var pendingSince: TimeInterval?
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while isRunning {
                let sent = ProcessInfo.processInfo.systemUptime
                let landed = DispatchSemaphore(value: 0)
                lock.withLock { pendingSince = sent }
                DispatchQueue.main.async { landed.signal() }
                landed.wait()
                let waited = ProcessInfo.processInfo.systemUptime - sent
                lock.withLock { pendingSince = nil; worst = max(worst, waited) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    func stop() -> TimeInterval {
        lock.withLock {
            running = false
            let now = ProcessInfo.processInfo.systemUptime
            return max(worst, pendingSince.map { now - $0 } ?? 0)
        }
    }

    private var isRunning: Bool { lock.withLock { running } }
}
