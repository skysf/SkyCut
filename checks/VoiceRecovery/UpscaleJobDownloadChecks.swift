import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A paid upscale whose download did not finish (2026-11-24, the review of PR #554; docs/bugfixes/2026-11-24-download-lost-connection-no-
// retry.md): the real UpscaleJob and UpscaleActivity against a fake Sky Studio on the shared session (UpscaleHTTP, registered only while
// these run; the base points at the loopback address; the key is a fixture key in SkyCut's in-memory cache, so the keychain is never
// read; the source is a one-second clip ffmpeg makes):
// - three lost connections: failed with the line and Download again; the day's books hold Sky Studio's charge (72 of the 75
//   reserved), settled when it was made;
// - Cancel while it downloads again (the inspector's) keeps it listed, stopped, with Download again;
// - dismissed, the same upscale is still found for the panel and upscale_clip (UpscaleActivity.heldDownload), and their Download again
//   lists it again, reads the job first and saves it; one upload and one /jobs in all.

final class UpscaleHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(method: String, path: String)] = []
    static var drops = 0
    static var holdFiles = false
    static var result = Data()
    static let prefix = "/upscale-check"

    static func reset() { lock.withLock { requests = []; drops = 0; holdFiles = false } }
    static func count(_ method: String, _ suffix: String) -> Int {
        lock.withLock { requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.hasPrefix(prefix + "/") ?? false)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

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
        let done = #"{"job_id": "job-up", "status": "done", "credits_charged": 72, "billing": {"status": "charged", "credits_charged": 72}, "result": {"url": "http://127.0.0.1\#(Self.prefix)/files/out.mp4", "generation_id": "gen-up", "content_type": "video/mp4", "width": 640, "height": 360, "duration": 1, "fps": 24}}"#
        if path.hasSuffix("/files/out.mp4") {
            if Self.holdFiles { Self.lock.unlock(); return }   // no answer until the task is cancelled
            if Self.drops > 0 { Self.drops -= 1 } else { answer = (200, Self.result, "video/mp4") }
        } else if path.hasSuffix("/uploads"), method == "POST" {
            answer = (200, Data(#"{"upload_url": "http://127.0.0.1\#(Self.prefix)/bucket/in.mp4", "method": "PUT", "headers": {"Content-Type": "video/mp4"}, "file_url": "https://r2.example/in.mp4"}"#.utf8), "application/json")
        } else if path.hasSuffix("/bucket/in.mp4"), method == "PUT" {
            answer = (200, Data(), "text/plain")
        } else if (path.hasSuffix("/jobs") && method == "POST") || path.hasSuffix("/jobs/job-up") {
            answer = (200, Data(done.utf8), "application/json")
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
}

@MainActor
func runUpscaleJobDownloadChecks(_ root: URL) async throws {
    guard let path = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"], FileManager.default.isExecutableFile(atPath: path) else {
        return require(false, "the upscale download checks need ffmpeg (SRTFLOW_FFMPEG)")
    }
    let ffmpeg = URL(fileURLWithPath: path)
    let folder = root.appendingPathComponent("upscale-download", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("clip.mp4")
    try await FFmpegProcess().run(executable: ffmpeg, arguments: [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=24", "-t", "1",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path,
    ], workingDirectory: nil)
    guard case .success(let info) = await MediaProbe.probe(url: source, ffmpeg: ffmpeg) else {
        return require(false, "the upscale fixture's source can be probed")
    }
    UpscaleHTTP.reset()
    UpscaleHTTP.result = try Data(contentsOf: source)
    URLProtocol.registerClass(UpscaleHTTP.self)
    setenv(SkyStudioAPI.baseEnvironmentKey, "http://127.0.0.1\(UpscaleHTTP.prefix)/api/skycut/v1", 1)
    await SkyStudioKey.cache.remember("sk-" + String(repeating: "U", count: 43))
    await heldStoppedDismissedAndAgain(source, info)
    await SkyStudioKey.cache.remember(nil)
    unsetenv(SkyStudioAPI.baseEnvironmentKey)
    URLProtocol.unregisterClass(UpscaleHTTP.self)
}

@MainActor
private func heldStoppedDismissedAndAgain(_ source: URL, _ info: MediaInfo) async {
    let tier = UpscaleTier(id: "topaz-starlight", title: "Topaz Starlight", targets: [.p1080, .p2160], maxSourceSeconds: 30.5,
                           maxSourceFPS: 30, maxUploadBytes: 209_715_200)
    let range = UpscaleRange.make(.wholeFile, thisClip: UUID(), uses: [], fileDuration: info.duration, frameRate: 24, maxSeconds: 30.5)
    let request = UpscaleRequest(originalURL: source, originalInfo: info, range: range, tier: tier, target: .p1080, credits: 75,
                                 typicalSeconds: nil, fallbackFolders: [])
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    let spent = SkyStudioSpendStore.shared.spentToday()
    let activity = UpscaleActivity.shared
    let job = UpscaleJob(request: request, clipIDs: [], owner: CloudTasksActivity.owner(of: OpenProjects.shared.primary), title: "clip")
    func ended() -> Bool { if case .running = job.state { return false }; return true }
    func books(_ what: String) {
        require(abs(SkyStudioSpendStore.shared.spentToday() - (spent + 72)) < 0.001,
                "\(what): the day's books hold Sky Studio's charge, 72 of the 75 reserved (\(SkyStudioSpendStore.shared.spentToday() - spent))")
    }

    // Three lost connections: held, with the line; the charge settled when it was made.
    UpscaleHTTP.drops = 3
    activity.add(job, opensCompare: false)
    await upscaleEventually("the first download to give up", ended)
    require(job.state == .failed(job.downloadFailure.map(SkyStudioDownloadWords.shown) ?? "") && job.downloadFailure?.kind == .interrupted
            && job.canRetryDownload && UpscaleHTTP.count("GET", "/files/out.mp4") == 3,
            "three lost connections: failed with the line and Download again after three GETs: \(job.state)")
    books("after the failed download")

    // Cancel while it downloads again (the inspector's Cancel): stopped, still listed, still held.
    UpscaleHTTP.holdFiles = true
    let gets = UpscaleHTTP.count("GET", "/files/out.mp4")
    activity.downloadAgain(job)
    require(!job.canRetryDownload && !ended(), "Download again runs")
    await upscaleEventually("the GET of Download again") { UpscaleHTTP.count("GET", "/files/out.mp4") > gets }
    activity.remove(job)
    await upscaleEventually("the stop", ended)
    require(job.state == .cancelled(.alreadyStarted) && job.downloadFailure?.kind == .stopped && job.canRetryDownload
            && activity.jobs.contains { $0 === job }, "Cancel while it downloads again keeps it listed, stopped, with Download again: \(job.state)")
    UpscaleHTTP.holdFiles = false

    // Dismissed: no longer shown, still found for the panel and upscale_clip (the same file, range, model and size only).
    activity.remove(job)
    require(!activity.jobs.contains { $0 === job } && activity.job(forOriginal: source) == nil, "Dismiss takes the row away")
    require(activity.heldDownload(original: source, range: range, tier: tier.id, target: .p1080) === job,
            "the panel and upscale_clip still find the held upscale after its row was dismissed")
    require(activity.heldDownload(original: source, range: range, tier: tier.id, target: .p2160) == nil, "another size is another upscale")

    // Their Download again: listed again, the job read first, saved; nothing submitted again.
    let reads = UpscaleHTTP.count("GET", "/jobs/job-up")
    activity.downloadAgain(job)
    require(activity.jobs.contains { $0 === job }, "Download again lists the dismissed upscale again")
    await upscaleEventually("the upscale to be saved", ended)
    require(job.state == .done && job.outcome.map { FileManager.default.fileExists(atPath: $0.file.path) } == true,
            "Download again saves the upscale: \(job.state)")
    require(UpscaleHTTP.count("GET", "/jobs/job-up") > reads, "the upscale's Download again read the job's current result first")
    require(UpscaleHTTP.count("POST", "/uploads") == 1 && UpscaleHTTP.count("POST", "/jobs") == 1, "one upload and one /jobs in all")
    books("after Download again")
    if let file = job.outcome?.file { try? FileManager.default.removeItem(at: file) }
    activity.remove(job)
    require(activity.heldDownload(original: source, range: range, tier: tier.id, target: .p1080) == nil, "a saved upscale is held no more")
}

@MainActor
private func upscaleEventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}
