import Foundation
import SrtFlowWebMotionKit

// SkyCut's side of the watch: a page eating memory is killed at the budget and its WebKit processes end; "the Mac is
// out of memory" (injected: simulating real pressure would squeeze every app on a shared Mac) kills a normal render;
// low memory kills over the smaller budget; and the two backstops stop a helper that keeps no limits of its own.

enum MemoryChecks {
    static func run() async {
        section("Memory and backstops")
        let pressure = WebMotionMemoryWatch.systemPressure()
        check(WebMotionMemoryWatch.footprint(of: [getpid()]) > 0, "the footprint reading works (this process: "
            + "\(WebMotionMemoryWatch.footprint(of: [getpid()]) >> 20) MB, the Mac's pressure now: \(pressure))")
        await hog()
        await injectedPressure()
        await backstops()
    }

    private static func hog() async {
        var watch = WebMotionHelperProcess.Watch()
        watch.interval = 0.05
        watch.memory.policy = WebMotionMemoryPolicy(budget: 600 << 20, warningBudget: 600 << 20)
        let run = await runHelper(Fixture.job(Pages.memoryHog, name: "hog", limits: Fixture.tight, workers: 1), watch: watch,
                                  within: 40)
        check(run.killed?.reason == .memoryBudget && (run.killed?.footprint ?? 0) > 600 << 20 && run.report.helperSignal == SIGKILL,
              "a page eating 128 MB a frame is killed (SIGKILL) past its budget: \(run.killed?.message ?? run.outcome)")
        check(run.processesEnded && run.report.killedLeftovers.isEmpty && !run.report.processes.isEmpty,
              "…its \(run.report.processes.count) WebKit processes ended with the helper (peak \(run.report.peakFootprint >> 20) MB, "
              + String(format: "%.1f", run.seconds) + " s; " + run.processSummary + ")")
    }

    private static func injectedPressure() async {
        var critical = WebMotionHelperProcess.Watch()
        critical.memory.pressure = { .critical }
        let out = await runHelper(Fixture.job(Pages.plain, name: "critical", limits: Fixture.tight), watch: critical, within: 40)
        check(out.killed?.reason == .memoryPressure && out.report.helperSignal == SIGKILL && out.seconds < 10 && out.processesEnded,
              "the Mac out of memory: SkyCut kills a normal render at once: \(out.killed?.message ?? out.outcome)")
        var low = WebMotionHelperProcess.Watch()
        low.memory.pressure = { .warning }
        low.memory.policy = WebMotionMemoryPolicy(budget: 3 << 30, warningBudget: 1 << 20)
        let warned = await runHelper(Fixture.job(Pages.plain, name: "warning", limits: Fixture.tight), watch: low, within: 40)
        check(warned.killed?.reason == .memoryBudget && warned.report.helperSignal == SIGKILL
              && warned.killed?.message.contains("low on memory") == true,
              "low memory: over the smaller budget is killed: \(warned.killed?.message ?? warned.outcome)")
    }

    /// Fake helpers that keep no limits: one silent, one chatty forever. Both loop in the script's own shell (no exec), so
    /// a run that outlives its bound can still be stopped by the script's path.
    private static func backstops() async {
        let silent = script("silent", "while true; do /bin/sleep 1; done")
        let chatty = script("chatty", "while true; do echo '{\"kind\":\"progress\"}'; /bin/sleep 0.2; done")
        let limits = WebMotionLimits(load: 1, script: 0.5, snapshot: 1, total: 5)
        var watch = WebMotionHelperProcess.Watch()
        watch.grace = 1
        watch.interval = 0.1
        Fixture.setEnvironment("SRTFLOW_WEB_MOTION_HELPER", silent.path)
        let stalled = await runHelper(Fixture.job(Pages.plain, name: "stalled", limits: limits), watch: watch, within: 20)
        Fixture.setEnvironment("SRTFLOW_WEB_MOTION_HELPER", chatty.path)
        let late = await runHelper(Fixture.job(Pages.plain, name: "late", limits: limits), watch: watch, within: 20)
        Fixture.setEnvironment("SRTFLOW_WEB_MOTION_HELPER", Fixture.helper)
        check(stalled.killed?.reason == .stalled && stalled.seconds >= 3 && stalled.seconds < 10,
              "a helper that goes silent is killed after its quiet limit (3.5 s): "
              + String(format: "%.1f", stalled.seconds) + " s, \(stalled.killed?.message ?? stalled.outcome)")
        check(late.killed?.reason == .overTime && late.seconds >= 5 && late.seconds < 12,
              "a helper that never finishes is killed after its total limit (5 s + 1 s): "
              + String(format: "%.1f", late.seconds) + " s, \(late.killed?.message ?? late.outcome)")
    }

    private static func script(_ name: String, _ body: String) -> URL {
        let url = Fixture.folder.appendingPathComponent("fake-\(name).sh")
        try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
}
