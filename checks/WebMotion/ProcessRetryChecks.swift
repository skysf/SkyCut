import Darwin
import Foundation
import SrtFlowWebMotionKit

// One reported owned child and a release barrier make identity retry observable during the live watch. No PID reuse,
// global process search, unbounded wait or memory load is needed; independent identity cleanup also runs on red checks.
@MainActor
enum ProcessRetryChecks {
    static func run() async {
        for mode in RetryWitness.Mode.allCases { await exercise(mode) }
    }

    private static func exercise(_ mode: RetryWitness.Mode) async {
        let folder = Fixture.folder.appendingPathComponent("pid-\(mode.rawValue)")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { check(false, "the PID fixture could not create its temporary folder: \(error)"); return }
        let script = folder.appendingPathComponent("helper.sh")
        do {
            try helper(repeated: mode == .repeated).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { check(false, "the PID fixture could not prepare its helper: \(error)"); return }
        let witness = RetryWitness(mode: mode, folder: folder, earlierCutoff: mach_absolute_time())
        var watch = WebMotionHelperProcess.Watch()
        watch.interval = 0.05
        watch.teardownGrace = 0.1
        watch.memory.pressure = { .normal }
        watch.identityReader = { witness.identity($0, cutoff: $1) }
        watch.didSample = { witness.sample($0, footprint: $1) }
        let job = Fixture.job(Pages.plain, name: "pid-\(mode.rawValue)", limits: Fixture.tight, workers: 1)
        let operation = Task { await boundedProcess(job, helper: script, watch: watch, within: 8) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline, !witness.readyToRelease {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        witness.release()
        let run = await operation.value
        let observed = witness.snapshot
        defer { if let identity = observed.owned { stopOwnedProcess(identity) } }
        let exitedNormally: Bool
        if case .finished(_, let status, let signaled, _) = run.report.outcome { exitedNormally = status == 0 && !signaled }
        else { exitedNormally = false }
        check(observed.owned != nil && !run.timedOut && exitedNormally,
              "\(mode.rawValue): the finite PID fixture exited normally and identified its independently owned child")
        switch mode {
        case .retry:
            check(observed.attempts >= 2 && observed.failedFirst,
                  "a reported PID whose first identity lookup failed was retried")
            check(observed.sampledBeforeRelease, "identity retry put the child in actual budget sampling while the helper was alive")
            check(observed.owned.map { run.report.processes.contains($0.pid) } == true,
                  "a safely pinned child remains in the teardown history")
        case .tooNew:
            check(observed.ordinaryRead && observed.bornReadRejected,
                  "a real child born after an earlier cutoff is readable normally but rejected by the bounded lookup")
            check(!observed.sampledBeforeRelease && observed.owned.map { !run.report.processes.contains($0.pid) } == true,
                  "a post-receipt identity is never pinned or included in live budget sampling")
            check(observed.owned.map { !run.report.killedLeftovers.contains($0.pid) && $0.state == .here } == true,
                  "an unowned post-receipt child is not signalled by runner teardown")
        case .repeated:
            check(observed.attempts >= 2 && observed.cutoffs.count == 1
                    && FileManager.default.fileExists(atPath: folder.appendingPathComponent("repeated").path),
                  "retries and repeated cumulative PID reports preserve the original receipt ceiling")
        }
        if let identity = observed.owned {
            stopOwnedProcess(identity)
            await waitForProcessEnd(identity)
            check(identity.state != .here, "\(mode.rawValue): identity-safe fixture cleanup leaves no child behind")
        }
    }

    private static func helper(repeated: Bool) -> String {
        let repeatEvent = #"""
        attempt=0
        while [ ! -f "$directory/first-reader" ] && [ "$attempt" -lt 80 ]; do
          /bin/sleep 0.05
          attempt=$((attempt+1))
        done
        [ -f "$directory/first-reader" ] || exit 3
        printf '{"kind":"processes","processes":[%s]}\n' "$child"
        : > "$directory/repeated"
        """#
        return """
        #!/bin/sh
        directory="${0%/*}"
        /bin/sleep 10 </dev/null >/dev/null 2>&1 &
        child=$!
        printf '%s %s\\n' "$$" "$child" > "$directory/info"
        printf '{"kind":"processes","processes":[%s]}\\n' "$child"
        \(repeated ? repeatEvent : "")
        attempt=0
        while [ ! -f "$directory/release" ] && [ "$attempt" -lt 80 ]; do
          /bin/sleep 0.05
          attempt=$((attempt+1))
        done
        exit 0
        """
    }
}

private final class RetryWitness: @unchecked Sendable {
    enum Mode: String, CaseIterable { case retry, tooNew, repeated }
    struct Snapshot {
        var owned: WebMotionProcessIdentity?
        var attempts = 0
        var failedFirst = false
        var sampledBeforeRelease = false
        var ordinaryRead = false
        var bornReadRejected = false
        var cutoffs: Set<UInt64> = []
        var samples = 0
    }
    private let lock = NSLock()
    private let mode: Mode
    private let folder: URL
    private let earlierCutoff: UInt64
    private var value = Snapshot()
    private var released = false

    init(mode: Mode, folder: URL, earlierCutoff: UInt64) {
        self.mode = mode
        self.folder = folder
        self.earlierCutoff = earlierCutoff
    }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    var readyToRelease: Bool {
        let value = snapshot
        switch mode {
        case .retry: return value.sampledBeforeRelease
        case .tooNew: return value.owned != nil && value.samples >= 4
        case .repeated: return value.owned != nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent("repeated").path)
        }
    }

    func identity(_ pid: Int32, cutoff: UInt64) -> WebMotionProcessIdentity? {
        lock.lock()
        value.attempts += 1
        value.cutoffs.insert(cutoff)
        let fail = mode == .repeated || (mode == .retry && value.attempts == 1)
        if mode == .retry && fail { value.failedFirst = true }
        let acknowledge = mode == .repeated && value.attempts == 1
        lock.unlock()
        // A second report cannot share the first pipe chunk: its helper waits until this reader handled the first.
        if acknowledge { try? Data().write(to: folder.appendingPathComponent("first-reader"), options: .atomic) }
        if fail { return nil }
        return WebMotionProcessIdentity.current(pid, bornNoLaterThan: mode == .tooNew ? min(cutoff, earlierCutoff) : cutoff)
    }

    func sample(_ pids: [Int32], footprint: UInt64) {
        guard let info = try? String(contentsOf: folder.appendingPathComponent("info"), encoding: .utf8) else { return }
        let ids = info.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        guard ids.count == 2, let child = WebMotionProcessIdentity.current(ids[1]) else { return }
        let rejected = WebMotionProcessIdentity.current(ids[1], bornNoLaterThan: earlierCutoff) == nil
        lock.lock()
        defer { lock.unlock() }
        value.owned = value.owned ?? child
        value.ordinaryRead = true
        value.bornReadRejected = rejected
        value.samples += 1
        if !released, pids.contains(child.pid), isRunning(ids[0]), footprint > 0 { value.sampledBeforeRelease = true }
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
        try? Data().write(to: folder.appendingPathComponent("release"), options: .atomic)
    }
}
