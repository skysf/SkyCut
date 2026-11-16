import Foundation
import SrtFlowWebMotionKit

// MARK: - Rendering a motion web page into a transparent movie (the API the next task builds on)
//
// `WebMotionRenderer.render(job)` → a ProRes 4444 movie with premultiplied alpha at `job.output`, the page checks
// (MCP-75: loads, frame entry, same t twice, no empty frame, no page error, no timeout) and the renderer / system
// versions to store with the clip. A page that fails a check comes back as `.rejected` with the page's own error text
// (the AI fixes the page with it). The page runs in the helper process `skycut-web-motion`, never in SkyCut; SkyCut
// watches its memory and time and kills it when needed. One render at a time (three helpers at once measured slower
// than one helper drawing three pages).
// Callers driving this from AI work run it inside `AIJobs` (App Nap, ai-control-mcp.md rule 59). Not here yet: no AI
// tool, no UI, no project-file change (MCP-74). docs/architecture/web-motion-renderer.md.

struct WebMotionJob: Sendable {
    var page: String
    /// A JSON object (becomes `window.MOTION_PARAMS`).
    var parameters: Data
    var duration: Double
    var width: Int
    var height: Int
    var fps: Int
    /// Where the movie goes (replaced if it exists). Written next to it first, moved in only when the page passed.
    var output: URL
    var layoutHeight = WebMotionCaps.referenceLayoutHeight
    var seed = WebMotionCaps.defaultSeed
    var clockEpochMilliseconds = WebMotionCaps.defaultClockEpochMilliseconds
    var workers = WebMotionCaps.defaultWorkers
    var samples = WebMotionCaps.defaultSamples
    var alpha: WebMotionAlphaPath = .auto
    /// nil = `WebMotionLimits.standard(frames:)`.
    var limits: WebMotionLimits?

    func request(writingTo path: URL) -> WebMotionRequest {
        WebMotionRequest(html: page, parametersJSON: String(decoding: parameters, as: UTF8.self), duration: duration,
                         width: width, height: height, fps: fps, outputPath: path.path, layoutHeight: layoutHeight,
                         seed: seed, clockEpochMilliseconds: clockEpochMilliseconds, workers: workers, samples: samples,
                         alpha: alpha, limits: limits)
    }
}

struct WebMotionRender: Sendable {
    let file: URL
    /// Checks, frame hashes, alpha path, versions, timing.
    let result: WebMotionResult
    /// The most memory the render used at once (helper + its WebKit processes).
    let peakFootprint: UInt64
}

enum WebMotionRenderError: Error, CustomStringConvertible {
    case invalid([String])
    case helperMissing
    /// The page failed a check or a time limit: `result.failure.message` is the page's own error text.
    case rejected(WebMotionResult)
    /// SkyCut stopped the render (memory, or a helper that stopped keeping its own limits).
    case killed(WebMotionKill)
    /// The renderer could not do its job (a lock unavailable on this macOS, the encoder failed, it crashed).
    case rendererFailed(String)
    case cancelled

    var description: String {
        switch self {
        case .invalid(let problems): problems.joined(separator: " ")
        case .helperMissing: "The motion renderer (skycut-web-motion) is missing from SkyCut."
        case .rejected(let result): result.failure?.message ?? "The page did not pass SkyCut's checks."
        case .killed(let kill): kill.message
        case .rendererFailed(let message): message
        case .cancelled: "The render was cancelled."
        }
    }
}

enum WebMotionRenderer {
    static func render(_ job: WebMotionJob, watch: WebMotionHelperProcess.Watch = .init()) async throws -> WebMotionRender {
        guard let helper = helperURL() else { throw WebMotionRenderError.helperMissing }
        let work = job.output.deletingLastPathComponent()
            .appendingPathComponent(".skycut-web-motion-\(UUID().uuidString).mov")
        let request = job.request(writingTo: work)
        let problems = request.problems()
        guard problems.isEmpty else { throw WebMotionRenderError.invalid(problems) }
        await WebMotionRenderGate.shared.enter()
        defer { Task { await WebMotionRenderGate.shared.leave() } }
        if Task.isCancelled { throw WebMotionRenderError.cancelled }
        defer { try? FileManager.default.removeItem(at: work) }
        Quarantine.repairOwnBundleIfNeeded()
        let report = await WebMotionHelperProcess().run(request, helper: helper, watch: watch)
        let result = try accepted(report.outcome)
        do {
            if FileManager.default.fileExists(atPath: job.output.path) { try FileManager.default.removeItem(at: job.output) }
            try FileManager.default.moveItem(at: work, to: job.output)
        } catch {
            throw WebMotionRenderError.rendererFailed("The movie could not be moved into place: \(error.localizedDescription)")
        }
        return WebMotionRender(file: job.output, result: result, peakFootprint: report.peakFootprint)
    }

    /// The result of a run that passed, or the error that says why not.
    static func accepted(_ outcome: WebMotionHelperProcess.Outcome) throws -> WebMotionResult {
        switch outcome {
        case .cancelled:
            throw WebMotionRenderError.cancelled
        case .killed(let kill, _):
            throw WebMotionRenderError.killed(kill)
        case .finished(let result?, let status, _, _) where status == WebMotionExitCode.accepted && result.accepted:
            return result
        case .finished(let result?, let status, _, _)
            where status == WebMotionExitCode.rejected || status == WebMotionExitCode.timeLimit:
            throw WebMotionRenderError.rejected(result)
        case .finished(let result, let status, let signaled, let log):
            if let message = result?.failure?.message { throw WebMotionRenderError.rendererFailed(message) }
            var message = signaled ? "The motion renderer was stopped by the system (signal \(status))."
                : "The motion renderer ended without a result (exit \(status))."
            if signaled, let fix = Quarantine.fixCommandIfFlagged { message += " SkyCut is quarantined; run: \(fix)" }
            let tail = log.split(separator: "\n").suffix(5).joined(separator: "\n")
            throw WebMotionRenderError.rendererFailed(tail.isEmpty ? message : message + "\n" + tail)
        }
    }

    /// `SRTFLOW_WEB_MOTION_HELPER` (checks), the app bundle's Contents/Helpers, or next to SkyCut's own executable
    /// (`swift run`, where SwiftPM builds every product into one folder).
    static func helperURL() -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_HELPER"], !override.isEmpty {
            return manager.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/skycut-web-motion"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("skycut-web-motion"),
        ].compactMap { $0 }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}

/// One render at a time, in the order asked.
actor WebMotionRenderGate {
    static let shared = WebMotionRenderGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
