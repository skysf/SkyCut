import Foundation
import SrtFlowMCPKit

// Uploads to Sky Studio's storage (2026-11-23, generate-34 / generate-35; docs/bugfixes/2026-11-23-upload-lost-connection-no-retry.md):
// SkyStudioAPI.upload tries a PUT the network broke again on a fresh task, three tries in all, at the same signed address while it is
// known to stay valid, with progress starting again from 0. An answer the storage gave stands (a 403 even when its body then broke),
// and a connection that does not work and a cancel are never tried again. Giving up is `SkyStudioFailure.uploadFailed`
// (`upload_network` / `upload_refused`, the PUT count, plain words). Run against a real local server (UploadServer) with no proxy: the
// system's own transfer code is what is tested. The pure rules are here; the address and answer cases are in UploadAnswerChecks.

func runUploadRetryChecks() async {
    runTransientErrorChecks()
    runUploadTicketChecks()
    runUploadFailureWordsChecks()
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
    await runUploadAnswerChecks(server, file: file)
    await runUploadAddressChecks(server, file: file)
    await runDownloadRetryChecks(server)
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

/// `putTimeout`: how long a PUT may sit without a byte moving (short only where an answer that stalls is the case).
func uploadAPI(_ server: UploadServer, events: UploadEvents, putTimeout: TimeInterval = 600) -> SkyStudioAPI {
    var retry = SkyStudioUploadRetry()
    retry.sleep = { seconds in events.add(.pause(seconds)) }
    retry.putTimeout = putTimeout
    return SkyStudioAPI(session: uploadSession, base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!, version: "0.18.50",
                        machine: String(repeating: "a", count: 64), uploadRetry: retry)
}

/// No proxy at all: the system's proxy settings are never read or used by these checks.
let uploadSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}()

func uploadPaths(_ server: UploadServer) -> [String] {
    server.log.map { "\($0.method) " + ($0.path.hasSuffix("/uploads") ? "/uploads" : String($0.path.prefix { $0 != "?" })) }
}

/// The failure an upload ended with, or nil (a failure that is not an upload failure is recorded).
func uploadFailure(_ message: String, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async -> SkyStudioUploadFailure? {
    guard let failure = await expectFailure(message, file: file, line: line, body) else { return nil }
    guard let upload = SkyStudioUploadFailure.from(failure) else {
        check(false, "\(message): expected uploadFailed, got \(failure)", file: file, line: line)
        return nil
    }
    return upload
}

private func runTransientErrorChecks() {
    for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet] {
        check(SkyStudioUploadRetry.isTransient(URLError(code)), "a PUT that ended with URLError \(code.rawValue) is tried again")
        check(SkyStudioUploadRetry.classify(URLError(code)) is SkyStudioUploadRetry.Broken, "URLError \(code.rawValue) is a broken try")
    }
    for code in [URLError.Code.cancelled, .badServerResponse, .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed,
                 .serverCertificateUntrusted, .fileDoesNotExist, .noPermissionsToReadFile, .badURL, .userAuthenticationRequired] {
        check(!SkyStudioUploadRetry.isTransient(URLError(code)), "URLError \(code.rawValue) is never tried again")
    }
    for code in [URLError.Code.serverCertificateUntrusted, .secureConnectionFailed, .cannotFindHost, .cannotParseResponse] {
        check(SkyStudioUploadRetry.classify(URLError(code)) is SkyStudioUploadRetry.Unreachable,
              "URLError \(code.rawValue) (on a PUT or while renewing the address) ends the upload")
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
    for expires in [nil, "next week"] as [JSONValue?] {
        var unknown = answer
        if case .object(var fields) = unknown { fields["expires_at"] = expires; unknown = .object(fields) }
        let ticket = SkyStudioUploadTicket(unknown, received: received, serverDate: nil)
        check(ticket?.deadline == nil && ticket?.needsRenewal(now: received.addingTimeInterval(1), lastTry: 0, margin: 60) == true,
              "an address of unknown validity (expires_at \(expires?.stringValue ?? "missing")) is never reused")
    }
    check(SkyStudioUploadTicket(["method": "PUT"], received: received, serverDate: nil) == nil, "no addresses, no ticket")
}

private func runUploadFailureWordsChecks() {
    let interrupted = SkyStudioUploadFailure(fileName: "cabin.png", kind: .interrupted, attempts: 3, lastError: "NSURLErrorDomain -1005")
    checkEqual(interrupted.message, "The upload of cabin.png to Sky Studio was interrupted by the network after 3 tries; nothing was "
        + "submitted and nothing was charged.", "the AI is told what happened in plain words")
    check(SkyStudioUploadFailure(fileName: "a.png", kind: .interrupted, attempts: 1, lastError: "x").message.contains("on its only try"),
          "one PUT is not called three tries")
    let unreachable = SkyStudioUploadFailure(fileName: "a.png", kind: .unreachable, attempts: 1, lastError: "NSURLErrorDomain -1202")
    check(unreachable.message.contains("could not connect (NSURLErrorDomain -1202)") && unreachable.code == "upload_network",
          "a connection that does not work: plain words, upload_network")
    let refused = SkyStudioUploadFailure(fileName: "a.png", kind: .refused(status: 403), attempts: 1, lastError: "HTTP 403")
    check(refused.message.contains("refused the upload of a.png (HTTP 403)") && refused.code == "upload_refused",
          "a refusal: plain words, upload_refused")
    let unread = SkyStudioUploadFailure(fileName: "a.png", kind: .refused(status: 0), attempts: 1, lastError: "HTTP 0")
    check(unread.message.contains("did not come through") && unread.code == "upload_refused", "an answer whose status never came through")
    let declined = SkyStudioUploadFailure(fileName: "a.png", kind: .declined(status: 503), attempts: 0, lastError: "HTTP 503")
    check(declined.message.contains("did not accept the upload of a.png (HTTP 503)") && declined.code == "upload_declined",
          "a /uploads refusal: plain words, upload_declined")
    // Too large: a 413 from /uploads or the storage, or Sky Studio's reason upload_too_large. Only a smaller file helps.
    let tooLarge = SkyStudioUploadFailure(fileName: "a.png", kind: .declined(status: 413), attempts: 0, lastError: "HTTP 413")
    let tooLargeRefusal = SkyStudioUploadFailure(fileName: "a.png", kind: .declined(status: 400), attempts: 0, lastError: "invalid_request: Big.",
        server: SkyStudioServerError(status: 400, code: "invalid_request", message: "Big.", fields: ["reason": "upload_too_large"]))
    let storageTooLarge = SkyStudioUploadFailure(fileName: "a.png", kind: .refused(status: 413), attempts: 1, lastError: "HTTP 413")
    let otherRefusal = SkyStudioUploadFailure(fileName: "a.png", kind: .declined(status: 400), attempts: 0, lastError: "invalid_request: No.",
        server: SkyStudioServerError(status: 400, code: "invalid_request", message: "No.", fields: ["reason": "unsupported_type"]))
    for failure in [tooLarge, tooLargeRefusal, storageTooLarge] {
        check(failure.isTooLarge && failure.message.contains("because the file is too large (\(failure.lastError))"),
              "\(failure.kind): a file too large is said so: \(failure.message)")
        check(failure.fields(retry: "x")["next_step"]?.stringValue?.contains("too large for Sky Studio (\(failure.lastError)), so they need a "
              + "smaller file") == true, "\(failure.kind): the next step asks for a smaller file")
    }
    check(![interrupted, unreachable, refused, unread, declined, otherRefusal].contains { $0.isTooLarge },
          "nothing else is called too large (another invalid_request, a 503, a 403)")
    for failure in [interrupted, unreachable, refused, unread, declined, tooLarge, tooLargeRefusal, storageTooLarge, otherRefusal] {
        let fields = failure.fields(retry: "call generate_media again.")
        let next = fields["next_step"]?.stringValue ?? ""
        check(fields["code"]?.stringValue == failure.code && fields["upload_attempts"] == .number(Double(failure.attempts))
              && fields["charged"] == false && fields["upload_error"]?.stringValue == failure.lastError,
              "\(failure.kind): the code, the PUT count, nothing charged, the last error")
        check(next.hasPrefix("Nothing was submitted to Sky Studio and nothing was charged.") && next.hasSuffix("call generate_media again.")
              && !next.contains("original job"), "\(failure.kind): the next step never points at a job that was never submitted: \(next)")
        check(!(failure.message + next).lowercased().contains("proxy"), "\(failure.kind): the words name the network, never a proxy")
    }
    checkEqual(SkyStudioUploadFailure.from(SkyStudioFailure.uploadFailed(refused)), refused, "read back from the error")
    checkEqual(SkyStudioUploadFailure.from(SkyStudioFailure.network("lost")), nil, "another failure is not an upload failure")
    checkEqual(SkyStudioJobError.request(.uploadFailed(refused)).message, refused.message, "a job's message is the same")
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
        checkEqual(uploadPaths(server), ["POST /uploads"] + Array(repeating: "PUT /r2/originals/u/skycut/1.png", count: drops + 1),
                   "\(drops) drop(s) (\(reply)): the same signed address, tried \(drops + 1) times, no new ticket")
        check(server.log.dropFirst().allSatisfy { $0.bodyBytes == size }, "every try sends the whole file")
        check(server.log.dropFirst().allSatisfy { $0.headers["authorization"] == nil }, "no try carries the key")
        checkEqual(events.pauses, Array([1.0, 2.0].prefix(drops)), "\(drops) drop(s): a short pause before each new try")
        check(events.restartsBeforeEachPause, "progress goes back to 0 before each new try and ends at 1: \(events.all)")
    }

    server.configure(puts: [.drop])
    let events = UploadEvents()
    let failure = await uploadFailure("three dropped PUTs") {
        _ = try await uploadAPI(server, events: events).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    }
    checkEqual(failure?.kind, .interrupted, "three drops: interrupted")
    checkEqual(failure?.attempts, 3, "three PUTs")
    checkEqual(failure?.fileName, "reference.png", "the file is named")
    checkEqual(failure?.lastError, "NSURLErrorDomain -1005", "a dropped connection is URLError -1005")
    checkEqual(failure?.code, "upload_network", "the code for tool results and get_job")
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 3, "never a fourth try")
    checkEqual(events.pauses, [1, 2], "two pauses")

    server.configure(puts: [.drop])
    let named = await uploadFailure("a cut sent under a temporary name") {
        _ = try await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey,
                                                                        named: "beach.mp4")
    }
    checkEqual(named?.fileName, "beach.mp4", "the words name the file as the user knows it")
}
