import Foundation
import SrtFlowWebMotionKit

// Shared bits of the web-motion checks: the tally, the scratch folder, building jobs, and the heartbeat that proves
// SkyCut's main thread kept running while hostile pages were rendered (this check program stands in for SkyCut).

final class Tally: @unchecked Sendable {
    static let shared = Tally()
    private let lock = NSLock()
    private(set) var passed = 0
    private(set) var failures: [String] = []

    func record(_ condition: Bool, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if condition { passed += 1 } else { failures.append(message) }
        print("  \(condition ? "✓" : "✗") \(message)")
    }
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    Tally.shared.record(condition, message())
}

func section(_ title: String) {
    print("==> \(title)")
}

enum Fixture {
    static let helper = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_HELPER"] ?? ""

    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-motion-checks-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A job at 320×180, 12 fps, 1 s, laid out 1 CSS px = 1 output px unless told otherwise.
    static func job(_ html: String, name: String, width: Int = 320, height: Int = 180, fps: Int = 12, duration: Double = 1,
                    layoutHeight: Double? = nil, parameters: [String: Any] = [:], limits: WebMotionLimits? = nil,
                    alpha: WebMotionAlphaPath = .auto, workers: Int = 3, samples: Int = 4) -> WebMotionJob {
        let json = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data("{}".utf8)
        var job = WebMotionJob(page: html, parameters: json, duration: duration, width: width, height: height, fps: fps,
                               output: folder.appendingPathComponent("\(name).mov"))
        job.layoutHeight = layoutHeight ?? Double(height)
        job.limits = limits
        job.alpha = alpha
        job.workers = workers
        job.samples = samples
        return job
    }

    /// Tight limits for hostile pages, so a check that waits for a limit waits seconds, not minutes.
    static let tight = WebMotionLimits(load: 4, script: 2, snapshot: 6, total: 40)

    static func setEnvironment(_ name: String, _ value: String?) {
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }
}

/// What a render came back as, for checks that expect either.
enum RenderOutcome {
    case accepted(WebMotionRender)
    case failed(WebMotionRenderError)
    case other(Error)

    var render: WebMotionRender? {
        if case .accepted(let render) = self { return render }
        return nil
    }

    var rejected: WebMotionResult? {
        if case .failed(.rejected(let result)) = self { return result }
        return nil
    }

    var summary: String {
        switch self {
        case .accepted: "accepted"
        case .failed(let error): "\(error)"
        case .other(let error): "\(error)"
        }
    }
}

func render(_ job: WebMotionJob, watch: WebMotionHelperProcess.Watch = .init()) async -> RenderOutcome {
    do {
        return .accepted(try await WebMotionRenderer.render(job, watch: watch))
    } catch let error as WebMotionRenderError {
        return .failed(error)
    } catch {
        return .other(error)
    }
}

/// Runs on the main run loop every 20 ms; the longest gap between beats is how long SkyCut's main thread was stuck.
@MainActor
final class Heartbeat {
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var longestGap = 0.0
    private var timer: Timer?

    func start() {
        last = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                self.longestGap = max(self.longestGap, now - self.last)
                self.last = now
            }
        }
    }

    func stop() {
        timer?.invalidate()
    }
}

func elapsed(since start: Double) -> Double { ProcessInfo.processInfo.systemUptime - start }

func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
