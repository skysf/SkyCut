import Foundation
import SrtFlowMCPKit

// 第 6 刀的接口：/models 怎么读、/quote 和 /jobs 发什么、任务的状态和成品怎么读、取消的两种结果、/uploads 之后 PUT 上去（只带服务器给的头、
// 不带 Key、文件原样）、把成品下载下来（不带 Key、下到一半不留半个文件）。全程走假协议（SkyStudioStub），不碰真的网络。
// 样例照 Sky Studio 仓库 docs/agents/skycut-api.md（main 5c8d6a0d 冻结）。

let jobBase = URL(string: "http://127.0.0.1:8123/api/skycut/v1")!
let jobKey = "sk-" + String(repeating: "A", count: 43)

func jobAPI() -> SkyStudioAPI {
    SkyStudioAPI(session: SkyStudioStub.session, base: jobBase, version: "0.18.50", machine: String(repeating: "a", count: 64))
}

/// 合同里「GET /models」的样例，外加一条没有 id 的（跳过）和一种这个 SkyCut 不认识的 kind（留着）。
let sampleModels = """
{"models": [
  {"id": "topaz-starlight", "kind": "upscale", "title": "Topaz Starlight",
   "price": {"per": "second", "credits_by_target": {"1080p": 30, "4K": 65}},
   "params": {"target": ["1080p", "4K"]},
   "limits": {"max_source_seconds": 30.5, "max_source_fps": 30,
              "max_output_pixels": 8294400, "max_upload_bytes": 209715200}},
  {"id": "bytedance-upscaler-pro", "kind": "upscale", "title": "ByteDance Upscaler Pro",
   "price": {"per": "second", "credits_by_target": {"1080p": 18, "2K": 36, "4K": 72}},
   "params": {"target": ["1080p", "2K", "4K"]},
   "limits": {"max_source_seconds": 30.5, "max_source_fps": 30,
              "max_output_pixels": 8294400, "max_upload_bytes": 209715200}},
  {"kind": "image", "title": "no id"},
  {"id": "future-model", "kind": "hologram", "title": "Something new", "extra": true}
]}
"""

/// 合同里「GET /jobs/{id}」做完的样子（upscale）。
let sampleDoneJob = """
{"job_id": "0b1d2c3e-1111-4a5b-9c8d-000000000001", "kind": "upscale", "status": "done", "phase": "saving",
 "queue_position": null, "phase_seconds": 3, "typical_seconds": 300, "poll_after_seconds": 15,
 "result": {"url": "https://cdn.skystudioai.com/generations/abc.mp4", "generation_id": "gen-1", "content_type": "video/mp4",
            "width": 3840, "height": 2160, "duration": 7.04, "fps": 29.97},
 "credits_charged": 455, "error": null}
"""

func runJobChecks() async {
    runCatalogChecks()
    await runQuoteAndJobChecks()
    await runTransferChecks()
}

private func runCatalogChecks() {
    guard let json = try? JSONValue.decode(Data(sampleModels.utf8)), let catalog = SkyStudioCatalog(json: json) else {
        check(false, "the /models sample reads")
        return
    }
    checkEqual(catalog.models.map(\.id), ["topaz-starlight", "bytedance-upscaler-pro", "future-model"], "an entry without an id is skipped, an unknown kind kept")
    checkEqual(catalog.models(kind: "upscale").map(\.id), ["topaz-starlight", "bytedance-upscaler-pro"], "the upscale models, in the server's order")
    let topaz = catalog.model("topaz-starlight", kind: "upscale")
    checkEqual(topaz?.title, "Topaz Starlight", "title")
    checkEqual(topaz?.choices("target"), ["1080p", "4K"], "Topaz has no 2K")
    checkEqual(catalog.model("bytedance-upscaler-pro", kind: "upscale")?.choices("target"), ["1080p", "2K", "4K"], "ByteDance targets")
    checkEqual(topaz?.limit("max_source_seconds"), 30.5, "30.5 s at most")
    checkEqual(topaz?.limit("max_source_fps"), 30, "30 fps at most")
    checkEqual(topaz?.limit("max_upload_bytes"), 209_715_200, "200 MB at most")
    checkEqual(topaz?.limit("nonsense"), nil, "a limit that is not there")
    checkEqual(topaz?.price["credits_by_target"]?["4K"]?.doubleValue, 65, "the display price is kept as it came")
    check(catalog.model("topaz-starlight", kind: "image") == nil, "a model is found by id and kind")
    check(SkyStudioCatalog(json: .object(["data": .array([])])) == nil, "no models array: not an answer")
}

private func runQuoteAndJobChecks() async {
    let api = jobAPI()
    let job = SkyStudioJobRequest(
        kind: "upscale", model: "topaz-starlight", inputs: ["video_url": "https://r2.example/originals/u/skycut/clip.mp4"],
        params: ["target": "4K", "source": ["width": 960, "height": 540, "seconds": 7.0, "fps": 29.97]],
        maxCredits: 455, idempotencyKey: "idem-1"
    )

    // 1. /quote：去掉 inputs、max_credits、idempotency_key，读回 credits、typical_seconds、plan。
    SkyStudioStub.reset { _ in
        .http(200, #"{"credits": 455, "typical_seconds": 300, "plan": {"factor": 4, "output_width": 3840, "output_height": 2160, "billing_tier": "4K", "capped": false, "wide": false}}"#)
    }
    let quote = try? await api.quote(job, key: jobKey)
    checkEqual(quote?.credits, 455, "the quote's credits")
    checkEqual(quote?.typicalSeconds, 300, "the quote's typical time")
    checkEqual(quote?.plan["output_width"]?.doubleValue, 3840, "upscale's plan is kept")
    let quoteSeen = SkyStudioStub.log.first
    checkEqual(quoteSeen?.method, "POST", "/quote is a POST")
    checkEqual(quoteSeen?.url, "http://127.0.0.1:8123/api/skycut/v1/quote", "the /quote address")
    checkEqual(quoteSeen?.headers["Authorization"], "Bearer \(jobKey)", "the key goes along")
    let quoteBody = quoteSeen?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(quoteBody?["kind"]?.stringValue, "upscale", "kind")
    checkEqual(quoteBody?["params"]?["source"]?["fps"]?.doubleValue, 29.97, "params as given")
    check(quoteBody?["inputs"] == nil && quoteBody?["max_credits"] == nil && quoteBody?["idempotency_key"] == nil,
          "/quote leaves out inputs, max_credits and idempotency_key")
    SkyStudioStub.reset { _ in .http(200, #"{"typical_seconds": 300}"#) }
    if case .badAnswer? = await expectFailure("a quote without credits", { _ = try await api.quote(job, key: jobKey) }) {} else {
        check(false, "a quote without credits is not an answer")
    }

    // 2. /jobs：带上 inputs、max_credits、idempotency_key；这一个请求多等一会儿；202 读成排队中的任务。
    SkyStudioStub.reset { _ in
        .http(202, #"{"job_id": "0b1d2c3e-1111-4a5b-9c8d-000000000001", "status": "queued", "credits_reserved": 455, "typical_seconds": 300, "poll_after_seconds": 15}"#)
    }
    let submitted = try? await api.submit(job, key: jobKey)
    checkEqual(submitted?.jobID, "0b1d2c3e-1111-4a5b-9c8d-000000000001", "the job id")
    checkEqual(submitted?.state, .queued, "queued")
    checkEqual(submitted?.creditsReserved, 455, "credits reserved")
    checkEqual(submitted?.pollAfterSeconds, 15, "ask again in 15 s")
    let jobSeen = SkyStudioStub.log.first
    checkEqual(jobSeen?.url, "http://127.0.0.1:8123/api/skycut/v1/jobs", "the /jobs address")
    checkEqual(jobSeen?.timeout, SkyStudioAPI.submitTimeout, "submitting waits longer than the other requests")
    let jobBody = jobSeen?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(jobBody?["inputs"]?["video_url"]?.stringValue, "https://r2.example/originals/u/skycut/clip.mp4", "inputs go along")
    checkEqual(jobBody?["max_credits"]?.doubleValue, 455, "max_credits goes along")
    checkEqual(jobBody?["idempotency_key"]?.stringValue, "idem-1", "the idempotency key goes along")
    check(jobBody?["prompt"] == nil, "no prompt, no prompt key")
    let narration = SkyStudioJobRequest(kind: "voice", model: "eleven-v4", prompt: "Hello there.", params: ["voice": "Rachel"])
    checkEqual(narration.quoteBody["prompt"]?.stringValue, "Hello there.", "the words are quoted too (narration is priced by length)")
    check(narration.idempotencyKey.count == 36 && narration.idempotencyKey == narration.idempotencyKey.lowercased(), "a fresh idempotency key")

    // 3. GET /jobs/{id}：做完的样子，成品、扣了多少。
    SkyStudioStub.reset { _ in .http(200, sampleDoneJob) }
    let done = try? await api.job("0b1d2c3e-1111-4a5b-9c8d-000000000001", key: jobKey)
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/jobs/0b1d2c3e-1111-4a5b-9c8d-000000000001", "the job's address")
    checkEqual(done?.state, .done, "done")
    check(done?.isFinished == true, "done is finished")
    checkEqual(done?.result?.url.absoluteString, "https://cdn.skystudioai.com/generations/abc.mp4", "the permanent result address")
    checkEqual(done?.result?.generationID, "gen-1", "the library row")
    checkEqual(done?.result?.fps, 29.97, "fps")
    checkEqual(done?.creditsCharged, 455, "credits charged")
    checkEqual(done?.error, nil, "no error")

    // H3 的视频不记像素和帧率：null 读成 nil（用的时候从文件读）；克隆的声音带 expires_at；旁白的 words 原样。
    let h3 = SkyStudioJobResult(json: .object([
        "url": "https://cdn.skystudioai.com/v.mp4", "width": .null, "height": .null, "fps": .null, "duration": 5.0
    ]))
    check(h3?.width == nil && h3?.fps == nil && h3?.duration == 5, "null sizes are unknown, not zero")
    let clone = SkyStudioJobResult(json: .object([
        "url": "https://cdn.skystudioai.com/c.wav", "expires_at": "2026-12-27T07:00:00.000Z", "content_type": "audio/wav", "duration": 2.4
    ]))
    checkEqual(clone?.expiresAt.map { Int($0.timeIntervalSince1970) }, 1_798_354_800, "a clone's expiry")
    let voice = SkyStudioJobResult(json: .object(["url": "https://cdn.skystudioai.com/n.mp3", "words": ["characters": ["H", "i"]]]))
    checkEqual(voice?.words?["characters"]?.arrayValue?.count, 2, "narration's character timings are kept as they came")
    check(SkyStudioJobResult(json: .object(["url": "not a url"])) == nil, "a result without an address is not a result")

    // 没做成：error 是一句话或 {code, message}；认不出的状态是 nil。
    let failedText = SkyStudioJobStatus(json: .object(["job_id": "j", "status": "failed", "error": "The provider failed."]))
    checkEqual(failedText?.error, "The provider failed.", "an error as a sentence")
    let failedObject = SkyStudioJobStatus(json: .object(["job_id": "j", "status": "failed", "error": ["code": "provider_error", "message": "fal failed."]]))
    checkEqual(failedObject?.error, "fal failed.", "an error as an object")
    checkEqual(SkyStudioJobStatus(json: .object(["job_id": "j", "status": "paused"]))?.state, nil, "an unknown status word")
    check(SkyStudioJobStatus(json: .object(["status": "queued"])) == nil, "no job id: not a status")

    // 任务号只当一节路径用。
    SkyStudioStub.reset { _ in .http(200, sampleDoneJob) }
    if case .badAnswer? = await expectFailure("a job id with a slash", { _ = try await api.job("../me", key: jobKey) }) {
        check(SkyStudioStub.log.isEmpty, "nothing was sent for a job id with a slash")
    } else {
        check(false, "a job id with a slash is refused")
    }

    // 4. 取消：排着队的退钱；开始了的 not_cancellable；别的错照旧抛。
    SkyStudioStub.reset { _ in .http(200, #"{"status": "cancelled", "credits_refunded": 455}"#) }
    let cancelled = try? await api.cancel("job-1", key: jobKey)
    checkEqual(cancelled, .cancelled(refunded: 455), "a queued job is cancelled and refunded")
    checkEqual(SkyStudioStub.log.first?.method, "POST", "cancel is a POST")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/jobs/job-1/cancel", "the cancel address")
    SkyStudioStub.reset { _ in .http(409, #"{"error": {"code": "not_cancellable", "message": "The job has started.", "status": "running"}}"#) }
    checkEqual(try? await api.cancel("job-1", key: jobKey), .notCancellable(status: "running"), "a started job cannot be cancelled")
    SkyStudioStub.reset { _ in .http(404, #"{"error": {"code": "not_found", "message": "No such job."}}"#) }
    if case .server(let error)? = await expectFailure("cancel an unknown job", { _ = try await api.cancel("job-1", key: jobKey) }) {
        checkEqual(error.code, "not_found", "other errors still throw")
    } else {
        check(false, "cancel of an unknown job throws")
    }
}

private func runTransferChecks() async {
    let api = jobAPI()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skystudio-job-checks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clip = folder.appendingPathComponent("clip.mp4")
    let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
    try? bytes.write(to: clip)

    // 1. /uploads → PUT：服务器给的头原样带上、不带 Key、文件原样、回 file_url；字节进度只升不降、最后是 1。
    SkyStudioStub.reset { seen in
        if seen.url.hasSuffix("/uploads") {
            return .http(200, #"{"upload_url": "http://127.0.0.1:8124/r2/originals/u/skycut/clip.mp4?X-Amz-Signature=abc", "method": "PUT", "headers": {"Content-Type": "video/mp4", "x-amz-meta-app": "skycut"}, "file_url": "https://r2.example/originals/u/skycut/clip.mp4", "expires_at": "2026-10-28T09:00:00Z"}"#)
        }
        return .http(200, "")
    }
    let fractions = FractionLog()
    let link = try? await api.upload(fileURL: clip, contentType: "video/mp4", purpose: "video", key: jobKey) { fractions.add($0) }
    checkEqual(link?.absoluteString, "https://r2.example/originals/u/skycut/clip.mp4", "the file_url comes back")
    let log = SkyStudioStub.log
    checkEqual(log.count, 2, "/uploads, then the PUT")
    let ask = log.first.flatMap { $0.body }.flatMap { try? JSONValue.decode($0) }
    checkEqual(ask?["filename"]?.stringValue, "clip.mp4", "the file name")
    checkEqual(ask?["bytes"]?.intValue, 200_000, "the size")
    checkEqual(ask?["purpose"]?.stringValue, "video", "the purpose")
    checkEqual(ask?["content_type"]?.stringValue, "video/mp4", "the content type")
    let put = log.last
    checkEqual(put?.method, "PUT", "the file goes up with PUT")
    checkEqual(put?.url, "http://127.0.0.1:8124/r2/originals/u/skycut/clip.mp4?X-Amz-Signature=abc", "to the signed address as given")
    checkEqual(put?.headers["x-amz-meta-app"], "skycut", "every header the server gave goes along")
    checkEqual(put?.headers["Content-Type"], "video/mp4", "the content type the server gave")
    check(put?.headers["Authorization"] == nil, "the key never goes to the storage address")
    checkEqual(put?.body, bytes, "the file goes up as it is")
    check(fractions.isCompleteAndMonotonic, "upload progress only rises and ends at 1: \(fractions.all)")

    SkyStudioStub.reset { seen in
        seen.url.hasSuffix("/uploads")
            ? .http(200, #"{"upload_url": "http://127.0.0.1:8124/r2/x", "method": "PUT", "headers": {}, "file_url": "https://r2.example/x"}"#)
            : .http(403, "<Error>SignatureDoesNotMatch</Error>")
    }
    if case .badAnswer(let status)? = await expectFailure("a refused PUT", {
        _ = try await api.upload(fileURL: clip, contentType: "video/mp4", purpose: "video", key: jobKey)
    }) {
        checkEqual(status, 403, "a refused PUT says its status")
    } else {
        check(false, "a refused PUT fails")
    }
    SkyStudioStub.reset { _ in .http(200, #"{"method": "PUT"}"#) }
    if case .badAnswer? = await expectFailure("/uploads without addresses", {
        _ = try await api.upload(fileURL: clip, contentType: "video/mp4", purpose: "video", key: jobKey)
    }) {} else {
        check(false, "/uploads without upload_url / file_url is not an answer")
    }

    // 2. 下载成品：不带 Key、文件原样、进度到 1；404 时目的地上什么都不留。
    let result = Data((0..<150_000).map { UInt8(($0 * 7) % 256) })
    SkyStudioStub.reset { _ in .data(200, result) }
    let destination = folder.appendingPathComponent("out.mp4")
    let downloaded = FractionLog()
    do {
        try await api.download(URL(string: "https://cdn.skystudioai.com/generations/abc.mp4")!, to: destination) { downloaded.add($0) }
    } catch {
        check(false, "the download works: \(error)")
    }
    checkEqual(try? Data(contentsOf: destination), result, "the file arrives as it is")
    check(SkyStudioStub.log.first?.headers["Authorization"] == nil, "the key never goes to the result address")
    check(downloaded.isCompleteAndMonotonic, "download progress only rises and ends at 1: \(downloaded.all)")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.contains(".part-") } ?? []
    check(leftovers.isEmpty, "no partial file left behind")

    SkyStudioStub.reset { _ in .data(404, Data("gone".utf8)) }
    let missing = folder.appendingPathComponent("missing.mp4")
    if case .badAnswer(let status)? = await expectFailure("a missing result", {
        try await api.download(URL(string: "https://cdn.skystudioai.com/generations/gone.mp4")!, to: missing)
    }) {
        checkEqual(status, 404, "a missing result says its status")
    } else {
        check(false, "a missing result fails")
    }
    check(!FileManager.default.fileExists(atPath: missing.path), "nothing is left where the missing file would go")
}

/// 上传 / 下载报上来的字节比例（回调在 URLSession 的线程上）。
final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ fraction: Double) { lock.lock(); items.append(fraction); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return items }
    /// 只升不降、都在 0…1 里、最后一个是 1。
    var isCompleteAndMonotonic: Bool { all == all.sorted() && all.allSatisfy { (0...1).contains($0) } && all.last == 1 }
}
