import CoreGraphics
import Foundation
import ImageIO
import SrtFlowCore
import SrtFlowMCPKit
import UniformTypeIdentifiers
@testable import SrtFlow

// A paid generation whose download did not finish (2026-11-24 / 25, backlog B40 and the reviews of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), with the real SkyStudioGenerationRun and a fake Sky Studio on the
// shared session (GenerationHTTP, registered only while these run; the base points at the loopback address; the key is a fixture key in
// SkyCut's in-memory cache, so the keychain is never read):
// - three lost connections: failed with download_network; the next step names this job's own idempotency_key and row, and says a call
//   without that key is a new generation, charged again; the job is held under its id;
// - a Download again that fails again keeps it held (it once released it as it started), and asking while it runs starts nothing more;
// - the row dismissed, the job's own key path (what generate_media with that key calls) still downloads the same result under the
//   same job id, reading the job's current result first; then nothing is held; one /jobs in all;
// - a stop while downloading keeps the result (download_stopped, with the one GET it sent), and the next press saves it;
// - empty answers are never the result: held (download_incomplete), then saved;
// - an optional SRT that did not come down: the video is saved with caption_issue naming the key, and that key fetches only the SRT.
// The tool entry itself (generate_media with and without the key, a changed canvas) is PaidToolEntryChecks.

final class GenerationHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(method: String, path: String, body: JSONValue)] = []
    static var drops = 0
    static var emptyFiles = 0
    static var captionDrops = 0
    static var holdFiles = false
    static var withCaption = false
    static var jobs = 0
    /// How many of the next `GET /jobs/{id}` answer 503 (OfficialRecoveryDownloadChecks: the job cannot be read now).
    static var jobReadFailures = 0
    static let image: Data = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
    static let caption = Data("1\n00:00:00,000 --> 00:00:01,000\nSnow.\n".utf8)
    /// Sky Studio's `/me` for the official tool entry, which needs a verified account (checks/SkyStudio/Fixtures/me-pro-v1.json).
    static let me = Data(#"""
    {"account": {"id": "acct-check", "email": "check@example.com"}, "credits": {"balance": 1000}, "server_time": "2026-11-26T00:00:00Z",
     "skycut": {"plan": "pro", "account_plan": "pro", "pro_source": "subscription", "trial_started_at": null, "trial_ends_at": null,
      "trial_unavailable": null, "paid_until": "2026-12-26T00:00:00Z", "features": {"mcp": true, "watermark": false},
      "valid_until": "2026-12-26T00:00:00Z", "min_version": "0.18.47", "max_running_jobs": 3,
      "recharge_url": "https://skystudioai.com/app?credits=1", "upgrade_url": "https://skystudioai.com/app/skycut/pro",
      "manage_machines_url": "https://skystudioai.com/app/skycut/machines", "plan_reason": null, "plan_message": null,
      "auto_renews": true, "grace_until": null, "machines": {"limit": 2, "used": 1, "window_days": 30, "current_allowed": true}}}
    """#.utf8)
    /// One image model, as Sky Studio's /models lists it (checks/SkyStudio/Fixtures/models-image-2026-11-07.json), for the tool entry.
    static let catalog: JSONValue = ["models": [[
        "id": "seedream5-flash", "kind": "image", "title": "Seedream 5.0 Flash",
        "price": ["per": "image", "credits": 8, "credits_by_resolution": ["2K": 8], "credits_with_references_by_resolution": ["2K": 8]],
        "params": ["aspect_ratio": ["1:1", "3:2", "2:3", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"], "resolution": ["2K"],
                   "reference_image_count": [0, 10]],
        "defaults": ["aspect_ratio": "16:9", "resolution": "2K"],
        "limits": ["max_prompt_characters": 4000, "max_upload_bytes": 31457280]
    ]]]

    static func reset() {
        lock.withLock { requests = []; drops = 0; emptyFiles = 0; captionDrops = 0; holdFiles = false; withCaption = false; jobs = 0; jobReadFailures = 0 }
    }

    static func count(_ method: String, _ prefix: String) -> Int { lock.withLock { requests.filter { $0.method == method && $0.path.hasPrefix(prefix) }.count } }
    static func bodies(_ method: String, _ suffix: String) -> [JSONValue] {
        lock.withLock { requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.map(\.body) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.hasPrefix("/generation-check/") ?? false)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        let sent = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.lock()
        Self.requests.append((method, path, (try? JSONValue.decode(sent)) ?? .null))
        let isFile = path.contains("/files/")
        if isFile, Self.holdFiles { Self.lock.unlock(); return }   // no answer until the task is cancelled
        var answer: (Int, Data, String)?
        if path.hasSuffix("/files/image.png") {
            if Self.drops > 0 { Self.drops -= 1 }
            else if Self.emptyFiles > 0 { Self.emptyFiles -= 1; answer = (200, Data(), "image/png") }
            else { answer = (200, Self.image, "image/png") }
        } else if path.hasSuffix("/files/caption.srt") {
            if Self.captionDrops > 0 { Self.captionDrops -= 1 } else { answer = (200, Self.caption, "application/x-subrip") }
        } else if path.hasSuffix("/models") {
            answer = (200, (try? Self.catalog.encodedData()) ?? Data(), "application/json")
        } else if path.hasSuffix("/me") {
            answer = (200, Self.me, "application/json")
        } else if path.hasSuffix("/quote"), method == "POST" {
            answer = (200, Data(#"{"credits": 8, "typical_seconds": 10}"#.utf8), "application/json")
        } else if path.hasSuffix("/jobs"), method == "POST" {
            Self.jobs += 1
            answer = (200, Self.finished("gen-\(Self.jobs)"), "application/json")
        } else if path.contains("/jobs/"), Self.jobReadFailures > 0 {
            Self.jobReadFailures -= 1
            answer = (503, Data(#"{"error": {"code": "unavailable", "message": "Try again later."}}"#.utf8), "application/json")
        } else if let range = path.range(of: "/jobs/") {
            answer = (200, Self.finished(String(path[range.upperBound...])), "application/json")
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

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(buffer, count: count)
        }
        return bytes
    }

    /// Called with the lock held.
    private static func finished(_ id: String) -> Data {
        var result: [String: JSONValue] = ["url": "http://127.0.0.1/generation-check/files/image.png", "content_type": "image/png",
                                           "width": 4, "height": 4, "generation_id": "g-1"]
        if withCaption { result["caption_file"] = "http://127.0.0.1/generation-check/files/caption.srt" }
        let status: JSONValue = ["job_id": .string(id), "kind": "image", "status": "done", "credits_charged": 4,
                                 "billing": ["status": "charged", "credits_charged": 4], "result": .object(result)]
        return (try? status.encodedData()) ?? Data()
    }
}

/// The fake Sky Studio for generation, its address and a fixture key, for the duration of `body`.
@MainActor
func withGenerationHTTP(_ body: () async throws -> Void) async rethrows {
    GenerationHTTP.reset()
    URLProtocol.registerClass(GenerationHTTP.self)
    setenv(SkyStudioAPI.baseEnvironmentKey, "http://127.0.0.1/generation-check/api/skycut/v1", 1)
    await SkyStudioKey.cache.remember("sk-" + String(repeating: "G", count: 43))
    SkyStudioCatalogCache.shared.forget()
    defer {
        unsetenv(SkyStudioAPI.baseEnvironmentKey)
        URLProtocol.unregisterClass(GenerationHTTP.self)
        SkyStudioCatalogCache.shared.forget()
    }
    try await body()
    await SkyStudioKey.cache.remember(nil)
}

@MainActor
func runGenerationDownloadChecks(_ root: URL) async throws {
    let folder = root.appendingPathComponent("generation-download", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    await withGenerationHTTP {
        await heldAndDownloadedAgain(folder)
        await stopped(folder)
        await emptyAnswers(folder)
        await missingCaption(folder)
    }
}

@MainActor
private func makeRun(_ folder: URL, stem: String, key: String = UUID().uuidString.lowercased()) -> SkyStudioGenerationRun {
    let model = SkyStudioModel(json: ["id": "fixture-image", "kind": "image", "title": "Fixture Image"])!
    let quote = SkyStudioQuote(json: ["credits": 4, "typical_seconds": 10])!
    return SkyStudioGenerationRun(
        generation: SkyStudioGeneration(kind: .image, prompt: "a cabin in snow", params: [:], notes: [], operation: "generate"),
        model: model, quote: quote, references: SkyStudioReferencePlan(mode: "none", files: []), folder: folder, stem: stem,
        project: OpenProjects.shared.primary, reservation: SkyStudioJobGate.Reservation(credits: 4, day: Date()), idempotencyKey: key)
}

@MainActor
func finishedJob(_ job: AIJobs.Job) async -> JSONValue {
    await AIJobs.shared.wait(for: job, seconds: 30)
    return AIJobs.shared.json(job)
}

private let files = "/generation-check/files/"
private let jobsPath = "/generation-check/api/skycut/v1/jobs"

@MainActor
private func heldAndDownloadedAgain(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
    let key = "held-\(UUID().uuidString.prefix(8))"
    let job = makeRun(folder, stem: "held", key: key).start()
    let failed = await finishedJob(job)
    let next = failed["next_step"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["download_attempts"] == 3
            && next.contains("idempotency_key \"\(key)\"") && next.contains("Download again")
            && next.contains("A call without that idempotency_key, or with another one, is a new generation and is charged again"),
            "three lost connections: download_network; the next step names this job's own key and row and says a call without it is "
                + "charged again: \(failed)")
    guard let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == job.id }), row.retryDownload != nil else {
        return require(false, "the failed row stays with Download again")
    }
    require(SkyStudioHeldDownloads.isHeld(job.id), "the held result is there for the job's own key")

    // A Download again that fails again keeps it held; asking while it runs starts nothing more.
    GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
    let gets = GenerationHTTP.count("GET", files)
    require(SkyStudioHeldDownloads.retry(job.id) && job.status == .running && SkyStudioHeldDownloads.isHeld(job.id),
            "Download again runs, and the result stays held while it does")
    _ = SkyStudioHeldDownloads.retry(job.id)
    let again = await finishedJob(job)
    require(again["code"] == "download_network" && row.retryDownload != nil && SkyStudioHeldDownloads.isHeld(job.id),
            "a Download again that fails again keeps the result held with its button: \(again)")
    require(GenerationHTTP.count("GET", files) == gets + 3, "asked again while it ran: no second download (\(GenerationHTTP.count("GET", files) - gets) GETs)")

    // The row dismissed: the job's own key path still downloads the same result under the same job id.
    SkyStudioGenerationActivity.shared.dismiss(row)
    require(!SkyStudioGenerationActivity.shared.runs.contains { $0 === row }, "the row is dismissed")
    let reads = GenerationHTTP.count("GET", jobsPath + "/gen-1")
    require(SkyStudioHeldDownloads.retry(job.id), "the job's own key starts Download again after the row was dismissed")
    require(SkyStudioGenerationActivity.shared.runs.contains { $0 === row } && job.status == .running,
            "the row is listed again and the same job runs again")
    let done = await finishedJob(job)
    let file = done["file"]?.stringValue.map { AIWorkspace.shared.resolve($0) }
    require(done["status"] == "done" && done["code"] == nil && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image,
            "Download again saves the byte-identical result: \(done)")
    require(!SkyStudioHeldDownloads.isHeld(job.id) && row.retryDownload == nil, "once the result came down nothing is held for it")
    require(GenerationHTTP.count("POST", jobsPath) == 1 && GenerationHTTP.count("GET", jobsPath + "/gen-1") > reads,
            "one /jobs in all; Download again read the job's current result first")
}

@MainActor
private func stopped(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.holdFiles = true }
    let gets = GenerationHTTP.count("GET", files)
    let job = makeRun(folder, stem: "stopped").start()
    for _ in 0..<1500 {
        if GenerationHTTP.count("GET", files) > gets { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    AIJobs.shared.cancel(job)
    let stopped = await finishedJob(job)
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.aiJobID == job.id }
    require(stopped["status"] == "cancelled" && stopped["code"] == "download_stopped" && stopped["download_attempts"] == 1
            && row?.retryDownload != nil && row?.issue == SkyStudioDownloadWords.shown(.stopped(attempts: 1)),
            "a generation stopped while downloading keeps the paid result with Download again, and says the one GET it sent: \(stopped)")
    GenerationHTTP.lock.withLock { GenerationHTTP.holdFiles = false }
    row?.retryDownload?()
    let done = await finishedJob(job)
    require(done["status"] == "done", "the next press saves it: \(done)")
}

@MainActor
private func emptyAnswers(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.emptyFiles = 3 }
    let job = makeRun(folder, stem: "empty").start()
    let empty = await finishedJob(job)
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.aiJobID == job.id }
    require(empty["status"] == "failed" && empty["code"] == "download_incomplete" && empty["download_attempts"] == 3
            && row?.retryDownload != nil && SkyStudioHeldDownloads.isHeld(job.id),
            "three empty answers are never the result: held with Download again (download_incomplete): \(empty)")
    row?.retryDownload?()
    let done = await finishedJob(job)
    require(done["status"] == "done", "Download again then saves the whole result: \(done)")
}

@MainActor
private func missingCaption(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.withCaption = true; GenerationHTTP.captionDrops = 3 }
    let key = "caption-\(UUID().uuidString.prefix(8))"
    let posts = GenerationHTTP.count("POST", jobsPath)
    let job = makeRun(folder, stem: "captioned", key: key).start()
    let first = await finishedJob(job)
    let issue = first["caption_issue"]?.stringValue ?? ""
    require(first["status"] == "done" && first["caption_file"] == nil && issue.contains("idempotency_key \"\(key)\"")
            && issue.contains("A call without that idempotency_key, or with another one, is a new generation and is charged again"),
            "the image is saved, and the missing SRT names this job's own key: \(first)")
    require(SkyStudioHeldDownloads.retry(job.id), "that key fetches the missing SRT")
    let second = await finishedJob(job)
    let caption = second["caption_file"]?.stringValue.map(URL.init(fileURLWithPath:))
    require(second["status"] == "done" && second["caption_issue"] == nil && caption.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.caption,
            "only the SRT came down, under the same job id: \(second)")
    require(GenerationHTTP.count("POST", jobsPath) == posts + 1 && !SkyStudioHeldDownloads.isHeld(job.id),
            "no new job for it, and nothing held once it is here")
}
