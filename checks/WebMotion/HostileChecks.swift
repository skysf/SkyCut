import Foundation
import SrtFlowWebMotionKit

// Hostile pages through the real helper with tight limits: an endless loop (in a frame, at load) stops within its limit
// and takes its WebKit processes with it; a page error comes back verbatim with its time; a page that keeps state between
// frames fails "same t twice"; a page without motion.frame fails "frame entry"; a huge canvas changes nothing.

/// One helper run through the low-level runner (pids, peak memory, how long it took).
struct RawRun {
    let report: WebMotionHelperProcess.Report
    let seconds: Double

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
}

func runHelper(_ job: WebMotionJob, watch: WebMotionHelperProcess.Watch = .init()) async -> RawRun {
    let start = ProcessInfo.processInfo.systemUptime
    let helper = WebMotionRenderer.helperURL() ?? URL(fileURLWithPath: Fixture.helper)
    let report = await WebMotionHelperProcess().run(job.request(writingTo: job.output), helper: helper, watch: watch)
    try? FileManager.default.removeItem(at: job.output)
    return RawRun(report: report, seconds: elapsed(since: start))
}

enum HostileChecks {
    static func run() async {
        section("Hostile pages")
        let loop = await runHelper(Fixture.job(Pages.loopInFrame, name: "loop-frame", limits: Fixture.tight))
        let loopFailure = loop.rejected?.failure
        check(loopFailure?.check == .noTimeout && loopFailure?.message.contains("t = 0.500 s") == true
              && loopFailure?.time == 0.5,
              "an endless loop in frame(t) is stopped at its 2 s limit: \(loopFailure?.message ?? String(describing: loop.error))")
        check(loop.seconds < 20 && loop.processesEnded && loop.report.killedLeftovers.isEmpty,
              "…the helper ended in " + String(format: "%.1f", loop.seconds) + " s and its \(loop.report.processes.count) "
              + "WebKit processes ended with it")

        let atLoad = await runHelper(Fixture.job(Pages.loopAtLoad, name: "loop-load", limits: Fixture.tight))
        check(atLoad.rejected?.failure?.check == .noTimeout && atLoad.rejected?.check(.loads)?.passed == false,
              "an endless loop while loading is stopped at its 4 s load limit: \(atLoad.rejected?.failure?.message ?? String(describing: atLoad.error))")
        check(atLoad.seconds < 20 && atLoad.processesEnded, "…ended in " + String(format: "%.1f", atLoad.seconds) + " s, WebKit processes gone")

        let error = await runHelper(Fixture.job(Pages.errorInFrame, name: "error", limits: Fixture.tight))
        let errorFailure = error.rejected?.failure
        check(errorFailure?.check == .noPageErrors && errorFailure?.message.contains("Can't find variable: undefinedFunction") == true
              && errorFailure?.message.contains("while drawing t = 0.500 s") == true && errorFailure?.time == 0.5,
              "a page error comes back verbatim with its time: \(errorFailure?.message ?? String(describing: error.error))")

        let state = await runHelper(Fixture.job(Pages.keepsState, name: "state", limits: Fixture.tight))
        check(state.rejected?.failure?.check == .sameTwice,
              "a page that keeps state between frames fails \"same t twice\": \(state.rejected?.failure?.message.prefix(120) ?? "\(String(describing: state.error))")")

        let entry = await runHelper(Fixture.job(Pages.noFrameEntry, name: "entry", limits: Fixture.tight))
        check(entry.rejected?.failure?.check == .frameEntry, "a page without motion.frame(t) fails \"frame entry\"")

        let huge = await runHelper(Fixture.job(Pages.hugeCanvas, name: "huge", limits: Fixture.tight))
        let hugeResult: WebMotionResult? = {
            if case .finished(let result, _, _, _) = huge.report.outcome { return result }
            return nil
        }()
        check(hugeResult != nil && huge.processesEnded, "a 40000×40000 canvas neither crashes nor hangs the renderer "
            + "(\(hugeResult?.failure?.message ?? (hugeResult?.accepted == true ? "accepted" : String(describing: huge.error)))); "
            + huge.processSummary)
        check(huge.report.peakFootprint < 2 << 30, "…and the render stayed under 2 GB (peak \(huge.report.peakFootprint >> 20) MB)")
    }
}
