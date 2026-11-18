import Darwin
import Foundation
import SrtFlowWebMotionKit

// MARK: - One run of skycut-web-motion, watched from SkyCut
//
// Owns: starting the helper, handing it the request on stdin, reading its event lines, and the watch that can end it:
// - memory: every `interval`, the render's footprint and the Mac's pressure go to `WebMotionMemoryPolicy`; a kill
//   verdict SIGKILLs the helper (its WebKit processes end with it);
// - backstops for a helper that stopped enforcing its own limits: no event for longer than its slowest single step
//   allows (+ grace), or past its total limit (+ grace);
// - cancellation of the awaiting task.
// Afterwards the WebKit processes it reported are made to end (`WebMotionProcessTeardown`).
// Nothing here blocks a Swift-concurrency thread: the pipes are read on GCD threads, the exit arrives through
// `terminationHandler` (docs/architecture/blocking-media-reads.md「子进程的异步退出」), the watch runs on its own queue.
// Does not own: what the result means (`WebMotionRenderer`). docs/architecture/web-motion-renderer.md.

/// SkyCut stopped the render.
struct WebMotionKill: Sendable, Equatable, CustomStringConvertible {
    enum Reason: String, Sendable {
        case memoryBudget, memoryPressure, stalled, overTime
    }

    let reason: Reason
    let footprint: UInt64
    let message: String

    var description: String { message }
}

final class WebMotionHelperProcess: @unchecked Sendable {
    struct Watch: Sendable {
        var memory: WebMotionMemoryWatch = .standard
        /// Added to the helper's own limits before SkyCut steps in.
        var grace: Double = 10
        var interval: Double = 0.25
        /// How long the WebKit processes get to end after the helper before SkyCut kills them.
        var teardownGrace: Double = 3
        var identityReader: @Sendable (Int32, UInt64) -> WebMotionProcessIdentity? = {
            WebMotionProcessIdentity.current($0, bornNoLaterThan: $1)
        }
        /// Observes real live watch samples; final cleanup retries never call this hook.
        var didSample: (@Sendable ([Int32], UInt64) -> Void)?
    }

    enum Outcome: Sendable {
        case finished(result: WebMotionResult?, status: Int32, signaled: Bool, log: String)
        case killed(WebMotionKill, log: String)
        case cancelled
    }

    struct Report: Sendable {
        let outcome: Outcome
        let peakFootprint: UInt64
        /// Safely identified reported WebKit processes (all ended or killed by the time this returns).
        /// An unresolved raw PID is not ownership and never enters teardown history.
        let processes: [Int32]
        /// WebKit processes still running after the grace period, killed by SkyCut (normally none).
        let killedLeftovers: [Int32]
        /// The signal that ended the helper (SIGKILL when SkyCut stopped it); nil when it exited by itself.
        let helperSignal: Int32?
    }

    private let lock = NSLock()
    private let process = Process()
    private var exited = false
    private var cancelled = false
    private var kill: WebMotionKill?
    private var result: WebMotionResult?
    private var processes: [WebMotionProcessIdentity] = []
    private var firstReported: [Int32: UInt64] = [:]
    private var lastEvent = ProcessInfo.processInfo.systemUptime
    private var peakFootprint: UInt64 = 0
    private var pending = Data()
    private let log = LogTail()

    func run(_ request: WebMotionRequest, helper: URL, watch: Watch) async -> Report {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.qualityOfService = .userInitiated
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { [self] _ in
            withLock { exited = true }
            group.leave()
        }
        read(output, into: group) { [self] chunk in received(chunk, identityReader: watch.identityReader) }
        read(errors, into: group) { [self] chunk in log.append(chunk) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            group.leave()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            return Report(outcome: .finished(result: nil, status: -1, signaled: false,
                                             log: "The renderer could not start: \(error.localizedDescription)"),
                          peakFootprint: 0, processes: [], killedLeftovers: [], helperSignal: nil)
        }
        send(request, to: input)
        let timer = startWatch(request.limits, watch)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global(qos: .userInitiated)) { done.resume() }
            }
        } onCancel: { [self] in
            withLock { cancelled = true }
            stop()
        }
        await finishWatch(timer)
        pinReported(using: watch.identityReader)
        let status = process.terminationStatus
        let signaled = process.terminationReason == .uncaughtSignal
        let (identities, outcome, peak) = withLock { () -> ([WebMotionProcessIdentity], Outcome, UInt64) in
            if cancelled { return (processes, .cancelled, peakFootprint) }
            if let kill { return (processes, .killed(kill, log: log.text), peakFootprint) }
            return (processes, .finished(result: result, status: status, signaled: signaled, log: log.text), peakFootprint)
        }
        let leftovers = await WebMotionProcessTeardown.ensureGone(identities, grace: watch.teardownGrace)
        return Report(outcome: outcome, peakFootprint: peak, processes: identities.map(\.pid), killedLeftovers: leftovers,
                      helperSignal: signaled ? status : nil)
    }

    // MARK: Watch

    private func startWatch(_ limits: WebMotionLimits, _ watch: Watch) -> DispatchSourceTimer {
        let started = ProcessInfo.processInfo.systemUptime
        // The longest a healthy helper goes without an event: one page load, or one frame (script + two snapshots).
        let quiet = max(limits.load, limits.script + 2 * limits.snapshot) + watch.grace
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SrtFlow.webMotion.watch", qos: .userInitiated))
        timer.schedule(deadline: .now() + watch.interval, repeating: watch.interval)
        timer.setEventHandler { [self] in
            pinReported(using: watch.identityReader)
            let now = ProcessInfo.processInfo.systemUptime
            let pids = withLock { [process.processIdentifier] + processes.map(\.pid) }
            let footprint = WebMotionMemoryWatch.footprint(of: pids)
            if !withLock({ exited }) { watch.didSample?(pids, footprint) }
            let verdict = watch.memory.policy.verdict(pressure: watch.memory.pressure(), footprint: footprint)
            let silent = now - withLock { lastEvent }
            let decision: WebMotionKill?
            switch verdict {
            case .machineCritical:
                decision = WebMotionKill(reason: .memoryPressure, footprint: footprint,
                                         message: "SkyCut stopped the render: the Mac is out of memory (the render used \(megabytes(footprint)) MB).")
            case .overBudget(let limit), .overWarningBudget(let limit):
                decision = WebMotionKill(reason: .memoryBudget, footprint: footprint,
                                         message: "SkyCut stopped the render: the page used \(megabytes(footprint)) MB, more than the "
                                             + "\(megabytes(limit)) MB a motion page may use\(verdict == .overBudget(limit: limit) ? "" : " while the Mac is low on memory").")
            case .keepGoing where now - started > limits.total + watch.grace:
                decision = WebMotionKill(reason: .overTime, footprint: footprint,
                                         message: "SkyCut stopped the render: it ran past its \(Int(limits.total)) s limit.")
            case .keepGoing where silent > quiet:
                decision = WebMotionKill(reason: .stalled, footprint: footprint,
                                         message: "SkyCut stopped the render: the renderer made no progress for \(Int(silent)) s.")
            case .keepGoing:
                decision = nil
            }
            withLock {
                peakFootprint = max(peakFootprint, footprint)
                if let decision, kill == nil { kill = decision }
            }
            if decision != nil { stop() }
        }
        timer.resume()
        return timer
    }

    /// The cancel handler runs after any in-flight handler on the timer's serial queue. Await it before the final
    /// identity snapshot, so a slow lookup cannot append an owned process after teardown has taken its input.
    private func finishWatch(_ timer: DispatchSourceTimer) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.setCancelHandler { done.resume() }
            timer.cancel()
        }
    }

    private func stop() {
        let running = withLock { !exited }
        if running, process.processIdentifier > 0 { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }

    // MARK: Pipes

    /// The request goes in whole, then stdin closes. A helper that died early must not take SkyCut down with SIGPIPE:
    /// the write end is set to fail with EPIPE instead (`F_SETNOSIGPIPE`).
    private func send(_ request: WebMotionRequest, to pipe: Pipe) {
        let data = (try? JSONEncoder().encode(request)) ?? Data()
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(handle.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
                }
            }
            try? handle.close()
        }
    }

    private func read(_ pipe: Pipe, into group: DispatchGroup, _ consume: @escaping (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                consume(chunk)
            }
            group.leave()
        }
    }

    private func received(_ chunk: Data, identityReader: @Sendable (Int32, UInt64) -> WebMotionProcessIdentity?) {
        let receivedAt = mach_absolute_time()
        var events: [WebMotionEvent] = []
        withLock {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let event = try? JSONDecoder().decode(WebMotionEvent.self, from: line) { events.append(event) }
            }
        }
        for event in events { handle(event, receivedAt: receivedAt, identityReader: identityReader) }
    }

    private func handle(_ event: WebMotionEvent, receivedAt: UInt64,
                        identityReader: @Sendable (Int32, UInt64) -> WebMotionProcessIdentity?) {
        withLock {
            for pid in event.processes ?? [] where pid > 0 && firstReported[pid] == nil { firstReported[pid] = receivedAt }
            lastEvent = ProcessInfo.processInfo.systemUptime
            if event.kind == .result { result = event.result }
        }
        pinReported(using: identityReader)
    }

    private func pinReported(using reader: @Sendable (Int32, UInt64) -> WebMotionProcessIdentity?) {
        let candidates = withLock { firstReported.filter { pid, _ in !processes.contains(where: { $0.pid == pid }) } }
        let found = candidates.compactMap { reader($0.key, $0.value) }
        withLock {
            for identity in found where !processes.contains(where: { $0.pid == identity.pid }) { processes.append(identity) }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The last 64 KB of the helper's stderr (WebKit and system logging), for failures nobody expected.
private final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 64 * 1024

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
