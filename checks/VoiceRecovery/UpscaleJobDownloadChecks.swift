import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A paid upscale whose download did not finish (2026-11-24 / 25, the reviews of PR #554; docs/bugfixes/2026-11-24-download-lost-
// connection-no-retry.md): the real UpscaleJob and UpscaleActivity against a fake Sky Studio on the shared session (UpscaleHTTP,
// registered only while these run; the base points at the loopback address; the key is a fixture key in SkyCut's in-memory cache, so
// the keychain is never read; the source is a one-second clip ffmpeg makes):
// - the day's books take Sky Studio's actual charge as soon as it is made, from whichever field it sent: the top-level
//   `credits_charged` alone, or `billing.credits_charged` alone (72 of the 75 reserved either way; the billing one once stayed at 75);
// - a first answer without any charge, then Download again's re-read with 72: the books and the saved upscale both say 72;
// - a bill under review (`billing.credits_charged` 72 with `pending_review` / `review_required`): the 75 reserved stays (it once
//   settled at 72 and reported it as charged, CXD3); Download again's re-read with the final bill settles at 72;
// - Cancel while it downloads again keeps it listed, stopped, with Download again on its own row; that row's Download again reads the
//   job first and saves it; one upload and one /jobs for each job.
// upscale_clip asked again (project B, the same source) is PaidToolEntryChecks.

final class UpscaleHTTP: URLProtocol {
    /// Which of Sky Studio's charge fields a finished status carries (`reviewing`: the billing one, under review).
    enum Charge { case topLevel, billing, reviewing, none }
    static let lock = NSLock()
    static var requests: [(method: String, path: String)] = []
    static var drops = 0
    static var holdFiles = false
    static var result = Data()
    static var charge = Charge.topLevel
    /// What a later `GET /jobs/job-up` carries (nil: the same as the first answer).
    static var rereadCharge: Charge?
    static var reads = 0
    static let prefix = "/upscale-check"

    static func reset() { lock.withLock { requests = []; drops = 0; holdFiles = false; charge = .topLevel; rereadCharge = nil; reads = 0 } }
    static func count(_ method: String, _ suffix: String) -> Int {
        lock.withLock { requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.hasPrefix(prefix + "/") ?? false)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// Called with the lock held.
    private static func done(_ charge: Charge) -> String {
        let fields: String
        switch charge {
        case .topLevel: fields = #""credits_charged": 72,"#
        case .billing: fields = #""billing": {"status": "charged", "credits_charged": 72},"#
        case .reviewing: fields = #""billing": {"status": "pending_review", "review_required": true, "credits_charged": 72},"#
        case .none: fields = ""
        }
        return #"{"job_id": "job-up", "status": "done", "#
            + fields + #" "result": {"url": "http://127.0.0.1\#(prefix)/files/out.mp4", "generation_id": "gen-up", "content_type": "video/mp4", "width": 640, "height": 360, "duration": 1, "fps": 24}}"#
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        if let stream = request.httpBodyStream {   // the PUT's body: read it off, as a server would
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable, stream.read(&buffer, maxLength: buffer.count) > 0 {}
            stream.close()
        }
        Self.lock.lock()
        Self.requests.append((method, path))
        var answer: (Int, Data, String)?
        if path.hasSuffix("/files/out.mp4") {
            if Self.holdFiles { Self.lock.unlock(); return }   // no answer until the task is cancelled
            if Self.drops > 0 { Self.drops -= 1 } else { answer = (200, Self.result, "video/mp4") }
        } else if path.hasSuffix("/models") {
            answer = (200, Data(UpscaleHTTP.models.utf8), "application/json")
        } else if path.hasSuffix("/quote"), method == "POST" {
            answer = (200, Data(#"{"credits": 75, "typical_seconds": 60}"#.utf8), "application/json")
        } else if path.hasSuffix("/uploads"), method == "POST" {
            answer = (200, Data(#"{"upload_url": "http://127.0.0.1\#(Self.prefix)/bucket/in.mp4", "method": "PUT", "headers": {"Content-Type": "video/mp4"}, "file_url": "https://r2.example/in.mp4"}"#.utf8), "application/json")
        } else if path.hasSuffix("/bucket/in.mp4"), method == "PUT" {
            answer = (200, Data(), "text/plain")
        } else if path.hasSuffix("/jobs"), method == "POST" {
            answer = (200, Data(Self.done(Self.charge).utf8), "application/json")
        } else if path.hasSuffix("/jobs/job-up") {
            Self.reads += 1
            answer = (200, Data(Self.done(Self.rereadCharge ?? Self.charge).utf8), "application/json")
        } else {
            answer = (404, Data("{}".utf8), "application/json")
        }
        Self.lock.unlock()
        guard let (status, data, type) = answer else { return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count), "Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// One upscale model, as Sky Studio's /models lists it (checks/Upscale/main.swift's sample), for upscale_clip.
    static let models = #"""
    {"models": [{"id": "topaz-starlight", "kind": "upscale", "title": "Topaz Starlight",
      "price": {"per": "second", "credits_by_target": {"1080p": 30, "4K": 65}}, "params": {"target": ["1080p", "4K"]},
      "limits": {"max_source_seconds": 30.5, "max_source_fps": 30, "max_output_pixels": 8294400, "max_upload_bytes": 209715200}}]}
    """#
}

/// The fixture's source clip (one second, 640×360, made by ffmpeg) and its probe; nil when ffmpeg is missing (recorded).
@MainActor
func upscaleSource(_ folder: URL) async throws -> (URL, MediaInfo)? {
    guard let path = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"], FileManager.default.isExecutableFile(atPath: path) else {
        require(false, "the upscale checks need ffmpeg (SRTFLOW_FFMPEG)")
        return nil
    }
    let ffmpeg = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("clip.mp4")
    try await FFmpegProcess().run(executable: ffmpeg, arguments: [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=24", "-t", "1",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path,
    ], workingDirectory: nil)
    guard case .success(let info) = await MediaProbe.probe(url: source, ffmpeg: ffmpeg) else {
        require(false, "the upscale fixture's source can be probed")
        return nil
    }
    return (source, info)
}

/// The fake Sky Studio for upscales, its address and a fixture key, for the duration of `body`.
@MainActor
func withUpscaleHTTP(serving source: URL, _ body: () async throws -> Void) async throws {
    UpscaleHTTP.reset()
    UpscaleHTTP.result = try Data(contentsOf: source)
    URLProtocol.registerClass(UpscaleHTTP.self)
    setenv(SkyStudioAPI.baseEnvironmentKey, "http://127.0.0.1\(UpscaleHTTP.prefix)/api/skycut/v1", 1)
    await SkyStudioKey.cache.remember("sk-" + String(repeating: "U", count: 43))
    SkyStudioCatalogCache.shared.forget()
    defer {
        unsetenv(SkyStudioAPI.baseEnvironmentKey)
        URLProtocol.unregisterClass(UpscaleHTTP.self)
        SkyStudioCatalogCache.shared.forget()
    }
    try await body()
    await SkyStudioKey.cache.remember(nil)
}

@MainActor
func runUpscaleJobDownloadChecks(_ root: URL) async throws {
    guard let (source, info) = try await upscaleSource(root.appendingPathComponent("upscale-download", isDirectory: true)) else { return }
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    try await withUpscaleHTTP(serving: source) {
        let tier = UpscaleTier(id: "topaz-starlight", title: "Topaz Starlight", targets: [.p1080, .p2160], maxSourceSeconds: 30.5,
                               maxSourceFPS: 30, maxUploadBytes: 209_715_200)
        let range = UpscaleRange.make(.wholeFile, thisClip: UUID(), uses: [], fileDuration: info.duration, frameRate: 24, maxSeconds: 30.5)
        let request = UpscaleRequest(originalURL: source, originalInfo: info, range: range, tier: tier, target: .p1080, credits: 75,
                                     typicalSeconds: nil, fallbackFolders: [])
        await ledgerChecks(request)
        await cancelAndDownloadAgain(request)
    }
}

/// A job started as the panel starts it, held after three lost connections. Returns it and the day's spend before it.
@MainActor
private func heldJob(_ request: UpscaleRequest, charge: UpscaleHTTP.Charge, _ what: String) async -> (UpscaleJob, Double) {
    let spent = SkyStudioSpendStore.shared.spentToday()
    UpscaleHTTP.lock.withLock { UpscaleHTTP.drops = 3; UpscaleHTTP.charge = charge; UpscaleHTTP.rereadCharge = nil }
    let job = UpscaleJob(request: request, clipIDs: [], owner: CloudTasksActivity.owner(of: OpenProjects.shared.primary), title: "clip")
    UpscaleActivity.shared.add(job, opensCompare: false)
    await upscaleEventually("\(what): the first download to give up") { job.canRetryDownload }
    require(job.state == .failed(job.downloadFailure.map(SkyStudioDownloadWords.shown) ?? "") && job.downloadFailure?.kind == .interrupted,
            "\(what): three lost connections: failed with the line and Download again: \(job.state)")
    return (job, spent)
}

@MainActor
private func books(_ spent: Double, _ expected: Double, _ what: String) {
    let now = SkyStudioSpendStore.shared.spentToday() - spent
    require(abs(now - expected) < 0.001, "\(what): the day's books hold \(expected) of the 75 reserved (\(now))")
}

@MainActor
private func ledgerChecks(_ request: UpscaleRequest) async {
    // Each charge field alone: the actual charge reaches the books as soon as it is made, before the download.
    for (charge, what) in [(UpscaleHTTP.Charge.topLevel, "top-level credits_charged alone"), (.billing, "billing.credits_charged alone")] {
        let (job, spent) = await heldJob(request, charge: charge, what)
        books(spent, 72, what)
        UpscaleActivity.shared.remove(job)
    }

    // No charge in the first answer; Download again's re-read carries it: the books and the saved upscale both say 72.
    let (job, spent) = await heldJob(request, charge: .none, "no charge at first")
    books(spent, 75, "no charge known yet")
    UpscaleHTTP.lock.withLock { UpscaleHTTP.rereadCharge = .billing }
    UpscaleActivity.shared.downloadAgain(job)
    await upscaleEventually("the re-read upscale to be saved") { job.state == .done }
    require(job.outcome?.creditsCharged == 72 && job.outcome?.record.credits == 72,
            "the saved upscale reports the charge the re-read carried (72), not the 75 reserved: \(String(describing: job.outcome?.creditsCharged))")
    books(spent, 72, "after the re-read")
    if let file = job.outcome?.file { try? FileManager.default.removeItem(at: file) }
    UpscaleActivity.shared.remove(job)

    // A bill under review: the 75 reserved stays until the bill is final; the final bill on Download again's re-read settles at 72.
    let (reviewed, reviewSpent) = await heldJob(request, charge: .reviewing, "a bill under review")
    books(reviewSpent, 75, "a bill under review")
    UpscaleHTTP.lock.withLock { UpscaleHTTP.rereadCharge = .billing }
    UpscaleActivity.shared.downloadAgain(reviewed)
    await upscaleEventually("the reviewed upscale to be saved") { reviewed.state == .done }
    require(reviewed.outcome?.creditsCharged == 72, "the final bill's charge (72) once it is final: \(String(describing: reviewed.outcome?.creditsCharged))")
    books(reviewSpent, 72, "once the bill is final")
    if let file = reviewed.outcome?.file { try? FileManager.default.removeItem(at: file) }
    UpscaleActivity.shared.remove(reviewed)
}

@MainActor
private func cancelAndDownloadAgain(_ request: UpscaleRequest) async {
    let activity = UpscaleActivity.shared
    let uploads = UpscaleHTTP.count("POST", "/uploads"), jobs = UpscaleHTTP.count("POST", "/jobs")
    let (job, _) = await heldJob(request, charge: .topLevel, "Cancel")
    func ended() -> Bool { if case .running = job.state { return false }; return true }

    // Cancel while it downloads again (the row's or the inspector's Cancel): stopped, still listed, still held on its own row.
    UpscaleHTTP.lock.withLock { UpscaleHTTP.holdFiles = true }
    let gets = UpscaleHTTP.count("GET", "/files/out.mp4")
    activity.downloadAgain(job)
    require(!job.canRetryDownload && !ended(), "Download again runs")
    await upscaleEventually("the GET of Download again") { UpscaleHTTP.count("GET", "/files/out.mp4") > gets }
    activity.remove(job)
    await upscaleEventually("the stop", ended)
    require(job.state == .cancelled(.alreadyStarted) && job.downloadFailure?.kind == .stopped && job.downloadFailure?.attempts == 1
            && job.canRetryDownload && activity.jobs.contains { $0 === job },
            "Cancel while it downloads again keeps it listed, stopped after the GET it sent, with Download again: \(job.state)")
    UpscaleHTTP.lock.withLock { UpscaleHTTP.holdFiles = false }

    // Its own row's Download again: the job read first, saved; nothing submitted again.
    let reads = UpscaleHTTP.lock.withLock { UpscaleHTTP.reads }
    activity.downloadAgain(job)
    await upscaleEventually("the upscale to be saved", ended)
    require(job.state == .done && job.outcome.map { FileManager.default.fileExists(atPath: $0.file.path) } == true,
            "Download again saves the upscale: \(job.state)")
    require(UpscaleHTTP.lock.withLock { UpscaleHTTP.reads } > reads, "the upscale's Download again read the job's current result first")
    require(UpscaleHTTP.count("POST", "/uploads") == uploads + 1 && UpscaleHTTP.count("POST", "/jobs") == jobs + 1,
            "one upload and one /jobs for this job")
    if let file = job.outcome?.file { try? FileManager.default.removeItem(at: file) }
    activity.remove(job)
}

@MainActor
func upscaleEventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}
