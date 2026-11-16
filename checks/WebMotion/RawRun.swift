import Foundation
import SrtFlowWebMotionKit

// One helper run through SkyCut's low-level runner (`WebMotionHelperProcess`), so a check can see the pids, the peak
// memory and how long it took — bounded: a run that outlives `within` (a sabotaged lock, a backstop that no longer fires)
// is stopped by killing the processes started from that helper path (only this check's own helper or fake scripts) and
// reported as timed out, instead of hanging the check until its 600 s watchdog.

struct RawRun {
    let report: WebMotionHelperProcess.Report
    let seconds: Double
    let timedOut: Bool

    var error: WebMotionRenderError? {
        do {
            _ = try WebMotionRenderer.accepted(report.outcome)
            return nil
        } catch let error as WebMotionRenderError {
            return error
        } catch {
            return nil
        }
    }

    var rejected: WebMotionResult? {
        if case .rejected(let result)? = error { return result }
        return nil
    }

    var killed: WebMotionKill? {
        if case .killed(let kill)? = error { return kill }
        return nil
    }

    /// Every WebKit process the helper reported has ended.
    var processesEnded: Bool { report.processes.allSatisfy { !isRunning($0) } }

    /// Each reported process, its name and whether it still runs (for failure messages).
    var processSummary: String {
        report.processes.map { pid in
            "\(pid) \(WebMotionProcessIdentity.current(pid)?.name ?? "-") \(isRunning(pid) ? "RUNNING" : "ended")"
        }.joined(separator: ", ") + "; killed by SkyCut: \(report.killedLeftovers)"
    }

    /// What went wrong, for messages: timed out first, then the error.
    var outcome: String { timedOut ? "the run did not end within its bound (stopped by the check)" : String(describing: error) }
}

func runHelper(_ job: WebMotionJob, watch: WebMotionHelperProcess.Watch = .init(), within limit: Double = 90) async -> RawRun {
    let start = ProcessInfo.processInfo.systemUptime
    let helper = WebMotionRenderer.helperURL() ?? URL(fileURLWithPath: Fixture.helper)
    let expiry = Task.detached { () -> Bool in
        try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
        guard !Task.isCancelled else { return false }
        await stopProcesses(startedFrom: helper)
        return true
    }
    let report = await WebMotionHelperProcess().run(job.request(writingTo: job.output), helper: helper, watch: watch)
    expiry.cancel()
    let timedOut = await expiry.value
    try? FileManager.default.removeItem(at: job.output)
    return RawRun(report: report, seconds: elapsed(since: start), timedOut: timedOut)
}

/// `pkill -9 -f <path>`: the path is this check's own build product or a script in its scratch folder.
func stopProcesses(startedFrom path: URL) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", path.path]
        process.terminationHandler = { _ in done.resume() }
        do { try process.run() } catch { done.resume() }
    }
}
