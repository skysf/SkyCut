import Darwin
import Foundation
import SrtFlowWebMotionKit
import WebKit

// MARK: - One render, start to finish
//
// Owns the order: versions → time limits → network lock → calibration (device scale, then which alpha path) → page
// instances loaded and validated → `FramePasses` (frames, checks, movie) → the exit. Every way out goes through
// `HelperReport.finish`. Does not own: drawing a frame (`FramePasses`, `PageWorker`), the locks (`Lockdown`).
// docs/architecture/web-motion-renderer.md.

/// The renderer could not do its job (not the page's fault).
struct HelperFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class HelperRun {
    let request: WebMotionRequest
    private let report = HelperReport.shared
    private var ruleList: WKContentRuleList?
    private var deviceScale = 1.0
    private var path: WebMotionAlphaPath = .fast
    private var workers: [PageWorker] = []
    /// Every page instance made, kept until the process exits: a page rejected while loading stays alive (and keeps its
    /// WebKit process) until the result is out, instead of being torn down mid-attempt by going out of scope.
    private var created: [PageWorker] = []

    init(request: WebMotionRequest) {
        self.request = request
    }

    func run() async -> Never {
        report.versions = HelperRun.versions()
        Deadline.startTotal(request.limits.total)
        Deadline.watchParent()
        do {
            try await prepareLock()
            try await calibrate()
            report.timing.setupSeconds = report.elapsed
            try await loadPages()
            try await FramePasses(request: request, workers: workers, path: path).run()
            report.finish(WebMotionExitCode.accepted)
        } catch let failure as PageFailure {
            report.fail(failure)
            report.finish(WebMotionExitCode.rejected)
        } catch {
            report.internalFailure("\(error)")
        }
    }

    private func prepareLock() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("skycut-web-motion-\(getpid())-rules", isDirectory: true)
        report.onExit { try? FileManager.default.removeItem(at: store) }
        let limit = request.limits.load
        ruleList = try await Deadline.within(limit, "Preparing the network lock took longer than \(Deadline.format(limit)) s.") {
            try await Lockdown.compileRuleList(storeDirectory: store)
        }
        // The compiled list lives in memory now; the store was only needed to compile it.
        try? FileManager.default.removeItem(at: store)
    }

    private func configuration() throws -> WKWebViewConfiguration {
        guard let ruleList else { throw HelperFailure(description: "The network lock was not prepared.") }
        return try Lockdown.configuration(ruleList: ruleList, scripts: [
            PageClock.bootstrap(seed: request.seed, epochMilliseconds: request.clockEpochMilliseconds),
            PageClock.parameters(for: request),
        ])
    }

    /// Measures WebKit's backing scale on a calibration page at zoom 1, redraws it at 1× and checks the alpha: the fast
    /// path when it reads right (or was asked for), the public black-and-white path otherwise (`.auto`, user 2026-11-16).
    private func calibrate() async throws {
        let size = CGSize(width: WebMotionAlphaCalibration.cssWidth, height: WebMotionAlphaCalibration.cssHeight)
        let pixels = (Int(size.width), Int(size.height))
        let wantFast = request.alpha != .public
        let page = PageWorker(configuration: try configuration(), points: size, zoom: 1, pixels: pixels, transparent: wantFast)
        created.append(page)
        let limit = request.limits.load
        let loaded = try await Deadline.within(limit, "The calibration page did not load within \(Deadline.format(limit)) s.") {
            try await page.load(WebMotionPageHTML.locked(WebMotionAlphaCalibration.html))
            return try await page.finishLoading()
        }
        report.addProcesses(page.processIdentifiers)
        guard loaded.ratio >= 1 else { throw HelperFailure(description: "WebKit reported a backing scale of \(loaded.ratio).") }
        deviceScale = loaded.ratio
        page.resize(points: CGSize(width: size.width / deviceScale, height: size.height / deviceScale), zoom: 1 / deviceScale)
        let frame = FrameMemory(width: pixels.0, height: pixels.1)
        let scratch = FrameMemory(width: pixels.0, height: pixels.1)
        var fastProblem: String?
        if wantFast {
            let bytes = try FrameCapture.write(try await capture(page, backdrop: false), into: frame.base,
                                               bytesPerRow: frame.bytesPerRow, scratch: scratch)
            fastProblem = WebMotionAlphaCalibration.problem(bytes)
            if fastProblem == nil {
                path = .fast
                report.alpha = WebMotionAlphaReport(path: .fast, fastPathProblem: nil,
                                                    calibration: WebMotionAlphaCalibration.summary(bytes), deviceScale: deviceScale)
                return
            }
            if request.alpha == .fast {
                throw HelperFailure(description: "The fast transparent background is wrong on this Mac: \(fastProblem ?? "")")
            }
        }
        let bytes = try FrameCapture.write(try await capture(page, backdrop: true), into: frame.base,
                                           bytesPerRow: frame.bytesPerRow, scratch: scratch)
        if let publicProblem = WebMotionAlphaCalibration.problem(bytes) {
            throw HelperFailure(description: "No way of making the background transparent works on this Mac. Fast: "
                + "\(fastProblem ?? "not tried"). Public: \(publicProblem)")
        }
        path = .public
        report.alpha = WebMotionAlphaReport(path: .public, fastPathProblem: fastProblem ?? "The public path was requested.",
                                            calibration: WebMotionAlphaCalibration.summary(bytes), deviceScale: deviceScale)
    }

    private func capture(_ page: PageWorker, backdrop: Bool) async throws -> CapturedFrame {
        let limit = request.limits.snapshot
        return try await Deadline.within(limit, "Capturing the calibration page took longer than \(Deadline.format(limit)) s.") {
            _ = try await page.draw(t: 0, backdrop: backdrop ? "#000" : nil)
            let first = try await page.snapshot()
            guard backdrop else { return .single(first) }
            try await page.setBackdrop("#fff")
            return .pair(black: first, white: try await page.snapshot())
        }
    }

    /// Loads the page in each instance (the workers draw frames in turn) and checks what the page reports.
    private func loadPages() async throws {
        let count = min(request.workers, request.frameCount)
        let points = CGSize(width: Double(request.width) / deviceScale, height: Double(request.height) / deviceScale)
        let zoom = request.pixelRatio / deviceScale
        let html = WebMotionPageHTML.locked(request.html)
        let start = report.elapsed
        let limit = request.limits.load
        var declared: Double?
        for index in 0..<count {
            let worker = PageWorker(configuration: try configuration(), points: points, zoom: zoom,
                                    pixels: (request.width, request.height), transparent: path == .fast)
            created.append(worker)
            let loaded: PageWorker.Loaded
            do {
                loaded = try await Deadline.within(limit, "The page did not finish loading within \(Deadline.format(limit)) s "
                    + "(an endless loop or a very slow script while loading?).", check: .loads) {
                    try await worker.load(html)
                    return try await worker.finishLoading()
                }
            } catch let ended as LockedNavigation.ProcessEnded {
                throw PageFailure(check: .loads, message: ended.description, time: nil)
            }
            report.addProcesses(worker.processIdentifiers)
            try validate(loaded)
            declared = loaded.declaredDuration
            workers.append(worker)
            report.progress("load", done: index + 1, total: count)
        }
        report.timing.loadSeconds = report.elapsed - start
        report.pass(.loads, "Loaded on \(count) page instance\(count == 1 ? "" : "s") in "
            + String(format: "%.2f", report.timing.loadSeconds) + " s.")
        var entry = "window.motion.frame(t) is defined."
        if let declared, abs(declared - request.duration) > 0.5 / Double(request.fps) {
            entry += " The page says its duration is \(declared) s; \(request.duration) s were rendered."
        }
        report.pass(.frameEntry, entry)
    }

    private func validate(_ loaded: PageWorker.Loaded) throws {
        if !loaded.errors.isEmpty {
            report.addPageErrors(loaded.errors)
            report.pass(.loads, "Loaded, with errors.")
            throw PageFailure(check: .noPageErrors, message: loaded.errors[0], time: nil)
        }
        guard loaded.hasFrame else {
            throw PageFailure(check: .frameEntry, message: "The page does not define window.motion.frame(t). SkyCut draws "
                + "every frame by calling it with the time in seconds.", time: nil)
        }
        let fits = abs(loaded.width - request.layoutWidth) <= 1 && abs(loaded.height - request.layoutHeight) <= 1
            && abs(loaded.ratio - request.pixelRatio) <= 0.01
        guard fits else {
            throw HelperFailure(description: "The renderer could not fix the page's size: the page sees "
                + "\(loaded.width)×\(loaded.height) CSS px at \(loaded.ratio)x, expected "
                + "\(request.layoutWidth)×\(request.layoutHeight) at \(request.pixelRatio)x.")
        }
    }

    static func versions() -> WebMotionVersions {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &build, &size, nil, 0)
        let webKit = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return WebMotionVersions(renderer: WebMotionVersion.renderer,
                                 macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                 macOSBuild: String(cString: build), webKit: webKit)
    }
}
