import Foundation
import SrtFlowMCPKit

// A paid upscale's download (2026-11-24, backlog B40 and the review of PR #554; docs/bugfixes/2026-11-24-download-lost-connection-no-
// retry.md), through the real pipeline against the fake Sky Studio (SkyStudioStub):
// - three lost connections: the pipeline throws UpscaleUndelivered (interrupted, three GETs) carrying what Download again needs, and
//   Sky Studio's charge (72 of the 75 reserved) was handed over as soon as it was made, before any download (UpscaleJob settles the
//   day's books there, whatever happens to the download);
// - Download again (UpscalePipeline.deliver) saves the same result with no new upload and no new job;
// - a stop while downloading keeps the result held (stopped).
// UpscaleJob's glue (settling at `onMade`, holding, the row and the panel) is pinned by checks/sky-studio-wiring/download-retry.sh.

func runUpscaleDownloadChecks(_ request: UpscaleRequest, base: String, bucket: String, uploaded: String, resultURL: String, fakeBytes: Data,
                              ffmpeg: URL?, work: URL) async {
    var retry = SkyStudioDownloadRetry()
    retry.sleep = { _ in }
    let api = SkyStudioAPI(session: SkyStudioStub.session, base: URL(string: base)!, version: "0.18.50", machine: String(repeating: "a", count: 64),
                           downloadRetry: retry)
    let done = #"{"job_id": "job-up", "status": "done", "credits_charged": 72, "result": {"url": "\#(resultURL)", "generation_id": "gen-up", "content_type": "video/mp4", "width": 1920, "height": 1080, "duration": 2.5, "fps": 24}}"#
    let drops = DropCount(3)
    SkyStudioStub.reset { seen in
        switch (seen.method, seen.url) {
        case ("POST", base + "/uploads"): return .http(200, uploaded)
        case ("PUT", bucket): return .http(200, "")
        case ("POST", base + "/jobs"), ("GET", base + "/jobs/job-up"): return .http(200, done)
        case ("GET", resultURL): return drops.take() ? .failure(.networkConnectionLost) : .data(200, fakeBytes)
        default: return .http(404, #"{"error": {"code": "not_found", "message": "unexpected \#(seen.method) \#(seen.url)"}}"#)
        }
    }
    let made = MadeLog()
    var held: UpscaleUndelivered?
    do {
        _ = try await UpscalePipeline.run(request, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: { _ in },
                                          onMade: { made.add($0) }) { _ in }
        check(false, "three lost connections: the upscale is not saved")
    } catch let undelivered as UpscaleUndelivered {
        held = undelivered
    } catch {
        check(false, "three lost connections end as UpscaleUndelivered, got \(error)")
    }
    check(held?.failure.kind == .interrupted && held?.failure.attempts == 3 && held?.delivery.jobID == "job-up"
            && held?.delivery.creditsCharged == 72 && abs((held?.delivery.offset ?? 0) - request.range.start) < 0.001,
          "three lost connections: held with the job, its charge and where its part starts")
    check(made.all.count == 1 && made.all.first?.creditsCharged == 72,
          "Sky Studio's charge (72, not the 75 reserved) is handed over as soon as it is made, before any download")
    checkEqual(SkyStudioStub.log.filter { $0.url == resultURL }.count, 3, "three GETs of the result")
    checkEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [], [], "nothing half-written is left")
    guard let held else { return }

    // Download again: only the delivery (GETs), saved as the first try would have.
    do {
        let outcome = try await UpscalePipeline.deliver(request, held.delivery, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work) { _ in }
        check(FileManager.default.fileExists(atPath: outcome.file.path) && outcome.creditsCharged == 72 && outcome.jobID == "job-up",
              "Download again saves the same result: \(outcome.file.lastPathComponent)")
        try? FileManager.default.removeItem(at: outcome.file)
    } catch {
        check(false, "Download again saves the result, got \(error)")
    }
    check(SkyStudioStub.log.filter { $0.method == "POST" }.map(\.url) == [base + "/uploads", base + "/jobs"],
          "Download again sends no new upload and no new job")

    // A stop while downloading: the result stays held for Download again.
    let stopping = Task { () -> Error? in
        while !Task.isCancelled { await Task.yield() }
        do {
            _ = try await UpscalePipeline.deliver(request, held.delivery, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work) { _ in }
            return nil
        } catch {
            return error
        }
    }
    stopping.cancel()
    let stopped = await stopping.value
    check((stopped as? UpscaleUndelivered)?.failure.kind == .stopped, "a stop while downloading keeps the paid result: \(String(describing: stopped))")
}

/// How many of the next result GETs lose their connection (the stub answers on URLSession's threads).
private final class DropCount: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(_ count: Int) { left = count }
    func take() -> Bool { lock.withLock { guard left > 0 else { return false }; left -= 1; return true } }
}

/// What `onMade` handed over.
private final class MadeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UpscaleDelivery] = []
    func add(_ delivery: UpscaleDelivery) { lock.withLock { items.append(delivery) } }
    var all: [UpscaleDelivery] { lock.withLock { items } }
}
