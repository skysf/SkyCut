import Foundation
import SrtFlowWebMotionKit

// MARK: - Drawing every frame, then the checks that need the frames (MCP-75)
//
// Owns: the main pass (frame i drawn by page instance i mod k, k frames in flight, written in order), the per-frame
// limits and page errors, "no empty frame", "same t twice" (sample frames drawn again in reverse order on the next page
// instance, compared by SHA-256 of their pixels), finishing and reading back the movie.
// Does not own: loading and calibration (`HelperRun`), what a page is allowed to do (`Lockdown`, `PageClock`).

@MainActor
final class FramePasses {
    private let request: WebMotionRequest
    private let workers: [PageWorker]
    private let path: WebMotionAlphaPath
    private let report = HelperReport.shared
    private let scratch: FrameMemory
    private var hashes: [String] = []
    private var blank: [Bool] = []
    /// Some frame has a pixel below alpha 255 (the movie must carry alpha).
    private var translucent = false
    private var slowest = 0.0

    init(request: WebMotionRequest, workers: [PageWorker], path: WebMotionAlphaPath) {
        self.request = request
        self.workers = workers
        self.path = path
        scratch = FrameMemory(width: request.width, height: request.height)
    }

    func run() async throws {
        let frames = request.frameCount
        report.frameCount = frames
        let url = URL(fileURLWithPath: request.outputPath)
        let encoder = try FrameEncoder(url: url, width: request.width, height: request.height, fps: request.fps)
        try await mainPass(encoder)
        report.pass(.noPageErrors, "No page errors.")
        let finishing = report.elapsed
        try await encoder.finish(frames: frames)
        report.timing.finishSeconds = report.elapsed - finishing
        try checkBlankFrames()
        try await drawSamplesAgain()
        try await FrameEncoder.verify(url, frames: frames, fps: request.fps, translucent: translucent)
        report.transparent = translucent
        report.pass(.noTimeout, "Slowest frame " + String(format: "%.2f", slowest) + " s (limits: script "
            + "\(Deadline.format(request.limits.script)) s, snapshot \(Deadline.format(request.limits.snapshot)) s, total "
            + "\(Deadline.format(request.limits.total)) s).")
    }

    private func mainPass(_ encoder: FrameEncoder) async throws {
        let frames = request.frameCount
        let start = report.elapsed
        var first = 0
        while first < frames {
            let batch = min(workers.count, frames - first)
            var captured = [Result<CapturedFrame, Error>?](repeating: nil, count: batch)
            await withTaskGroup(of: (Int, Result<CapturedFrame, Error>, Double).self) { group in
                for offset in 0..<batch {
                    let worker = workers[(first + offset) % workers.count]
                    let t = request.time(ofFrame: first + offset)
                    group.addTask { @MainActor in
                        let began = ProcessInfo.processInfo.systemUptime
                        do {
                            let frame = try await self.draw(worker, t: t)
                            return (offset, .success(frame), ProcessInfo.processInfo.systemUptime - began)
                        } catch {
                            return (offset, .failure(error), ProcessInfo.processInfo.systemUptime - began)
                        }
                    }
                }
                for await (offset, frame, seconds) in group {
                    captured[offset] = frame
                    slowest = max(slowest, seconds)
                }
            }
            // Frames of a batch are drawn at once; when several fail, the earliest is the one to report.
            for offset in 0..<batch {
                guard let frame = try captured[offset]?.get() else { throw HelperFailure(description: "A frame went missing.") }
                let buffer = try encoder.makeBuffer()
                let (hash, isBlank, isOpaque) = try FrameCapture.write(frame, into: buffer, scratch: scratch)
                hashes.append(hash)
                blank.append(isBlank)
                translucent = translucent || !isOpaque
                try await encoder.append(buffer, frame: first + offset)
            }
            first += batch
            report.progress("frames", done: first, total: frames)
        }
        report.frameHashes = hashes
        report.timing.renderSeconds = report.elapsed - start
        report.timing.framesPerSecond = Double(frames) / max(report.timing.renderSeconds, 0.001)
        report.timing.slowestFrameSeconds = slowest
    }

    /// One frame on one page instance, under the script and snapshot limits. The page's errors from this frame fail
    /// the render with the first one verbatim.
    private func draw(_ worker: PageWorker, t: Double) async throws -> CapturedFrame {
        let limits = request.limits
        let stamp = String(format: "%.3f", t)
        let backdrop: String? = path == .public ? "#000" : nil
        let errors = try await guarded(t) {
            try await Deadline.within(limits.script, "Drawing the frame at t = \(stamp) s took longer than "
                + "\(Deadline.format(limits.script)) s (an endless loop in motion.frame(t)?).", time: t) {
                try await worker.draw(t: t, backdrop: backdrop)
            }
        }
        if let first = errors.first {
            report.addPageErrors(errors)
            throw PageFailure(check: .noPageErrors, message: first, time: t)
        }
        let late = "Capturing the frame at t = \(stamp) s took longer than \(Deadline.format(limits.snapshot)) s."
        let image = try await guarded(t) { try await Deadline.within(limits.snapshot, late, time: t) { try await worker.snapshot() } }
        guard path == .public else { return .single(image) }
        try await guarded(t) {
            try await Deadline.within(limits.script, "Changing the backdrop at t = \(stamp) s took longer than "
                + "\(Deadline.format(limits.script)) s.", time: t) { try await worker.setBackdrop("#fff") }
        }
        let white = try await guarded(t) { try await Deadline.within(limits.snapshot, late, time: t) { try await worker.snapshot() } }
        return .pair(black: image, white: white)
    }

    /// A page process that died is the page's failure (too much memory, a crash); anything else stays internal.
    private func guarded<T>(_ t: Double, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let ended as LockedNavigation.ProcessEnded {
            throw PageFailure(check: .noPageErrors, message: ended.description, time: t)
        }
    }

    private func checkBlankFrames() throws {
        let verdict = WebMotionBlankFrames.verdict(blank: blank)
        report.blankFrames = verdict.blank
        guard verdict.passed else {
            throw PageFailure(check: .noBlankFrames, message: verdict.detail, time: verdict.failingFrame.map(request.time(ofFrame:)))
        }
        report.pass(.noBlankFrames, verdict.detail)
    }

    /// Sample frames drawn again, last first, each on the next page instance: a page that keeps state between frames,
    /// differs between instances or depends on what was drawn before comes out different.
    private func drawSamplesAgain() async throws {
        let picks = FramePasses.samples(frames: request.frameCount, count: request.samples)
        let start = report.elapsed
        let memory = FrameMemory(width: request.width, height: request.height)
        for (done, index) in picks.reversed().enumerated() {
            let firstWorker = index % workers.count
            let secondWorker = (index + 1) % workers.count
            let t = request.time(ofFrame: index)
            let frame = try await draw(workers[secondWorker], t: t)
            let bytes = try FrameCapture.write(frame, into: memory.base, bytesPerRow: memory.bytesPerRow, scratch: scratch)
            guard WebMotionPixels.digest(bytes) == hashes[index] else {
                let instances = workers.count == 1 ? "on the same page instance" :
                    "first on page instance \(firstWorker + 1), then on \(secondWorker + 1)"
                throw PageFailure(check: .sameTwice, message: "The frame at t = " + String(format: "%.3f", t)
                    + " s came out different when drawn a second time (\(instances), after other frames). A motion page must "
                    + "draw only from t: no state carried between frames, randomness only from Math.random (SkyCut seeds it), "
                    + "and images and fonts ready before drawing (wait for them in motion.ready).", time: t)
            }
            report.progress("verify", done: done + 1, total: picks.count)
        }
        report.timing.verifySeconds = report.elapsed - start
        report.pass(.sameTwice, "\(picks.count) frame\(picks.count == 1 ? "" : "s") drawn a second time (last first, on "
            + "\(workers.count == 1 ? "the same page instance" : "another page instance")) came out identical.")
    }

    /// `count` frames spread evenly from the first to the last.
    static func samples(frames: Int, count: Int) -> [Int] {
        guard frames > 0, count > 0 else { return [] }
        let picks = min(count, frames)
        guard picks > 1 else { return [0] }
        let spread = (0..<picks).map { Int((Double($0) * Double(frames - 1) / Double(picks - 1)).rounded()) }
        return Array(Set(spread)).sorted()
    }
}
