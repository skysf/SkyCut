import Foundation
import SrtFlowWebMotionKit

// Hostile pages through the real helper with tight limits: an endless loop (in a frame, at load) stops within its limit
// and takes its WebKit processes with it; a page error comes back verbatim with its time; a page that keeps state between
// frames fails "same t twice"; a page without motion.frame fails "frame entry"; a huge canvas changes nothing.

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

        let flicker = await runHelper(Fixture.job(Pages.flicker, name: "flicker", limits: Fixture.tight))
        check(flicker.rejected?.failure?.check == .noBlankFrames && flicker.rejected?.failure?.time == 0.5,
              "one empty frame between drawn frames fails \"no empty frame\" at t = 0.5: "
              + (flicker.rejected?.failure?.message ?? String(describing: flicker.error)))

        let huge = await runHelper(Fixture.job(Pages.hugeCanvas, name: "huge", limits: Fixture.tight))
        let hugeResult: WebMotionResult? = {
            if case .finished(let result, _, _, _) = huge.report.outcome { return result }
            return nil
        }()
        check(hugeResult != nil && huge.processesEnded, "a 40000×40000 canvas neither crashes nor hangs the renderer "
            + "(\(hugeResult?.failure?.message ?? (hugeResult?.accepted == true ? "accepted" : String(describing: huge.error)))); "
            + huge.processSummary)
        check(huge.report.peakFootprint < 2 << 30, "…and the render stayed under 2 GB (peak \(huge.report.peakFootprint >> 20) MB)")
        await oversizedRequest()
    }

    /// The helper re-checks every request itself: a duration whose frame count overflows Int is refused in plain words,
    /// not a crash SkyCut can only report as "stopped by the system" (docs/bugfixes/2026-11-19-web-motion-huge-duration-quits-app.md).
    /// The duration is changed after the request is made, so only the helper ever sees it.
    private static func oversizedRequest() async {
        let job = Fixture.job(Pages.plain, name: "huge-duration", limits: Fixture.tight)
        var request = job.request(writingTo: job.output)
        request.duration = 1e20
        let report = await WebMotionHelperProcess().run(request, helper: URL(fileURLWithPath: Fixture.helper), watch: .init())
        guard case .finished(let result, let status, let signaled, let log) = report.outcome else {
            return check(false, "a 10^20 s request ends with a result, not \(report.outcome)")
        }
        let message = result?.failure?.message ?? ""
        check(!signaled && status == WebMotionExitCode.invalidRequest
              && message.contains("The duration must be more than 0 and at most 60 seconds."),
              "the helper refuses a 10^20 s request in plain words (exit \(status), signaled \(signaled)): "
              + (message.isEmpty ? String(log.suffix(200)) : message))
        check(!FileManager.default.fileExists(atPath: job.output.path), "…and writes no movie")
    }
}
