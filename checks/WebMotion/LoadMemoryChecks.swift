import Darwin
import Foundation
import SrtFlowWebMotionKit

// Bounded load/ready checks: one fixed 32 MiB buffer in the helper's first view, never the existing frame-memory hog.
@MainActor
enum LoadMemoryChecks {
    static func run() async {
        section("Load memory and process discovery")
        tracker()
        for (mode, alpha) in [("load", WebMotionAlphaPath.auto), ("ready", .public)] {
            await boundedPage(mode, alpha: alpha)
        }
        await ProcessRetryChecks.run()
    }

    private static func tracker() {
        var sources: [[Int32]] = [[0, -1]]
        var events: [[Int32]] = []
        var reads = 0
        let tracker = PageProcessTracker(read: { reads += 1; return sources.flatMap { $0 } }, emit: { events.append($0) })
        tracker.start()
        check(events.isEmpty, "discovery ignores unknown and negative process identifiers")
        sources[0] = [12, 12, 13]
        tracker.sample()
        tracker.sample()
        check(events == [[12, 13]], "shared and repeated PIDs emit one unique change-only batch")
        sources.append([13, 21])
        tracker.sample()
        sources[0] = [31]
        tracker.sample()
        check(events == [[12, 13], [21], [31]], "discovery reads live appended sources and replacement PIDs")
        sources.append([41, 41])
        let before = reads
        tracker.finish()
        check(events.last == [41] && reads == before + 1, "finishing performs exactly one final discovery scan")
        sources.append([51])
        tracker.sample()
        tracker.finish()
        check(events.last == [41] && reads == before + 1, "queued discovery callbacks after finish are no-ops")
    }

    private static func boundedPage(_ mode: String, alpha: WebMotionAlphaPath) async {
        let probe = Fixture.folder.appendingPathComponent("load-memory-\(mode).json")
        let previous = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_TEST_LOAD_PROBE"]
        Fixture.setEnvironment("SRTFLOW_WEB_MOTION_TEST_LOAD_PROBE", probe.path)
        defer { Fixture.setEnvironment("SRTFLOW_WEB_MOTION_TEST_LOAD_PROBE", previous) }
        let witness = LoadMemoryWitness(probe: probe)
        var watch = WebMotionHelperProcess.Watch()
        watch.interval = 0.05
        watch.memory.policy = WebMotionMemoryPolicy(budget: 512 << 20, warningBudget: 1 << 20)
        watch.memory.pressure = { witness.wasSampled ? .warning : .normal }
        watch.didSample = { witness.sample($0, footprint: $1) }
        let limits = WebMotionLimits(load: 4, script: 1, snapshot: 2, total: 15)
        let job = Fixture.job(page(mode), name: "load-memory-\(mode)", width: 64, height: 64, duration: 0.25,
                              layoutHeight: 120, limits: limits, alpha: alpha, workers: 1, samples: 1)
        let run = await boundedProcess(job, helper: URL(fileURLWithPath: Fixture.helper), watch: watch, within: 20)
        let observed = witness.snapshot
        check(observed.probe?.heldBytes == 32 << 20 && observed.identity != nil,
              "\(mode): the first locked view held exactly one 32 MiB buffer and exposed its exact WebContent PID")
        check(observed.sampled && observed.targetFootprint >= 32 << 20 && observed.consistent,
              "\(mode): live budget sampling included that WebContent and real footprint (target \(observed.targetFootprint >> 20) MiB)")
        check(run.killed?.reason == .memoryBudget && run.report.helperSignal == SIGKILL && !run.timedOut && observed.beforeDeadline,
              "\(mode): the real memory budget stopped the unresolved load/ready before its deadline: \(run.outcome)")
        check(!FileManager.default.fileExists(atPath: job.output.path), "\(mode): an unfinished ready produced no movie")
        if let identity = observed.identity { await waitForProcessEnd(identity) }
        check(observed.identity.map { $0.state != .here } == true && run.report.killedLeftovers.isEmpty,
              "\(mode): the target WebContent ended with the helper without an orphan")
        if let identity = observed.identity { stopOwnedProcess(identity) }
    }

    private static func page(_ mode: String) -> String {
        let allocate = """
          const a=new Uint8Array(32*1024*1024);
          for(let i=0;i<a.length;i+=4096)a[i]=1;
          window.__srtflowKeep=a;window.__srtflowHeldBytes=a.length;
        """
        let ready = mode == "ready" ? "new Promise(()=>{\(allocate)})" : "new Promise(()=>{})"
        return """
        <!doctype html><html><body><div style="width:20px;height:20px;background:white"></div><script>
        \(mode == "load" ? allocate : "")
        window.motion={ready:\(ready),frame(){}};
        </script></body></html>
        """
    }
}

private struct LoadProbe: Decodable {
    let pid: Int32
    let helper: Int32
    let heldBytes: Int
    let deadline: Double
}

private final class LoadMemoryWitness: @unchecked Sendable {
    struct Snapshot {
        var probe: LoadProbe?
        var identity: WebMotionProcessIdentity?
        var sampled = false
        var targetFootprint: UInt64 = 0
        var consistent = false
        var beforeDeadline = false
    }
    private let lock = NSLock()
    private let probeURL: URL
    private var value = Snapshot()

    init(probe: URL) { probeURL = probe }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    var wasSampled: Bool { snapshot.sampled }

    // Called on the production watch's GCD queue, after its actual kernel footprint read and before its pressure verdict.
    func sample(_ pids: [Int32], footprint: UInt64) {
        guard let data = try? Data(contentsOf: probeURL), let probe = try? JSONDecoder().decode(LoadProbe.self, from: data),
              let identity = WebMotionProcessIdentity.current(probe.pid) else { return }
        let target = WebMotionMemoryWatch.footprint(of: [probe.pid])
        let helper = WebMotionMemoryWatch.footprint(of: [probe.helper])
        lock.lock()
        defer { lock.unlock() }
        value.probe = probe
        value.identity = value.identity ?? identity
        if pids.contains(probe.pid), isRunning(probe.helper), probe.heldBytes == 32 << 20 {
            value.sampled = true
            value.targetFootprint = target
            value.consistent = footprint + (4 << 20) >= target + helper
            value.beforeDeadline = ProcessInfo.processInfo.systemUptime < probe.deadline
        }
    }
}

// A native cancellation watchdog owns only this runner, rather than finding processes by a global name/path scan.
func boundedProcess(_ job: WebMotionJob, helper: URL, watch: WebMotionHelperProcess.Watch,
                    within limit: Double) async -> RawRun {
    let start = ProcessInfo.processInfo.systemUptime
    let operation = Task { await WebMotionHelperProcess().run(job.request(writingTo: job.output), helper: helper, watch: watch) }
    let expiry = Task { () -> Bool in
        try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
        guard !Task.isCancelled else { return false }
        operation.cancel()
        return true
    }
    let report = await operation.value
    expiry.cancel()
    return RawRun(report: report, seconds: elapsed(since: start), timedOut: await expiry.value)
}

func waitForProcessEnd(_ identity: WebMotionProcessIdentity) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while identity.state == .here, ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}

func stopOwnedProcess(_ identity: WebMotionProcessIdentity) {
    if WebMotionProcessIdentity.current(identity.pid) == identity { kill(identity.pid, SIGKILL) }
}
