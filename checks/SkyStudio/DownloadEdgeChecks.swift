import Foundation

// Downloads of paid results against what a server and the network can answer (2026-11-24 / 25, the reviews of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), run by DownloadRetryChecks against the local server (UploadServer):
// - a resumed GET answered with a 206 that stops short: thrown away, never 100% before, the next GET fetches the whole result;
// - a gzip 206 for the second half (`bytes 29-57/58`, 1,000 bytes decoded): never the result, and a file already at the destination
//   stays as it was; followed by the whole answer it is the whole result;
// - a gzip 206 `bytes 29-52/53` decoding to exactly 53 bytes (CXD3: it once overwrote a whole 2,000-byte file on the first GET): never
//   the result, every GET after it starts without a Range; a whole gzip 200 (its length cannot be checked) never replaces a file already
//   there, and is taken where nothing is in the way; a gzip 200 the network broke starts again without a Range;
// - an empty 200: never the result; three of them end `download_incomplete` (a download failure the flows hold for Download again);
// - an answer whose status the system held back (a stalled 403 or 500): at most one GET at the job's current address, never the same
//   address again;
// - a redirect is a GET of its own (three in all);
// - a stop counts the GETs it really sent.

func runDownloadEdgeChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    await runShortAnswerChecks(server, folder: folder, result: result, api: api)
    await runHeldBackChecks(server, folder: folder, result: result, api: api)
    await runRedirectChecks(server, folder: folder, result: result, api: api)
    await runStopCountChecks(server, folder: folder, result: result, api: api)
}

private func runShortAnswerChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    await runEncodedAnswerChecks(server, folder: folder, result: result, api: api)
    // A resumed GET answered with a 206 that stops short of the end: thrown away, and the next GET fetches the whole result.
    server.configureDownload(gets: [.cut(400_000), .shortRange(150_000), .file], result: result)
    let events = UploadEvents()
    let whole = folder.appendingPathComponent("whole.mp4")
    do {
        try await api(events, 600).download(server.resultURL("a.mp4"), to: whole, onProgress: { events.add(.progress($0)) })
    } catch {
        check(false, "a short 206: the next GET fetches the whole result, got \(error)")
    }
    checkEqual(try? Data(contentsOf: whole), result, "a short 206 never stands as the result: the file is byte-identical")
    let gets = resultGets(server)
    check(gets.count == 3 && gets[1].headers["range"] != nil && gets[2].headers["range"] == nil,
          "cut, resumed (short), then the whole result from the start: \(gets.map { $0.headers["range"] ?? "-" })")
    let shortEvents = events.all
    let lastPause = shortEvents.lastIndex { if case .pause = $0 { return true } else { return false } } ?? 0
    check(lastPause > 0 && shortEvents[lastPause - 1] == .progress(0) && !shortEvents[..<lastPause].contains(.progress(1)),
          "the short answer never reads 100%, and progress goes back to 0 before the GET that starts again: \(shortEvents)")

    // A gzip 206 for the second half, whatever was asked: never the result, and the file already at the destination stays whole.
    let kept = folder.appendingPathComponent("kept.mp4")
    let earlier = Data((0..<2_000).map { UInt8($0 % 241) })
    try? earlier.write(to: kept)
    server.configureDownload(gets: [.gzipRange(decoded: 1_000, range: "bytes 29-57/58")], result: result)
    var failure = await downloadFailureOf {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: kept)
    }
    check(failure?.kind == .incomplete && failure?.attempts == 3 && failure?.code == "download_incomplete",
          "three gzip 206s: never the result, download_incomplete after three GETs: \(String(describing: failure))")
    check((try? Data(contentsOf: kept)) == earlier && leftovers(folder).isEmpty,
          "the 2,000-byte file at the destination is untouched (it was once overwritten with the 1,000 decoded bytes)")
    server.configureDownload(gets: [.gzipRange(decoded: 1_000, range: "bytes 29-57/58"), .file], result: result)
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: kept)
    } catch {
        check(false, "a gzip 206 then the whole answer: the download works, got \(error)")
    }
    check((try? Data(contentsOf: kept)) == result && resultGets(server).count == 2,
          "a gzip 206 then the whole answer: the whole result after two GETs")

    // An empty 200 is never a result: three of them are a download failure (which the flows hold for Download again).
    server.configureDownload(gets: [.empty], result: result)
    let empty = folder.appendingPathComponent("empty.mp4")
    failure = await downloadFailureOf {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: empty)
    }
    check(failure?.kind == .incomplete && failure?.attempts == 3 && failure?.lastError.contains("an empty answer") == true
            && !FileManager.default.fileExists(atPath: empty.path),
          "three empty 200s: download_incomplete after three GETs, no file: \(String(describing: failure))")
    server.configureDownload(gets: [.empty, .file], result: result)
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: empty)
    } catch {
        check(false, "an empty 200 then the whole answer: the download works, got \(error)")
    }
    check((try? Data(contentsOf: empty)) == result && resultGets(server).count == 2, "an empty 200 then the whole result after two GETs")
}

/// Answers the system decoded (Content-Encoding gzip although identity was asked for): their length can never be checked.
private func runEncodedAnswerChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    let earlier = Data((0..<2_000).map { UInt8($0 % 239) })
    let kept = folder.appendingPathComponent("kept-encoded.mp4")
    try? earlier.write(to: kept)

    // A gzip 206 whose decoded body is exactly its Content-Range total: never the result, and never resumed.
    server.configureDownload(gets: [.gzipRange(decoded: 53, range: "bytes 29-52/53")], result: result)
    var failure = await downloadFailureOf { try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: kept) }
    check(failure?.kind == .incomplete && failure?.attempts == 3 && (try? Data(contentsOf: kept)) == earlier && leftovers(folder).isEmpty,
          "three gzip 206s decoding to their whole total: download_incomplete, the 2,000-byte file untouched: \(String(describing: failure))")
    check(resultGets(server).allSatisfy { $0.headers["range"] == nil }, "every GET after an encoded answer starts without a Range")

    // A whole gzip 200: taken nowhere a file already is (three of them end download_incomplete), taken where nothing is in the way.
    server.configureDownload(gets: [.gzipWhole], result: result)
    failure = await downloadFailureOf { try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: kept) }
    check(failure?.kind == .incomplete && failure?.attempts == 3 && (try? Data(contentsOf: kept)) == earlier && leftovers(folder).isEmpty,
          "a gzip 200 never replaces the file already at the destination: \(String(describing: failure))")
    server.configureDownload(gets: [.gzipWhole, .file], result: result)
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: kept)
    } catch {
        check(false, "a gzip 200 then the whole answer: the checked result replaces the file, got \(error)")
    }
    check((try? Data(contentsOf: kept)) == result && resultGets(server).count == 2, "a gzip 200, then the whole result checked against its length")
    let fresh = folder.appendingPathComponent("fresh-encoded.mp4")
    server.configureDownload(gets: [.gzipWhole], result: result)
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: fresh)
    } catch {
        check(false, "a gzip 200 where nothing is in the way: taken, got \(error)")
    }
    check((try? Data(contentsOf: fresh)) == result && resultGets(server).count == 1, "a gzip 200 where nothing is in the way is taken")

    // A gzip 200 the network broke: the next GET starts again from nothing, without a Range.
    server.configureDownload(gets: [.gzipCut, .file], result: result)
    let broken = folder.appendingPathComponent("broken-encoded.mp4")
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("a.mp4"), to: broken)
    } catch {
        check(false, "a gzip 200 cut, then the whole answer: the download works, got \(error)")
    }
    let gets = resultGets(server)
    check((try? Data(contentsOf: broken)) == result && gets.count == 2 && gets[1].headers["range"] == nil,
          "a broken gzip 200 is never resumed: \(gets.map { $0.headers["range"] ?? "-" })")
}

private func runHeldBackChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    // An error answer whose status the system held back while its body stalled: the job's current address is asked for, and used.
    server.configureDownload(gets: [.statusStall(403), .file], result: result)
    var renewals = Renewals(server.resultURL("fresh.mp4"))
    var events = UploadEvents()
    let stalled = folder.appendingPathComponent("stalled403.mp4")
    do {
        try await api(events, 1.5).download(server.resultURL("old.mp4"), to: stalled, renew: renewals.renew)
    } catch {
        check(false, "a stalled 403 then the job's fresh address: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: stalled), result, "the fresh address gives the byte-identical file")
    check(renewals.count == 1 && resultGets(server).map(\.path) == ["/files/old.mp4", "/files/fresh.mp4"] && events.pauses.isEmpty,
          "a stalled answer goes to the fresh-address path, never the old address again: \(resultGets(server).map(\.path))")

    // A 500 whose body stalls, and the job gives the same address: an answer, so that address is never fetched again.
    server.configureDownload(gets: [.statusStall(500), .file], result: result)
    let old = server.resultURL("old.mp4")
    renewals = Renewals(old)
    events = UploadEvents()
    var failure = await downloadFailureOf {
        try await api(events, 1.5).download(old, to: folder.appendingPathComponent("stalled500.mp4"), renew: renewals.renew)
    }
    check(failure?.kind == .interrupted && failure?.attempts == 1 && renewals.count == 1 && resultGets(server).count == 1 && events.pauses.isEmpty,
          "a stalled 500 with the same address from the job: one GET, never three to the same address: \(String(describing: failure)), "
            + "\(resultGets(server).count) GETs")

    // No way to ask the job: the one GET, then held.
    server.configureDownload(gets: [.statusStall(500), .file], result: result)
    failure = await downloadFailureOf {
        try await api(UploadEvents(), 1.5).download(old, to: folder.appendingPathComponent("stalled500b.mp4"))
    }
    check(failure?.kind == .interrupted && failure?.attempts == 1 && resultGets(server).count == 1,
          "a stalled 500 with no fresh address to ask for: one GET: \(String(describing: failure))")

    // Stalled at the old address and at the fresh one: two GETs, never a third.
    server.configureDownload(gets: [.statusStall(500)], result: result)
    renewals = Renewals(server.resultURL("fresh.mp4"))
    failure = await downloadFailureOf {
        try await api(UploadEvents(), 1.5).download(old, to: folder.appendingPathComponent("stalled500c.mp4"), renew: renewals.renew)
    }
    check(failure?.attempts == 2 && renewals.count == 1 && resultGets(server).map(\.path) == ["/files/old.mp4", "/files/fresh.mp4"],
          "stalled at both addresses: the old one, the fresh one, nothing more: \(resultGets(server).map(\.path))")
}

private func runRedirectChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    // A redirect is a GET of its own: followed by the next GET, three in all however the server redirects.
    server.configureDownload(gets: [.redirect("a.mp4"), .cut(300_000), .file], result: result)
    let redirected = folder.appendingPathComponent("redirected.mp4")
    do {
        try await api(UploadEvents(), 600).download(server.resultURL("r.mp4"), to: redirected)
    } catch {
        check(false, "a redirect, a cut, then the rest: the download works, got \(error)")
    }
    checkEqual(try? Data(contentsOf: redirected), result, "after a redirect and a cut the file is byte-identical")
    let gets = resultGets(server)
    check(gets.map(\.path) == ["/files/r.mp4", "/files/a.mp4", "/files/a.mp4"] && gets[2].headers["range"] != nil,
          "the redirect, the target, then the target resumed (never the redirect again): \(gets.map(\.path))")
    server.configureDownload(gets: [.redirect("a.mp4"), .cut(300_000)], result: result)
    let failure = await downloadFailureOf {
        try await api(UploadEvents(), 600).download(server.resultURL("r.mp4"), to: folder.appendingPathComponent("redirect-drops.mp4"))
    }
    check(failure?.kind == .interrupted && failure?.attempts == 3 && resultGets(server).count == 3,
          "a redirect then drops: three GETs in all, never six: \(String(describing: failure)), \(resultGets(server).count)")
}

private func runStopCountChecks(_ server: UploadServer, folder: URL, result: Data, api: (UploadEvents, TimeInterval) -> SkyStudioAPI) async {
    // Cut, then the resumed GET stalls and is stopped: the stop says two GETs were sent (it once always said 0).
    server.configureDownload(gets: [.cut(300_000), .stall], result: result)
    let downloader = api(UploadEvents(), 600)
    let url = server.resultURL("a.mp4")
    let running = Task { try await downloader.download(url, to: folder.appendingPathComponent("second.mp4")) }
    let deadline = Date().addingTimeInterval(5)
    while resultGets(server).count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    running.cancel()
    if case .failure(let error) = await running.result {
        let stop = error as? SkyStudioDownloadFailure
        check(stop?.kind == .stopped && stop?.attempts == 2, "a stop during the second GET says two GETs were sent, got \(error)")
    } else {
        check(false, "a stop during the second GET ends it")
    }
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
