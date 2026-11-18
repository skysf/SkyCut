import Darwin
import Foundation
import SrtFlowWebMotionKit

// MARK: - What the helper has found so far, and the one way out of the process
//
// Owns: the result being built (checks, first failure, page errors, hashes, versions, timing), the stdout events, and
// `finish`: every exit — accepted, rejected, a time limit, an internal failure, the parent gone — prints the result line
// first, then cleans up and exits. Also the time limits (`within`, the total limit) and the parent watch.
// Does not own: deciding the checks (`HelperRun`), drawing (`PageWorker`). docs/architecture/web-motion-renderer.md.

/// The page failed a check: the render is rejected with this text (exit 1).
struct PageFailure: Error {
    let check: WebMotionCheckName
    let message: String
    let time: Double?
}

@MainActor
final class HelperReport {
    static let shared = HelperReport()

    private var checks: [WebMotionCheckName: WebMotionCheck] = [:]
    private(set) var failure: WebMotionFailure?
    private var pageErrors: [String] = []
    var frameCount = 0
    var frameHashes: [String] = []
    var blankFrames: [Int] = []
    var alpha: WebMotionAlphaReport?
    var transparent = true
    var versions: WebMotionVersions?
    var timing = WebMotionTiming()
    private var processes: [Int32] = []
    private var cleanups: [() -> Void] = []
    private var finished = false
    var beforeFinish: (() -> Void)?
    let started = ProcessInfo.processInfo.systemUptime

    var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

    func pass(_ name: WebMotionCheckName, _ detail: String) {
        checks[name] = WebMotionCheck(name: name, passed: true, detail: detail)
    }

    /// The first failure is the one reported; later ones only mark their check.
    func fail(_ failure: PageFailure) {
        checks[failure.check] = WebMotionCheck(name: failure.check, passed: false, detail: failure.message)
        if self.failure == nil {
            self.failure = WebMotionFailure(check: failure.check, message: failure.message, time: failure.time)
        }
    }

    func addPageErrors(_ errors: [String]) {
        for error in errors where pageErrors.count < WebMotionResult.maxPageErrors { pageErrors.append(error) }
    }

    func addProcesses(_ pids: [Int32]) {
        let new = Set(pids.filter { $0 > 0 }).subtracting(processes).sorted()
        guard !new.isEmpty else { return }
        processes += new
        emit(WebMotionEvent(kind: .processes, processes: processes))
    }

    func progress(_ stage: String, done: Int, total: Int) {
        emit(WebMotionEvent(kind: .progress, stage: stage, done: done, total: total))
    }

    func onExit(_ cleanup: @escaping () -> Void) { cleanups.append(cleanup) }

    private func emit(_ event: WebMotionEvent) {
        FileHandle.standardOutput.write(event.line())
    }

    func result(accepted: Bool) -> WebMotionResult {
        WebMotionResult(
            accepted: accepted,
            checks: WebMotionCheckName.allCases.map { checks[$0] ?? WebMotionCheck(name: $0, passed: nil, detail: "Not reached.") },
            failure: failure, pageErrors: pageErrors, frameCount: frameCount, frameHashes: frameHashes,
            blankFrames: blankFrames, alpha: alpha, transparent: transparent, versions: versions, timing: timing,
            webKitProcesses: processes)
    }

    /// Prints the result line once, runs the cleanups, exits.
    func finish(_ code: Int32) -> Never {
        if !finished {
            finished = true
            beforeFinish?()
            beforeFinish = nil
            timing.totalSeconds = elapsed
            emit(WebMotionEvent(kind: .result, result: result(accepted: code == WebMotionExitCode.accepted)))
            cleanups.forEach { $0() }
            lingerForChecks()
        }
        exit(code)
    }

    /// Checks only (`SRTFLOW_WEB_MOTION_TEST_LINGER`, seconds, at most 10): keep the pages alive a little after the
    /// result, so a lock that failed has time to leak to the check's listener before the process is gone (a page
    /// rejected at load would otherwise end its own attempts by exiting at once).
    private func lingerForChecks() {
        guard let value = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_TEST_LINGER"],
              let seconds = Double(value), seconds > 0 else { return }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: min(seconds, 10)))
    }

    /// A time limit was hit: the render stops here, whatever is still running in the page.
    func timeLimit(_ message: String, check: WebMotionCheckName?, time: Double?) -> Never {
        if let check, check != .noTimeout {
            checks[check] = WebMotionCheck(name: check, passed: false, detail: message)
        }
        fail(PageFailure(check: .noTimeout, message: message, time: time))
        finish(WebMotionExitCode.timeLimit)
    }

    /// The renderer itself could not work (not the page's fault).
    func internalFailure(_ message: String) -> Never {
        if failure == nil { failure = WebMotionFailure(check: .loads, message: message, time: nil) }
        finish(WebMotionExitCode.internalFailure)
    }
}

/// Time limits that end the process. The page's JavaScript runs in WebKit's own process, so the helper's main thread
/// stays free while a page loops forever, and these timers fire on time (the probe's first version waited inside a task
/// group for the stuck call and hung until the total limit).
@MainActor
enum Deadline {
    static func within<T>(_ seconds: Double, _ message: String, check: WebMotionCheckName? = nil, time: Double? = nil,
                          _ work: () async throws -> T) async throws -> T {
        let expire: @Sendable () -> Void = {
            MainActor.assumeIsolated { () -> Void in HelperReport.shared.timeLimit(message, check: check, time: time) }
        }
        let timer = DispatchWorkItem(block: expire)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        return try await work()
    }

    static func startTotal(_ seconds: Double) {
        let expire: @Sendable () -> Void = {
            MainActor.assumeIsolated { () -> Void in
                HelperReport.shared.timeLimit("The whole render took longer than \(format(seconds)) s.", check: nil, time: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: expire)
    }

    /// SkyCut gone (the helper was handed to launchd): stop rather than render for nobody.
    static func watchParent() {
        let parent = getppid()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard getppid() != parent else { return }
            MainActor.assumeIsolated { () -> Void in
                HelperReport.shared.internalFailure("SkyCut is no longer running; the render stopped.")
            }
        }
    }

    static func format(_ seconds: Double) -> String { String(format: "%g", seconds) }
}
