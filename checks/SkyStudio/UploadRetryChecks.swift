import Foundation
import SrtFlowMCPKit

// Uploads the network interrupts (2026-11-23, generate-34 / generate-35; docs/bugfixes/2026-11-23-upload-lost-connection-no-retry.md):
// SkyStudioAPI.upload tries a PUT the network broke again on a fresh task, three tries in all, at the same signed address while it
// stays valid (a new ticket when it would run out), with progress starting again from 0; a storage answer (403) and a cancel are
// never tried again; after the last try the error is `SkyStudioFailure.uploadInterrupted` with the code `upload_network`, the count
// and plain words. Run against a real local server (UploadServer) that reads the whole body and then drops the connection, with no
// proxy: the system's own transfer code is what is tested. Plus the pure rules: which errors are retried, when an address must be
// renewed, the words for the AI.

func runUploadRetryChecks() async {
    runTransientErrorChecks()
    runUploadTicketChecks()
    runInterruptionWordsChecks()
    let server: UploadServer
    do { server = try UploadServer() } catch {
        check(false, "the local upload server starts: \(error)")
        return
    }
    defer { server.stop() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skystudio-upload-retry-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("reference.png")
    let bytes = Data((0..<200_000).map { UInt8($0 % 241) })
    try? bytes.write(to: file)
    await runDropChecks(server, file: file, size: bytes.count)
    await runNotRetriedChecks(server, file: file)
    await runAddressChecks(server, file: file)
}

/// Progress reports and the waits between tries, in the order they happened (waits are recorded, not slept).
final class UploadEvents: @unchecked Sendable {
    enum Event: Equatable { case progress(Double), pause(Double) }
    private let lock = NSLock()
    private var items: [Event] = []
    func add(_ event: Event) { lock.lock(); items.append(event); lock.unlock() }
    var all: [Event] { lock.lock(); defer { lock.unlock() }; return items }
    var pauses: [Double] { all.compactMap { if case .pause(let seconds) = $0 { return seconds } else { return nil } } }
    /// Each wait comes right after a report of 0 (the broken try's bytes are lost), and the last report is 1.
    var restartsBeforeEachPause: Bool {
        let events = all
        let resets = events.indices.filter { if case .pause = events[$0] { return true } else { return false } }
            .allSatisfy { $0 > 0 && events[$0 - 1] == .progress(0) }
        return resets && events.last(where: { if case .progress = $0 { return true } else { return false } }) == .progress(1)
    }
}

private func uploadAPI(_ server: UploadServer, events: UploadEvents) -> SkyStudioAPI {
    var retry = SkyStudioUploadRetry()
    retry.sleep = { seconds in events.add(.pause(seconds)) }
    return SkyStudioAPI(session: uploadSession, base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!, version: "0.18.50",
                        machine: String(repeating: "a", count: 64), uploadRetry: retry)
}

/// No proxy at all: the system's proxy settings are never read or used by these checks.
private let uploadSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}()

private func paths(_ server: UploadServer) -> [String] {
    server.log.map { "\($0.method) " + ($0.path.hasSuffix("/uploads") ? "/uploads" : String($0.path.prefix { $0 != "?" })) }
}

private func runTransientErrorChecks() {
    for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet] {
        check(SkyStudioUploadRetry.isTransient(URLError(code)), "a PUT that ended with URLError \(code.rawValue) is tried again")
    }
    for code in [URLError.Code.cancelled, .badServerResponse, .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed,
                 .serverCertificateUntrusted, .fileDoesNotExist, .noPermissionsToReadFile, .badURL, .userAuthenticationRequired] {
        check(!SkyStudioUploadRetry.isTransient(URLError(code)), "URLError \(code.rawValue) is never tried again")
    }
    check(SkyStudioUploadRetry.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))), "a connection reset is tried again")
    check(SkyStudioUploadRetry.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))), "a broken pipe is tried again")
    check(!SkyStudioUploadRetry.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), "a permission error is not")
    check(!SkyStudioUploadRetry.isTransient(CancellationError()), "a cancel is never tried again")
    check(!SkyStudioUploadRetry.isTransient(SkyStudioFailure.badAnswer(status: 503)), "a storage answer is never tried again")
    checkEqual(SkyStudioUploadRetry.describe(URLError(.networkConnectionLost)), "NSURLErrorDomain -1005", "the last error, in any language")
    let standard = SkyStudioUploadRetry.standard
    checkEqual(standard.attempts, 3, "three tries in all")
    checkEqual(standard.pauses, [1, 2], "a short pause before each new try")
}

private func runUploadTicketChecks() {
    let answer: JSONValue = ["upload_url": "https://r2.example/put/1?X-Amz-Signature=a", "method": "PUT",
                             "headers": ["Content-Type": "image/png", "Cache-Control": "public, max-age=3600", "x-number": 7],
                             "file_url": "https://r2.example/originals/u/skycut/1.png", "expires_at": "2026-11-23T07:15:00.000Z"]
    let received = Date(timeIntervalSince1970: 1_795_500_000)
    // Sky Studio's clock says 07:00:00 when this Mac's says `received`: the address lives 15 minutes from `received`.
    guard let ticket = SkyStudioUploadTicket(answer, received: received, serverDate: "Mon, 23 Nov 2026 07:00:00 GMT") else {
        check(false, "the /uploads answer reads")
        return
    }
    checkEqual(ticket.deadline, received.addingTimeInterval(900), "expires_at moves onto this Mac's clock with the answer's Date")
    checkEqual(ticket.request.value(forHTTPHeaderField: "Cache-Control"), "public, max-age=3600", "every header the server gave goes along")
    check(ticket.request.value(forHTTPHeaderField: "x-number") == nil, "a header that is not text is left out, as before")
    check(ticket.request.value(forHTTPHeaderField: "Authorization") == nil, "the key never goes to the storage address")
    checkEqual(ticket.request.timeoutInterval, 600, "the PUT's timeout is unchanged")
    check(!ticket.needsRenewal(now: received.addingTimeInterval(60), lastTry: 30, margin: 60), "14 minutes left: the address is reused")
    check(!ticket.needsRenewal(now: received.addingTimeInterval(800), lastTry: 30, margin: 60), "100 s left after a 30 s try: reused")
    check(ticket.needsRenewal(now: received.addingTimeInterval(820), lastTry: 30, margin: 60), "80 s left after a 30 s try: renewed")
    check(ticket.needsRenewal(now: received.addingTimeInterval(300), lastTry: 600, margin: 60), "a 10-minute try with 10 minutes left: renewed")
    let local = SkyStudioUploadTicket.deadline(expiresAt: "2026-11-23T07:15:00Z", received: received, serverDate: nil)
    checkEqual(local, SkyStudioJSON.parseDate("2026-11-23T07:15:00Z"), "without Date, expires_at is taken as it is")
    let garbled = SkyStudioUploadTicket.deadline(expiresAt: "2026-11-23T07:15:00Z", received: received, serverDate: "yesterday")
    checkEqual(garbled, SkyStudioJSON.parseDate("2026-11-23T07:15:00Z"), "an unreadable Date is ignored")
    var open = answer
    if case .object(var fields) = open { fields["expires_at"] = nil; open = .object(fields) }
    let forever = SkyStudioUploadTicket(open, received: received, serverDate: nil)
    check(forever?.deadline == nil && forever?.needsRenewal(now: received.addingTimeInterval(86_400), lastTry: 600, margin: 60) == false,
          "an answer without expires_at keeps its address for every try")
    check(SkyStudioUploadTicket(["method": "PUT"], received: received, serverDate: nil) == nil, "no addresses, no ticket")
}

private func runInterruptionWordsChecks() {
    let interruption = SkyStudioUploadInterruption(fileName: "cabin.png", attempts: 3, lastError: "NSURLErrorDomain -1005")
    checkEqual(interruption.message, "The upload of cabin.png to Sky Studio was interrupted by the network after 3 tries; nothing was "
        + "submitted and nothing was charged.", "the AI is told what happened in plain words")
    check(!interruption.message.lowercased().contains("proxy"), "the words name the network, never a proxy")
    let fields = interruption.fields(retry: "call generate_media again.")
    checkEqual(fields["code"], "upload_network", "the stable code")
    checkEqual(fields["upload_attempts"], 3, "the count")
    checkEqual(fields["charged"], false, "nothing was charged")
    checkEqual(fields["upload_error"], "NSURLErrorDomain -1005", "the last error")
    let next = fields["next_step"]?.stringValue ?? ""
    check(next.hasPrefix("Nothing was submitted to Sky Studio and nothing was charged.") && next.hasSuffix("call generate_media again.")
          && !next.contains("original job"), "the next step never sends the AI to query a job that was never submitted: \(next)")
    checkEqual(SkyStudioUploadInterruption.from(SkyStudioFailure.uploadInterrupted(interruption)), interruption, "read back from the error")
    checkEqual(SkyStudioUploadInterruption.from(SkyStudioFailure.network("lost")), nil, "another failure is not an interruption")
    checkEqual(SkyStudioJobError.request(.uploadInterrupted(interruption)).message, interruption.message, "a job's message is the same")
}

/// The server reads the whole body, then drops the connection N times: the upload works on try N + 1, at the same address.
private func runDropChecks(_ server: UploadServer, file: URL, size: Int) async {
    for (drops, reply) in [(1, UploadServer.PutReply.drop), (2, .drop), (1, .reset)] {
        server.configure(puts: Array(repeating: reply, count: drops) + [.ok])
        let events = UploadEvents()
        let link: URL?
        do {
            link = try await uploadAPI(server, events: events).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey) {
                events.add(.progress($0))
            }
        } catch {
            check(false, "\(drops) dropped PUT(s) (\(reply)) then an answer: the upload works, got \(error)")
            continue
        }
        checkEqual(link?.absoluteString, server.fileURL(1), "\(drops) drop(s) (\(reply)): the first ticket's file_url comes back")
        checkEqual(paths(server), ["POST /uploads"] + Array(repeating: "PUT /r2/originals/u/skycut/1.png", count: drops + 1),
                   "\(drops) drop(s) (\(reply)): the same signed address, tried \(drops + 1) times, no new ticket")
        check(server.log.dropFirst().allSatisfy { $0.bodyBytes == size }, "every try sends the whole file")
        check(server.log.dropFirst().allSatisfy { $0.headers["authorization"] == nil }, "no try carries the key")
        checkEqual(events.pauses, Array([1.0, 2.0].prefix(drops)), "\(drops) drop(s): a short pause before each new try")
        check(events.restartsBeforeEachPause, "progress goes back to 0 before each new try and ends at 1: \(events.all)")
    }

    server.configure(puts: [.drop])
    let events = UploadEvents()
    let failure = await expectFailure("three dropped PUTs") {
        _ = try await uploadAPI(server, events: events).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    }
    guard case .uploadInterrupted(let interruption)? = failure else {
        check(false, "three dropped PUTs end as uploadInterrupted, got \(String(describing: failure))")
        return
    }
    checkEqual(interruption.attempts, 3, "three tries")
    checkEqual(interruption.fileName, "reference.png", "the file is named")
    checkEqual(interruption.lastError, "NSURLErrorDomain -1005", "a dropped connection is URLError -1005")
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 3, "never a fourth try")
    checkEqual(events.pauses, [1, 2], "two pauses")
    checkEqual(interruption.fields(retry: "x")["code"], "upload_network", "the code for tool results and get_job")

    server.configure(puts: [.drop])
    let named = await expectFailure("a cut sent under a temporary name") {
        _ = try await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey,
                                                                        named: "beach.mp4")
    }
    if case .uploadInterrupted(let interruption)? = named {
        checkEqual(interruption.fileName, "beach.mp4", "the words name the file as the user knows it")
    } else {
        check(false, "a named upload ends as uploadInterrupted")
    }
}

/// A storage answer and a cancel are never tried again.
private func runNotRetriedChecks(_ server: UploadServer, file: URL) async {
    server.configure(puts: [.forbidden, .ok])
    let refusedEvents = UploadEvents()
    let refused = await expectFailure("a refused PUT") {
        _ = try await uploadAPI(server, events: refusedEvents).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    }
    if case .badAnswer(let status)? = refused {
        checkEqual(status, 403, "a refused PUT says its status")
    } else {
        check(false, "a refused PUT is a bad answer, got \(String(describing: refused))")
    }
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "a 403 is never tried again")
    checkEqual(refusedEvents.pauses, [], "no pause after a 403")

    server.configure(puts: [.hold, .ok])
    let held = UploadEvents()
    let api = uploadAPI(server, events: held)
    let upload = Task { try await api.upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey) }
    let deadline = Date().addingTimeInterval(10)
    while !server.log.contains(where: { $0.method == "PUT" }), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    upload.cancel()
    var cancelled = false
    do { _ = try await upload.value } catch is CancellationError { cancelled = true } catch {
        check(false, "a cancelled upload throws CancellationError, got \(error)")
    }
    check(cancelled, "a cancel during the PUT ends the upload")
    try? await Task.sleep(nanoseconds: 300_000_000)
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "a cancel is never tried again")
    checkEqual(held.pauses, [], "no pause after a cancel")

    // A stop during the pause before the next try ends it at once: one PUT, no second.
    server.configure(puts: [.drop, .ok])
    var retry = SkyStudioUploadRetry()
    retry.sleep = { _ in try await Task.sleep(nanoseconds: 30_000_000_000) }
    let waiting = SkyStudioAPI(session: uploadSession, base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!,
                               version: "0.18.50", machine: nil, uploadRetry: retry)
    let paused = Task { try await waiting.upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey) }
    let pauseDeadline = Date().addingTimeInterval(10)
    while !server.log.contains(where: { $0.method == "PUT" }), Date() < pauseDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    paused.cancel()
    var stopped = false
    do { _ = try await paused.value } catch is CancellationError { stopped = true } catch {
        check(false, "a stop during the pause throws CancellationError, got \(error)")
    }
    check(stopped, "a stop during the pause ends the upload")
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "no try after a stop during the pause")
}

/// An address about to run out is renewed before the next try; a Mac clock an hour off still reuses a fresh one.
private func runAddressChecks(_ server: UploadServer, file: URL) async {
    server.configure(puts: [.drop, .ok], ticketLife: 30)
    let renewed = try? await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    checkEqual(paths(server), ["POST /uploads", "PUT /r2/originals/u/skycut/1.png", "POST /uploads", "PUT /r2/originals/u/skycut/2.png"],
               "an address with 30 s left is renewed before the next try")
    checkEqual(renewed?.absoluteString, server.fileURL(2), "the file_url of the ticket whose PUT worked comes back")

    server.configure(puts: [.drop, .ok], clockOffset: -3_600)
    let skewed = try? await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    checkEqual(paths(server), ["POST /uploads", "PUT /r2/originals/u/skycut/1.png", "PUT /r2/originals/u/skycut/1.png"],
               "Sky Studio's clock an hour behind this Mac's: the fresh address is reused, not renewed")
    checkEqual(skewed?.absoluteString, server.fileURL(1), "and its file_url comes back")
}
