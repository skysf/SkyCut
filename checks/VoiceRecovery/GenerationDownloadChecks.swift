import CoreGraphics
import Foundation
import ImageIO
import SrtFlowCore
import SrtFlowMCPKit
import UniformTypeIdentifiers
@testable import SrtFlow

// A paid generation whose download did not finish (2026-11-24, backlog B40 and the review of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), with the real SkyStudioGenerationRun and a fake Sky Studio on the
// shared session (GenerationHTTP, registered only while these run; the base points at the loopback address; the key is a fixture key in
// SkyCut's in-memory cache, so the keychain is never read):
// - three lost connections: failed with download_network, the row's Download again, the job held for the AI's re-ask;
// - the row dismissed, the AI's re-ask (what generate_media with the same request calls) still downloads the same result under the
//   same job id, reading the job's current result first; one /jobs in all;
// - a stop while downloading keeps the result (download_stopped), and the next press saves it;
// - an optional SRT that did not come down: the video is saved with caption_issue, and the re-ask fetches only the SRT.

final class GenerationHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(method: String, path: String)] = []
    static var drops = 0
    static var captionDrops = 0
    static var holdFiles = false
    static var withCaption = false
    static var jobs = 0
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

    static func reset() {
        lock.withLock { requests = []; drops = 0; captionDrops = 0; holdFiles = false; withCaption = false; jobs = 0 }
    }

    static func count(_ method: String, _ prefix: String) -> Int { lock.withLock { requests.filter { $0.method == method && $0.path.hasPrefix(prefix) }.count } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.hasPrefix("/generation-check/") ?? false)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        Self.lock.lock()
        Self.requests.append((method, path))
        let isFile = path.contains("/files/")
        if isFile, Self.holdFiles { Self.lock.unlock(); return }   // no answer until the task is cancelled
        var answer: (Int, Data, String)?
        if path.hasSuffix("/files/image.png") {
            if Self.drops > 0 { Self.drops -= 1 } else { answer = (200, Self.image, "image/png") }
        } else if path.hasSuffix("/files/caption.srt") {
            if Self.captionDrops > 0 { Self.captionDrops -= 1 } else { answer = (200, Self.caption, "application/x-subrip") }
        } else if path.hasSuffix("/jobs"), method == "POST" {
            Self.jobs += 1
            answer = (200, Self.finished("gen-\(Self.jobs)"), "application/json")
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

@MainActor
func runGenerationDownloadChecks(_ root: URL) async throws {
    let folder = root.appendingPathComponent("generation-download", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    GenerationHTTP.reset()
    URLProtocol.registerClass(GenerationHTTP.self)
    setenv(SkyStudioAPI.baseEnvironmentKey, "http://127.0.0.1/generation-check/api/skycut/v1", 1)
    await SkyStudioKey.cache.remember("sk-" + String(repeating: "G", count: 43))
    await heldAndAskedAgain(folder)
    await stopped(folder)
    await missingCaption(folder)
    await SkyStudioKey.cache.remember(nil)
    unsetenv(SkyStudioAPI.baseEnvironmentKey)
    URLProtocol.unregisterClass(GenerationHTTP.self)
}

@MainActor
private func makeRun(_ folder: URL, stem: String) -> SkyStudioGenerationRun {
    let model = SkyStudioModel(json: ["id": "fixture-image", "kind": "image", "title": "Fixture Image"])!
    let quote = SkyStudioQuote(json: ["credits": 4, "typical_seconds": 10])!
    return SkyStudioGenerationRun(
        generation: SkyStudioGeneration(kind: .image, prompt: "a cabin in snow", params: [:], notes: [], operation: "generate"),
        model: model, quote: quote, references: SkyStudioReferencePlan(mode: "none", files: []), folder: folder, stem: stem,
        project: OpenProjects.shared.primary, reservation: SkyStudioJobGate.Reservation(credits: 4, day: Date()),
        idempotencyKey: UUID().uuidString.lowercased())
}

@MainActor
private func finished(_ job: AIJobs.Job) async -> JSONValue {
    await AIJobs.shared.wait(for: job, seconds: 30)
    return AIJobs.shared.json(job)
}

@MainActor
private func heldAndAskedAgain(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
    let job = makeRun(folder, stem: "held").start()
    let failed = await finished(job)
    let next = failed["next_step"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["download_attempts"] == 3
            && next.contains("call generate_media again with the same arguments") && next.contains("Download again"),
            "three lost connections: failed with download_network, both ways back named: \(failed)")
    guard let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == job.id }), row.retryDownload != nil else {
        return require(false, "the failed row stays with Download again")
    }
    require(SkyStudioHeldDownloads.isHeld(job.id), "the held result is there for the AI's re-ask")

    // The row dismissed: the AI's re-ask still downloads the same result under the same job id.
    SkyStudioGenerationActivity.shared.dismiss(row)
    require(!SkyStudioGenerationActivity.shared.runs.contains { $0 === row }, "the row is dismissed")
    let reads = GenerationHTTP.count("GET", "/generation-check/api/skycut/v1/jobs/gen-1")
    require(SkyStudioHeldDownloads.retry(job.id), "the re-ask starts Download again after the row was dismissed")
    require(SkyStudioGenerationActivity.shared.runs.contains { $0 === row } && job.status == .running,
            "the row is listed again and the same job runs again")
    let done = await finished(job)
    let file = done["file"]?.stringValue.map { AIWorkspace.shared.resolve($0) }
    require(done["status"] == "done" && done["code"] == nil && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image,
            "Download again saves the byte-identical result: \(done)")
    require(GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") == 1
            && GenerationHTTP.count("GET", "/generation-check/api/skycut/v1/jobs/gen-1") > reads,
            "one /jobs in all; Download again read the job's current result first")
}

@MainActor
private func stopped(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.holdFiles = true }
    let gets = GenerationHTTP.count("GET", "/generation-check/files/")
    let job = makeRun(folder, stem: "stopped").start()
    for _ in 0..<1500 {
        if GenerationHTTP.count("GET", "/generation-check/files/") > gets { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    AIJobs.shared.cancel(job)
    let stopped = await finished(job)
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.aiJobID == job.id }
    require(stopped["status"] == "cancelled" && stopped["code"] == "download_stopped" && row?.retryDownload != nil
            && row?.issue == SkyStudioDownloadWords.shown(.stopped),
            "a generation stopped while downloading keeps the paid result with Download again: \(stopped)")
    GenerationHTTP.lock.withLock { GenerationHTTP.holdFiles = false }
    row?.retryDownload?()
    let done = await finished(job)
    require(done["status"] == "done", "the next press saves it: \(done)")
}

@MainActor
private func missingCaption(_ folder: URL) async {
    GenerationHTTP.lock.withLock { GenerationHTTP.withCaption = true; GenerationHTTP.captionDrops = 3 }
    let job = makeRun(folder, stem: "captioned").start()
    let first = await finished(job)
    require(first["status"] == "done" && first["caption_file"] == nil
            && first["caption_issue"]?.stringValue?.contains("call generate_media again with the same arguments") == true,
            "the image is saved, and the missing SRT says how to fetch it: \(first)")
    require(SkyStudioHeldDownloads.retry(job.id), "the re-ask fetches the missing SRT")
    let second = await finished(job)
    let caption = second["caption_file"]?.stringValue.map(URL.init(fileURLWithPath:))
    require(second["status"] == "done" && second["caption_issue"] == nil && caption.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.caption,
            "only the SRT came down, under the same job id: \(second)")
    require(GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") == 3, "no new job for it")
}
