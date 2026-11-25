import Foundation
import SrtFlowMCPKit

// Downloads of paid results (2026-11-24, backlog B40; docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md):
// SkyStudioAPI.download resumes a GET the network broke from where it stopped when the system kept what arrived, starts it again
// otherwise, three GETs in all with a short pause before each new one; an HTTP answer is never tried again as it is, except that a
// 403 / 404 / 410 asks Sky Studio once for a fresh address; a cancel and a connection that does not work end it. Giving up is
// SkyStudioDownloadFailure (`download_network` / `download_refused`, the GET count). Run against the real local server
// (UploadServer, no proxy): the system's own transfer and resume code is what is tested.

func runDownloadRetryChecks(_ server: UploadServer) async {
    runDownloadFailureWordsChecks()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skystudio-download-retry-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = Data((0..<1_500_000).map { UInt8(($0 * 7) % 253) })
    await runResumeChecks(server, folder: folder, result: result)
    await runDownloadAnswerChecks(server, folder: folder, result: result)
    await runDownloadStopChecks(server, folder: folder, result: result)
    await runDownloadEdgeChecks(server, folder: folder, result: result) { events, timeout in downloadAPI(server, events: events, getTimeout: timeout) }
}

/// Waits between tries are recorded, not slept (unless `sleep` is given).
private func downloadAPI(_ server: UploadServer, events: UploadEvents, sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
                         getTimeout: TimeInterval = 600) -> SkyStudioAPI {
    var retry = SkyStudioDownloadRetry()
    retry.sleep = sleep ?? { seconds in events.add(.pause(seconds)) }
    retry.getTimeout = getTimeout
    return SkyStudioAPI(session: uploadSession, base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!, version: "0.18.50",
                        machine: String(repeating: "a", count: 64), downloadRetry: retry)
}

private func resultGets(_ server: UploadServer) -> [UploadServer.Seen] { server.log.filter { $0.method == "GET" } }

private func progress(_ events: UploadEvents) -> [Double] {
    events.all.compactMap { if case .progress(let value) = $0 { return value } else { return nil } }
}

private func leftovers(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(".part-") }
}

/// The failure a download ended with, or nil (any other outcome is recorded).
private func downloadFailure(_ message: String, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async
    -> SkyStudioDownloadFailure? {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a SkyStudioDownloadFailure, got none")
    } catch let failure as SkyStudioDownloadFailure {
        return failure
    } catch {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a SkyStudioDownloadFailure, got \(error)")
    }
    return nil
}

/// How often `renew` was asked, and what it answers.
private final class Renewals: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    let answer: URL?
    init(_ answer: URL?) { self.answer = answer }
    var count: Int { lock.lock(); defer { lock.unlock() }; return asked }
    var renew: @Sendable () async throws -> URL? {
        { [self] in
            lock.withLock { asked += 1 }
            return answer
        }
    }
}

private func runResumeChecks(_ server: UploadServer, folder: URL, result: Data) async {
    // One drop mid-body on a result the system can resume: the second GET asks for the rest (Range + If-Range) and the file is whole.
    server.configureDownload(gets: [.cut(400_000), .file], result: result)
    var events = UploadEvents()
    let resumed = folder.appendingPathComponent("resumed.mp4")
    do {
        let sink = events
        try await downloadAPI(server, events: sink).download(server.resultURL("a.mp4"), to: resumed, onProgress: { sink.add(.progress($0)) })
    } catch {
        check(false, "one drop on a resumable result: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: resumed), result, "one drop, resumed: the file is byte-identical")
    var gets = resultGets(server)
    let offset = gets.count == 2 ? Int(gets[1].headers["range"]?.dropFirst(6).prefix { $0 != "-" } ?? "") ?? 0 : 0
    check(gets.count == 2 && gets[0].headers["range"] == nil && offset > 0 && gets[1].headers["if-range"] == UploadServer.etag,
          "the second GET resumes where the first stopped (Range bytes=\(offset)-, If-Range the ETag): \(gets.map { $0.headers["range"] ?? "-" })")
    checkEqual(events.pauses, [1], "a short pause before the resumed try")
    let resumedProgress = progress(events)
    check(resumedProgress == resumedProgress.sorted() && resumedProgress.last == 1,
          "a resumed download's progress never goes back and ends at 1: \(resumedProgress)")
    let afterPause = events.all.drop { if case .pause = $0 { return false } else { return true } }.dropFirst()
    if case .progress(let first)? = afterPause.first {
        check(first >= Double(offset) / Double(result.count) - 0.011, "progress goes on from the bytes already here (\(first))")
    }

    // The same drop where the server gives no ETag / Accept-Ranges: nothing can be resumed, so the next GET starts from the beginning.
    server.configureDownload(gets: [.cut(400_000), .file], result: result, validators: false)
    events = UploadEvents()
    let restarted = folder.appendingPathComponent("restarted.mp4")
    do {
        let sink = events
        try await downloadAPI(server, events: sink).download(server.resultURL("a.mp4"), to: restarted, onProgress: { sink.add(.progress($0)) })
    } catch {
        check(false, "one drop without validators: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: restarted), result, "one drop, started again: the file is byte-identical")
    gets = resultGets(server)
    check(gets.count == 2 && gets.allSatisfy { $0.headers["range"] == nil }, "nothing to resume: the second GET asks for all of it")
    check(events.restartsBeforeEachPause, "progress goes back to 0 before the new try and ends at 1: \(events.all)")

    // A reset, then a cut of the resumed try, then the rest: the third GET finishes it.
    server.configureDownload(gets: [.cutReset(300_000), .cut(300_000), .file], result: result)
    events = UploadEvents()
    let third = folder.appendingPathComponent("third.mp4")
    do {
        try await downloadAPI(server, events: events).download(server.resultURL("a.mp4"), to: third)
    } catch {
        check(false, "a reset and a cut: the third GET works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: third), result, "after a reset and a cut the file is byte-identical")
    checkEqual(resultGets(server).count, 3, "three GETs")
    checkEqual(events.pauses, [1, 2], "a pause before each new try")

    // Three drops: interrupted after three GETs, nothing left where the file would go, nothing half-written beside it.
    server.configureDownload(gets: [.cut(300_000)], result: result)
    events = UploadEvents()
    let interrupted = folder.appendingPathComponent("interrupted.mp4")
    let failure = await downloadFailure("three drops") {
        try await downloadAPI(server, events: events).download(server.resultURL("a.mp4"), to: interrupted)
    }
    checkEqual(failure?.kind, .interrupted, "three drops: interrupted")
    checkEqual(failure?.attempts, 3, "three GETs")
    checkEqual(failure?.code, "download_network", "the code for tool results and get_job")
    checkEqual(failure?.lastError, "NSURLErrorDomain -1005", "a dropped connection is URLError -1005")
    checkEqual(resultGets(server).count, 3, "never a fourth GET")
    checkEqual(events.pauses, [1, 2], "two pauses")
    check(!FileManager.default.fileExists(atPath: interrupted.path) && leftovers(folder).isEmpty, "no file and no partial file left behind")

    // Later, Download again: the same address gives the same bytes (nothing was submitted to get them).
    server.configureDownload(gets: [.file], result: result)
    do {
        try await downloadAPI(server, events: UploadEvents()).download(server.resultURL("a.mp4"), to: interrupted)
    } catch {
        check(false, "a later download of the same result works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: interrupted), result, "a later retry gets the byte-identical file")
}

private func runDownloadAnswerChecks(_ server: UploadServer, folder: URL, result: Data) async {
    // 403 (an expired address): Sky Studio is asked once for a fresh one, and that one works.
    server.configureDownload(gets: [.status(403), .file], result: result)
    var renewals = Renewals(server.resultURL("fresh.mp4"))
    var events = UploadEvents()
    let renewed = folder.appendingPathComponent("renewed.mp4")
    do {
        try await downloadAPI(server, events: events).download(server.resultURL("old.mp4"), to: renewed, renew: renewals.renew)
    } catch {
        check(false, "a 403 then a fresh address: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: renewed), result, "the fresh address gives the byte-identical file")
    checkEqual(renewals.count, 1, "a fresh address is asked for once")
    checkEqual(resultGets(server).map(\.path), ["/files/old.mp4", "/files/fresh.mp4"], "the old address once, then the fresh one")
    checkEqual(events.pauses, [], "no pause before trying the fresh address")

    // A 404 with no way to renew: refused after one GET, no pause, nothing tried again.
    server.configureDownload(gets: [.status(404), .file], result: result)
    events = UploadEvents()
    var failure = await downloadFailure("a 404 with no renewal") {
        try await downloadAPI(server, events: events).download(server.resultURL("gone.mp4"), to: folder.appendingPathComponent("gone.mp4"))
    }
    checkEqual(failure?.kind, .refused(status: 404), "a 404: refused")
    checkEqual(failure?.code, "download_refused", "a refusal's code")
    checkEqual(failure?.attempts, 1, "one GET")
    checkEqual(events.pauses, [], "no pause")
    checkEqual(resultGets(server).count, 1, "a 404 is never tried again blindly")

    // A 403 whose fresh address is the same one: refused, never the same GET again.
    server.configureDownload(gets: [.status(403), .file], result: result)
    renewals = Renewals(server.resultURL("old.mp4"))
    failure = await downloadFailure("a 403 renewed to the same address") {
        try await downloadAPI(server, events: UploadEvents()).download(server.resultURL("old.mp4"), to: folder.appendingPathComponent("same.mp4"),
                                                                       renew: renewals.renew)
    }
    check(failure?.kind == .refused(status: 403) && failure?.triedFreshAddress == false && failure?.attempts == 1
            && failure?.message.contains("fresh address") == false,
          "the same address again: refused after one GET, never said to be a fresh address: \(String(describing: failure))")
    checkEqual(renewals.count, 1, "asked once")
    checkEqual(resultGets(server).count, 1, "the same address is not tried again")

    // 403, a fresh address, 403 again: refused after two GETs; a fresh address is asked for only once.
    server.configureDownload(gets: [.status(403), .status(410)], result: result)
    renewals = Renewals(server.resultURL("fresh.mp4"))
    failure = await downloadFailure("a 403 then a 410 at the fresh address") {
        try await downloadAPI(server, events: UploadEvents()).download(server.resultURL("old.mp4"), to: folder.appendingPathComponent("twice.mp4"),
                                                                       renew: renewals.renew)
    }
    check(failure?.kind == .refused(status: 410) && failure?.attempts == 2 && failure?.triedFreshAddress == true
            && failure?.message.contains("also at the fresh address") == true,
          "the fresh address refused too: refused after two GETs: \(String(describing: failure))")
    checkEqual(renewals.count, 1, "never a second fresh address")

    // A 404 whose body broke after its head: still the 404 (refused after one GET), never a broken try that a second GET would mask.
    server.configureDownload(gets: [.statusCut(404), .file], result: result)
    failure = await downloadFailure("a 404 whose body broke") {
        try await downloadAPI(server, events: UploadEvents()).download(server.resultURL("a.mp4"), to: folder.appendingPathComponent("broken404.mp4"))
    }
    check(failure?.kind == .refused(status: 404) && failure?.attempts == 1 && resultGets(server).count == 1,
          "a 404 whose body broke is the 404, after one GET: \(String(describing: failure))")

    // A 500 is an answer too: refused at once, and it is not an expired address, so nothing is renewed.
    server.configureDownload(gets: [.status(500), .file], result: result)
    renewals = Renewals(server.resultURL("fresh.mp4"))
    failure = await downloadFailure("a 500") {
        try await downloadAPI(server, events: UploadEvents()).download(server.resultURL("a.mp4"), to: folder.appendingPathComponent("five.mp4"),
                                                                       renew: renewals.renew)
    }
    check(failure?.kind == .refused(status: 500) && failure?.attempts == 1 && renewals.count == 0,
          "a 500: refused after one GET, nothing renewed: \(String(describing: failure))")

    // A connection that does not work (TLS against this plain server): could not connect, never tried again.
    server.configureDownload(gets: [.file], result: result)
    events = UploadEvents()
    failure = await downloadFailure("a TLS failure") {
        try await downloadAPI(server, events: events).download(server.resultURL("a.mp4", tls: true), to: folder.appendingPathComponent("tls.mp4"))
    }
    check(failure?.kind == .unreachable && failure?.attempts == 1 && failure?.code == "download_network",
          "a TLS failure: could not connect after one GET: \(String(describing: failure))")
    checkEqual(events.pauses, [], "no pause after a connection that does not work")
}

private func runDownloadStopChecks(_ server: UploadServer, folder: URL, result: Data) async {
    // A cancel while the body is stalled: the download stops at once and leaves nothing.
    server.configureDownload(gets: [.stall], result: result)
    let stalled = folder.appendingPathComponent("stalled.mp4")
    let api = downloadAPI(server, events: UploadEvents())
    let url = server.resultURL("a.mp4")
    let running = Task { try await api.download(url, to: stalled) }
    let seen = Date().addingTimeInterval(5)
    while resultGets(server).isEmpty, Date() < seen { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    let cancelled = Date()
    running.cancel()
    let outcome = await running.result
    let took = Date().timeIntervalSince(cancelled)
    if case .failure(let error) = outcome {
        check(error is CancellationError, "a cancel mid-download is a cancel, got \(error)")
    } else {
        check(false, "a cancel mid-download ends it")
    }
    check(took < 2, "a cancel stops the download promptly (\(String(format: "%.2f", took)) s)")
    check(!FileManager.default.fileExists(atPath: stalled.path) && leftovers(folder).isEmpty, "a cancelled download leaves nothing")
    checkEqual(resultGets(server).count, 1, "a cancel is never tried again")

    // A cancel during the pause before the second try: no second GET.
    server.configureDownload(gets: [.cut(300_000)], result: result)
    let pausing = downloadAPI(server, events: UploadEvents(), sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 5_000_000_000)) })
    let waiting = Task { try await pausing.download(url, to: folder.appendingPathComponent("paused.mp4")) }
    let first = Date().addingTimeInterval(5)
    while resultGets(server).isEmpty, Date() < first { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 600_000_000)
    let stopped = Date()
    waiting.cancel()
    let paused = await waiting.result
    if case .failure(let error) = paused {
        check(error is CancellationError, "a cancel during the pause is a cancel, got \(error)")
    } else {
        check(false, "a cancel during the pause ends it")
    }
    check(Date().timeIntervalSince(stopped) < 2, "a cancel during the pause stops promptly")
    checkEqual(resultGets(server).count, 1, "no second GET after a cancel during the pause")
}

private func runDownloadFailureWordsChecks() {
    let interrupted = SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "NSURLErrorDomain -1005")
    check(interrupted.message.contains("interrupted by the network after 3 tries") && interrupted.message.contains("nothing more was charged"),
          "the AI is told what happened in plain words: \(interrupted.message)")
    check(SkyStudioDownloadFailure(kind: .interrupted, attempts: 1, lastError: "x").message.contains("on its only try"),
          "one GET is not called three tries")
    let unreachable = SkyStudioDownloadFailure(kind: .unreachable, attempts: 1, lastError: "NSURLErrorDomain -1200")
    check(unreachable.message.contains("could not connect (NSURLErrorDomain -1200)") && unreachable.code == "download_network",
          "a connection that does not work: plain words, download_network")
    let refused = SkyStudioDownloadFailure(kind: .refused(status: 403), attempts: 2, lastError: "HTTP 403", triedFreshAddress: true)
    check(refused.message.contains("refused the download (HTTP 403), also at the fresh address") && refused.code == "download_refused",
          "a refusal after a fresh address: plain words, download_refused")
    checkEqual(refused.localizedDescription, refused.message, "a caught error reads as the message")
    let stopped = SkyStudioDownloadFailure.stopped
    check(stopped.code == "download_stopped" && stopped.message.contains("was stopped"), "a stopped download: its own code and words")
    for failure in [interrupted, unreachable, refused, stopped] {
        // Billing is not asserted (it may be pending): the words say it was made and that nothing more was charged.
        check(!failure.message.contains("charged for it"), "\(failure.kind): the message never asserts the charge: \(failure.message)")
        check(failure.fields() == ["code": .string(failure.code), "download_attempts": .number(Double(failure.attempts)),
                                   "download_error": .string(failure.lastError)],
              "\(failure.kind): without a retry, only the code, the GET count and the last error (a flow keeps its own next step)")
        let next = failure.fields(retry: "call generate_media again with the same idempotency_key.")["next_step"]?.stringValue ?? ""
        check(next.hasPrefix("Sky Studio made this result; only its download to this Mac did not finish, and nothing more was charged for it.")
              && next.hasSuffix("call generate_media again with the same idempotency_key."),
              "\(failure.kind): the next step says it was made, nothing more charged, and how to download it again: \(next)")
        check(!(failure.message + next).lowercased().contains("proxy"), "\(failure.kind): the words name the network, never a proxy")
    }
    checkEqual(SkyStudioDownloadFailure.from(refused), refused, "read back from the error")
    checkEqual(SkyStudioDownloadFailure.from(SkyStudioFailure.network("lost")), nil, "another failure is not a download failure")
    let standard = SkyStudioDownloadRetry.standard
    check(standard.attempts == 3 && standard.pauses == [1, 2], "three GETs in all, a short pause before each new one")
    checkEqual(SkyStudioDownloadRetry.renewableStatuses, [403, 404, 410], "only an expired or withdrawn address is renewed")
    runWholenessChecks()
}

/// The pure rule that a result is whole before it is moved into place (the review of PR #554: a resumed 206 `bytes
/// 100000-249999/1000000` once became a 250,000-byte result).
private func runWholenessChecks() {
    let short = SkyStudioDownloadRetry.incompleteness(status: 206, contentRange: "bytes 100000-249999/1000000", expectedLength: 150_000, size: 250_000)
    check(short != nil, "a resumed answer short of the last byte is not the result")
    check(SkyStudioDownloadRetry.incompleteness(status: 206, contentRange: "bytes 100000-999999/1000000", expectedLength: 900_000, size: 1_000_000) == nil,
          "a resumed answer to the last byte, with the whole length on disk, is the result")
    check(SkyStudioDownloadRetry.incompleteness(status: 206, contentRange: "bytes 100000-999999/1000000", expectedLength: 900_000, size: 900_000) != nil,
          "the length on disk must be the whole result's")
    check(SkyStudioDownloadRetry.incompleteness(status: 206, contentRange: "bytes 0-99/*", expectedLength: 100, size: 100) != nil,
          "a resumed answer whose total is unknown cannot be checked: it is not taken")
    check(SkyStudioDownloadRetry.incompleteness(status: 206, contentRange: nil, expectedLength: 100, size: 100) != nil,
          "a resumed answer without a Content-Range is not taken")
    check(SkyStudioDownloadRetry.incompleteness(status: 200, contentRange: nil, expectedLength: 1_000, size: 999) != nil,
          "a whole answer must hold its declared length")
    check(SkyStudioDownloadRetry.incompleteness(status: 200, contentRange: nil, expectedLength: -1, size: 999) == nil,
          "a whole answer without a length is taken as it is")
    check(SkyStudioDownloadRetry.incompleteness(status: 200, contentRange: nil, expectedLength: 400, size: 999, encoded: true) == nil,
          "an encoded answer's decoded bytes are not compared with its length")
    check(SkyStudioDownloadRetry.parseContentRange("bytes 5-9/10").map { [$0.first, $0.last, $0.total ?? -1] } == [5, 9, 10]
            && SkyStudioDownloadRetry.parseContentRange("bytes 9-5/10") == nil && SkyStudioDownloadRetry.parseContentRange("items 0-1/2") == nil,
          "Content-Range is read strictly")
    let base = URL(string: "https://cdn.example/files/a.mp4")!
    checkEqual(SkyStudioDownloadRetry.redirectTarget(status: 302, location: "/files/b.mp4", from: base)?.absoluteString,
               "https://cdn.example/files/b.mp4", "a relative Location resolves against the address it came from")
    check(SkyStudioDownloadRetry.redirectTarget(status: 302, location: "ftp://x/y", from: base) == nil
            && SkyStudioDownloadRetry.redirectTarget(status: 200, location: "/b", from: base) == nil,
          "only an http(s) Location of a 3xx is followed")
}

/// What the network and the server can do to a resumed or redirected GET, against the local server.
func runDownloadEdgeChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    // A resumed GET answered with a 206 that stops short of the end: thrown away, and the next GET fetches the whole result.
    server.configureDownload(gets: [.cut(400_000), .shortRange(150_000), .file], result: result)
    var events = UploadEvents()
    let whole = folder.appendingPathComponent("whole.mp4")
    do {
        let sink = events
        try await api(sink, 600).download(server.resultURL("a.mp4"), to: whole, onProgress: { sink.add(.progress($0)) })
    } catch {
        check(false, "a short 206: the next GET fetches the whole result, got \(error)")
    }
    checkEqual(try? Data(contentsOf: whole), result, "a short 206 never stands as the result: the file is byte-identical")
    var gets = server.log.filter { $0.method == "GET" }
    check(gets.count == 3 && gets[1].headers["range"] != nil && gets[2].headers["range"] == nil,
          "cut, resumed (short), then the whole result from the start: \(gets.map { $0.headers["range"] ?? "-" })")
    let shortEvents = events.all
    let lastPause = shortEvents.lastIndex { if case .pause = $0 { return true } else { return false } } ?? 0
    check(lastPause > 0 && shortEvents[lastPause - 1] == .progress(0)
            && !shortEvents[..<lastPause].contains(.progress(1)),
          "the short answer never reads 100%, and progress goes back to 0 before the GET that starts again: \(shortEvents)")

    // An error answer whose status the system held back while its body stalled: the job's current address is asked for, and used.
    server.configureDownload(gets: [.statusStall(403), .file], result: result)
    var renewals = Renewals(server.resultURL("fresh.mp4"))
    events = UploadEvents()
    let stalled = folder.appendingPathComponent("stalled403.mp4")
    do {
        try await api(events, 1.5).download(server.resultURL("old.mp4"), to: stalled, renew: renewals.renew)
    } catch {
        check(false, "a stalled 403 then the job's fresh address: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: stalled), result, "the fresh address gives the byte-identical file")
    gets = server.log.filter { $0.method == "GET" }
    check(renewals.count == 1 && gets.map(\.path) == ["/files/old.mp4", "/files/fresh.mp4"] && events.pauses.isEmpty,
          "a stalled answer goes to the fresh-address path, never the old address again: \(gets.map(\.path)), renewed \(renewals.count)")

    // The same, but the job gives the same address: the same address is tried again after the pause (it may have been a slow 200).
    server.configureDownload(gets: [.statusStall(403), .file], result: result)
    let old = server.resultURL("old.mp4")
    renewals = Renewals(old)
    events = UploadEvents()
    let same = folder.appendingPathComponent("stalledSame.mp4")
    do {
        try await api(events, 1.5).download(old, to: same, renew: renewals.renew)
    } catch {
        check(false, "a stalled answer with the same address: tried again, got \(error)")
    }
    checkEqual(try? Data(contentsOf: same), result, "tried again at the same address: byte-identical")
    check(renewals.count == 1 && server.log.filter { $0.method == "GET" }.count == 2 && events.pauses == [1],
          "asked once, then the same address after a pause: \(renewals.count), \(events.pauses)")

    // A redirect is a GET of its own: followed by the next GET, three in all however the server redirects.
    server.configureDownload(gets: [.redirect("a.mp4"), .cut(300_000), .file], result: result)
    let redirected = folder.appendingPathComponent("redirected.mp4")
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("r.mp4"), to: redirected)
    } catch {
        check(false, "a redirect, a cut, then the rest: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: redirected), result, "after a redirect and a cut the file is byte-identical")
    gets = server.log.filter { $0.method == "GET" }
    check(gets.map(\.path) == ["/files/r.mp4", "/files/a.mp4", "/files/a.mp4"] && gets[2].headers["range"] != nil,
          "the redirect, the target, then the target resumed (never the redirect again): \(gets.map(\.path))")
    server.configureDownload(gets: [.redirect("a.mp4"), .cut(300_000)], result: result)
    let failure = await downloadFailureOf {
        try await api(UploadEvents(), 600).download(server.resultURL("r.mp4"), to: folder.appendingPathComponent("redirect-drops.mp4"))
    }
    check(failure?.kind == .interrupted && failure?.attempts == 3 && server.log.filter { $0.method == "GET" }.count == 3,
          "a redirect then drops: three GETs in all, never six: \(String(describing: failure)), \(server.log.filter { $0.method == "GET" }.count)")
}

/// The download failure a body ended with, or nil (anything else is recorded).
func downloadFailureOf(_ body: () async throws -> Void) async -> SkyStudioDownloadFailure? {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL a download expected to fail did not")
    } catch let failure as SkyStudioDownloadFailure {
        return failure
    } catch {
        failures += 1
        print("FAIL expected a SkyStudioDownloadFailure, got \(error)")
    }
    return nil
}
