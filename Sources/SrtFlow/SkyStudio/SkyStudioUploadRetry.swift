import Foundation
import SrtFlowMCPKit

// MARK: - An upload to Sky Studio's storage: when SkyStudioAPI.upload tries the PUT again, and what it says when it gives up
//
// What it covers (2026-11-23, generate-34 / generate-35: the reference image's PUT to Sky Studio's storage lost its connection on a
// slow, unstable uplink and the job ended at once; the system never replays a body upload by itself):
// - what a transport error means inside an upload (`classify`): the network broke this try (worth another), or the connection does not
//   work at all (another try would only repeat it); how many tries and the pauses between them;
// - the `/uploads` ticket and when its signed address must be renewed before the next try (`SkyStudioUploadTicket`);
// - the error when the upload gives up (`SkyStudioUploadFailure`): interrupted, could not connect, or refused by the storage. English
//   for the AI, the stable code and the PUT count for tool results and get_job. Nothing was submitted, so nothing was charged.
// What it does not cover: sending anything (SkyStudioAPI.upload owns the loop), the words the user reads (SkyStudioUploadWords,
// localized), what each job does with the error (generation, upscale, voice change, voice library, characters).
// Rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".

struct SkyStudioUploadRetry: Sendable {
    /// Tries in all, the first one included.
    var attempts = 3
    /// Seconds to wait before the second, third… try (the last one repeats).
    var pauses: [TimeInterval] = [1, 2]
    /// The signed address is renewed before the next try when less is left of it than the last try took plus this.
    var renewalMargin: TimeInterval = 60
    /// How long a PUT may go without a byte moving before it times out (the system's idle timeout; checks shorten it).
    var putTimeout: TimeInterval = 600
    /// Waits between tries; a cancelled task ends the wait at once (checks record the pauses instead of waiting).
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    static let standard = SkyStudioUploadRetry()

    /// The pause before try `attempt` (2, 3…).
    func pause(before attempt: Int) async throws {
        guard let last = pauses.last else { return }
        let index = attempt - 2
        try await sleep(pauses.indices.contains(index) ? pauses[index] : last)
    }

    /// The network broke this try, so the same PUT may work a moment later: the connection was lost or reset, the transfer stalled
    /// past its timeout, or the network went away (Wi-Fi or VPN changing). A cancel, an HTTP answer, an address that cannot be
    /// found or connected to, a certificate or TLS failure and a file that cannot be read are never tried again: they say something
    /// a second try would only repeat.
    static func isTransient(_ error: Error) -> Bool {
        if let url = error as? URLError { return transientCodes.contains(url.code.rawValue) }
        let system = error as NSError
        return system.domain == NSPOSIXErrorDomain && transientPOSIXCodes.contains(Int32(truncatingIfNeeded: system.code))
    }

    /// -1005 connection lost (also a reset mid-transfer), -1001 timed out, -1009 offline (the network changed).
    static let transientCodes: Set<Int> = [URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue,
                                           URLError.notConnectedToInternet.rawValue]
    static let transientPOSIXCodes: Set<Int32> = [ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET]

    /// What a transport error means inside an upload (a cancel is sorted out before): `Broken` or `Unreachable`.
    static func classify(_ error: Error) -> Error {
        isTransient(error) ? Broken(detail: describe(error)) : Unreachable(detail: describe(error))
    }

    /// "NSURLErrorDomain -1005": the last error, the same in every language.
    static func describe(_ error: Error) -> String {
        let system = error as NSError
        return "\(system.domain) \(system.code)"
    }

    /// One try the network broke: worth another. Only inside SkyStudioAPI.upload: it never leaves it.
    struct Broken: Error {
        let detail: String
    }

    /// The connection does not work at all (address, certificate, TLS): the upload ends. Only inside SkyStudioAPI.upload.
    struct Unreachable: Error {
        let detail: String
    }

    /// The storage answered with an error: that answer stands and the upload ends. Only inside SkyStudioAPI.upload.
    struct Refused: Error {
        let status: Int
    }

    /// Sky Studio did not hand out an address (`/uploads` refused, or answered something with no address): the upload ends. Its own
    /// refusal is kept (`server`). Only inside SkyStudioAPI.upload.
    struct Declined: Error {
        let status: Int
        let server: SkyStudioServerError?
        let detail: String
    }
}

/// What `POST /uploads` answered: where to PUT the file (a signed address, valid for a while) and the `file_url` that jobs take.
struct SkyStudioUploadTicket: Sendable {
    let uploadURL: URL
    let method: String
    let headers: [String: String]
    let fileURL: URL
    /// When the signed address stops working, on this Mac's clock; nil when the answer did not say (it is then renewed before every
    /// new try: an address of unknown validity is never reused).
    let deadline: Date?

    /// `received`: when the answer arrived, on this Mac's clock; `serverDate`: the answer's HTTP `Date` header.
    init?(_ answer: JSONValue, received: Date, serverDate: String?) {
        guard let target = answer["upload_url"]?.stringValue.flatMap(URL.init(string:)), target.scheme != nil,
              let link = answer["file_url"]?.stringValue.flatMap(URL.init(string:)), link.scheme != nil else { return nil }
        uploadURL = target
        fileURL = link
        method = answer["method"]?.stringValue ?? "PUT"
        headers = (answer["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        deadline = Self.deadline(expiresAt: answer["expires_at"]?.stringValue, received: received, serverDate: serverDate)
    }

    /// The PUT: every header the server gave, as given, and never the key (the address is the storage's own, signed).
    var request: URLRequest {
        var put = URLRequest(url: uploadURL)
        put.httpMethod = method
        put.timeoutInterval = 600
        for (name, value) in headers { put.setValue(value, forHTTPHeaderField: name) }
        return put
    }

    /// Renew before the next try when the address would run out before that try is done (less is left than the last try took plus
    /// `margin`) or when its validity is unknown.
    func needsRenewal(now: Date, lastTry: TimeInterval, margin: TimeInterval) -> Bool {
        guard let deadline else { return true }
        return deadline.timeIntervalSince(now) < lastTry + margin
    }

    /// `expires_at` is on Sky Studio's clock. With the answer's `Date` the address's lifetime moves onto this Mac's clock, so a Mac
    /// clock that is minutes off neither reuses a dead address nor renews a live one; without it `expires_at` is taken as it is.
    static func deadline(expiresAt: String?, received: Date, serverDate: String?) -> Date? {
        guard let expires = expiresAt.flatMap(SkyStudioJSON.parseDate) else { return nil }
        guard let server = serverDate.flatMap(httpDate) else { return expires }
        return received.addingTimeInterval(expires.timeIntervalSince(server))
    }

    /// An HTTP `Date` header ("Sun, 23 Nov 2026 06:51:00 GMT").
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
