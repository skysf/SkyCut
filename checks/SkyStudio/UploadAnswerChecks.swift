import Foundation
import SrtFlowMCPKit

// Uploads to Sky Studio's storage, the cases that must not be tried again and the signed address (2026-11-23, PR #549 and its two
// reviews): an answer the storage began stands, even when its body then broke or stalled, and even when only its head came (a 403 is
// refused after one PUT; a 200 is success); a redirect is not followed (one try is one PUT); a TLS failure, a cancel and a stop during
// the pause end the upload; a `/uploads` refusal or an answer without an address is declined (Sky Studio's own refusal kept; a 413 or
// its `upload_too_large` is called too large); the address is renewed when it would run out or its validity is unknown, a renewal
// the network broke costs a try but is not counted as a PUT, and a renewal whose connection does not work ends the upload. Same
// local server and helpers as UploadRetryChecks.

func runUploadAnswerChecks(_ server: UploadServer, file: URL) async {
    // The review's case: a 403 whose body then stalled until the PUT timed out (here after 1.5 s) was tried again and the second
    // try's 200 taken as success. A reset body is the same error after an answer.
    for (reply, what) in [(UploadServer.PutReply.forbidden, "a 403"), (.forbiddenThenReset, "a 403 whose body was then reset"),
                          (.forbiddenThenStall, "a 403 whose body then stalled into a timeout")] {
        server.configure(puts: [reply, .ok])
        let events = UploadEvents()
        let refused = await uploadFailure(what) {
            _ = try await uploadAPI(server, events: events, putTimeout: 1.5).upload(fileURL: file, contentType: "image/png", purpose: "image",
                                                                                   key: jobKey)
        }
        checkEqual(refused?.kind, .refused(status: 403), "\(what): refused, with its status")
        checkEqual(refused?.code, "upload_refused", "\(what): upload_refused")
        checkEqual(refused?.attempts, 1, "\(what): one PUT")
        checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "\(what) is never tried again")
        checkEqual(events.pauses, [], "\(what): no pause")
    }

    // Only the head of a 403 came, and its body never: the system holds such an answer back (task.response stays nil, waiting for body
    // bytes), so the answer is known from the task's metrics. It is refused (status unknown) after one PUT, never tried again.
    server.configure(puts: [.forbiddenHeadersThenStall, .ok])
    let headEvents = UploadEvents()
    let headOnly = await uploadFailure("a 403 whose head came and whose body never did") {
        _ = try await uploadAPI(server, events: headEvents, putTimeout: 1.5).upload(fileURL: file, contentType: "image/png", purpose: "image",
                                                                                   key: jobKey)
    }
    checkEqual(headOnly?.kind, .refused(status: 0), "a head without a body: refused, its status unread")
    checkEqual(headOnly?.attempts, 1, "a head without a body: one PUT")
    checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "a head without a body is never tried again")
    checkEqual(headEvents.pauses, [], "a head without a body: no pause")
    check(headOnly?.message.contains("did not come through") == true, "the words say the answer did not come through")

    // A redirect is never followed: one try is one PUT, and upload_attempts says so.
    for code in [307, 308] {
        server.configure(puts: [.redirect(code), .ok])
        let redirected = await uploadFailure("a \(code) redirect") {
            _ = try await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
        }
        checkEqual(redirected?.kind, .refused(status: code), "a \(code): refused, not followed")
        checkEqual(redirected?.attempts, 1, "a \(code): one PUT")
        checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "a \(code): no second PUT to the new address")
    }

    // `/uploads` refused or answered without an address: declined, before any PUT, with Sky Studio's own refusal kept.
    // A file too large (a 413, or Sky Studio's reason upload_too_large) is said so, and only that.
    for (reply, what, status, tooLarge) in [(UploadServer.TicketReply.status(413), "a 413 from /uploads", 413, true),
                                            (.noAddress, "a /uploads answer without an address", 200, false),
                                            (.refusal(503, code: "voice_library_unavailable"), "Sky Studio's own refusal", 503, false),
                                            (.refusal(400, code: "invalid_request", reason: "upload_too_large"),
                                             "Sky Studio's own too-large refusal", 400, true)] {
        server.configure(puts: [.ok], tickets: [reply])
        var thrown: Error?
        let declined = await uploadFailure(what) {
            do { _ = try await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey) }
            catch { thrown = error; throw error }
        }
        checkEqual(declined?.kind, .declined(status: status), "\(what): declined, with its status")
        checkEqual(declined?.code, "upload_declined", "\(what): upload_declined")
        checkEqual(declined?.attempts, 0, "\(what): no PUT")
        check(!server.log.contains { $0.method == "PUT" }, "\(what): nothing was sent to the storage")
        checkEqual(declined?.isTooLarge, tooLarge, "\(what): too large \(tooLarge ? "is" : "is not") what it is called")
        if case .refusal(_, let code, _) = reply {
            checkEqual(declined?.server?.code, code, "\(what): Sky Studio's refusal is kept")
            checkEqual(declined?.fields(retry: "x")["server_code"], .string(code), "\(what): and its code reaches the AI")
            checkEqual(thrown.flatMap(SkyStudioVoiceLibraryErrors.kind), tooLarge ? .uploadTooLarge : .unavailable,
                       "\(what): the voice library still names it in its own words")
        }
    }

    for (reply, what) in [(UploadServer.PutReply.okThenStall, "a 200 whose body then stalled into a timeout"),
                          (.okThenReset, "a 200 whose body was then reset")] {
        server.configure(puts: [reply, .ok])
        let answered = try? await uploadAPI(server, events: UploadEvents(), putTimeout: 1.5).upload(fileURL: file, contentType: "image/png",
                                                                                                   purpose: "image", key: jobKey)
        checkEqual(answered?.absoluteString, server.fileURL(1), "\(what): the storage took the file")
        checkEqual(server.log.filter { $0.method == "PUT" }.count, 1, "\(what): a 200 is never tried again")
    }

    // A TLS failure on the first PUT (an https address on this plain server, as a certificate the Mac does not trust): not tried again.
    // (The system may open a second connection inside its own handshake; SkyCut's tries are what is counted here.)
    server.configure(puts: [.ok], tickets: [.ticket(life: 900, tls: true)])
    let tlsEvents = UploadEvents()
    let tls = await uploadFailure("a PUT whose TLS fails") {
        _ = try await uploadAPI(server, events: tlsEvents).upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    }
    checkEqual(tls?.kind, .unreachable, "a TLS failure on the PUT: could not connect")
    checkEqual(tls?.attempts, 1, "one PUT")
    checkEqual(tlsEvents.pauses, [], "no second try after a TLS failure")
    check(tls?.lastError.hasPrefix("NSURLErrorDomain") == true, "the system's error is kept: \(tls?.lastError ?? "")")
    check(!server.log.contains { $0.method == "PUT" }, "nothing reached the storage as a PUT")

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

func runUploadAddressChecks(_ server: UploadServer, file: URL) async {
    func run(_ puts: [UploadServer.PutReply], _ tickets: [UploadServer.TicketReply], clock: TimeInterval = 0) async -> Result<URL, Error> {
        server.configure(puts: puts, tickets: tickets, clockOffset: clock)
        do {
            return .success(try await uploadAPI(server, events: UploadEvents()).upload(fileURL: file, contentType: "image/png",
                                                                                     purpose: "image", key: jobKey))
        } catch {
            return .failure(error)
        }
    }
    let put1 = "PUT /r2/originals/u/skycut/1.png", put2 = "PUT /r2/originals/u/skycut/2.png"

    let renewed = try? await run([.drop, .ok], [.ticket(life: 30), .ticket(life: 900)]).get()
    checkEqual(uploadPaths(server), ["POST /uploads", put1, "POST /uploads", put2], "an address with 30 s left is renewed before the next try")
    checkEqual(renewed?.absoluteString, server.fileURL(2), "the file_url of the ticket whose PUT worked comes back")

    let skewed = try? await run([.drop, .ok], [.ticket(life: 900)], clock: -3_600).get()
    checkEqual(uploadPaths(server), ["POST /uploads", put1, put1], "Sky Studio's clock an hour behind this Mac's: the fresh address is reused")
    checkEqual(skewed?.absoluteString, server.fileURL(1), "and its file_url comes back")

    let unknown = try? await run([.drop, .ok], [.ticket(life: nil)]).get()
    checkEqual(uploadPaths(server), ["POST /uploads", put1, "POST /uploads", put2], "an address of unknown validity is never reused")
    checkEqual(unknown?.absoluteString, server.fileURL(2), "the renewed address's file_url comes back")

    let once = try? await run([.drop, .ok], [.ticket(life: 30), .drop, .ticket(life: 900)]).get()
    checkEqual(uploadPaths(server), ["POST /uploads", put1, "POST /uploads", "POST /uploads", put2],
               "a renewal the network broke costs a try; the next try renews and sends")
    checkEqual(once?.absoluteString, server.fileURL(2), "and the upload works")

    if case .failure(let error) = await run([.drop], [.ticket(life: 30), .drop]), let failure = SkyStudioUploadFailure.from(error) {
        checkEqual(failure.kind, .interrupted, "renewals broken twice: interrupted")
        checkEqual(failure.attempts, 1, "upload_attempts counts PUTs (one), not renewals")
        check(failure.message.contains("on its only try"), "and the words say one try: \(failure.message)")
    } else {
        check(false, "renewals broken twice end as an upload failure")
    }

    // A renewal whose connection does not work (the review's case: a certificate the Mac does not trust). The pause arms a fault that
    // fails the next `/uploads` ask with -1202 before it leaves this Mac; the error still takes the API's own path. It ends the upload:
    // no other ask, no second PUT. A server that stops listening is no stand-in: the system reports a refused loopback connection as
    // -1005 ("connection lost") in a few tries out of a hundred, so that renewal read as broken now and then (2026-11-23).
    server.configure(puts: [.drop, .ok], tickets: [.ticket(life: 30)])
    var retry = SkyStudioUploadRetry()
    retry.sleep = { _ in RenewalCertificateFault.armed = true }
    let api = SkyStudioAPI(session: renewalFaultSession, base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!,
                           version: "0.18.50", machine: nil, uploadRetry: retry)
    let refused = await uploadFailure("a renewal whose certificate is not trusted") {
        _ = try await api.upload(fileURL: file, contentType: "image/png", purpose: "image", key: jobKey)
    }
    RenewalCertificateFault.armed = false
    checkEqual(refused?.kind, .unreachable, "a renewal whose connection does not work ends the upload as could not connect "
        + "(\(refused?.lastError ?? "no upload failure"))")
    checkEqual(refused?.attempts, 1, "upload_attempts counts the one PUT")
    checkEqual(refused?.lastError, "NSURLErrorDomain -1202", "the system's error is kept")
    checkEqual(uploadPaths(server), ["POST /uploads", put1], "it is not tried again: no other ask, no second PUT")
}

/// While armed, fails every `/uploads` ask with an untrusted certificate (-1202) before it leaves this Mac; everything else reaches the
/// local server. Only `renewalFaultSession` carries it.
final class RenewalCertificateFault: URLProtocol {
    private static let lock = NSLock()
    private static var isArmed = false
    static var armed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isArmed }
        set { lock.lock(); isArmed = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { armed && request.url?.path.hasSuffix("/uploads") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)) }
    override func stopLoading() {}
}

/// The checks' session (no proxy) with RenewalCertificateFault in front.
let renewalFaultSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil
    configuration.protocolClasses = [RenewalCertificateFault.self] + (configuration.protocolClasses ?? [])
    return URLSession(configuration: configuration)
}()
