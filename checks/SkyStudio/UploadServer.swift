import Darwin
import Foundation

// A local HTTP/1.1 server on 127.0.0.1 for the upload retry checks (UploadRetryChecks). It answers `POST …/uploads` with a ticket
// whose signed address points back at itself, and treats each `PUT /r2/…` the way the scenario says: read the whole body, then drop
// the connection without an answer (FIN) or reset it (RST); answer 200; answer 403; or hold the connection open until the client goes
// away. Every request is logged once its body is read, or once the client cut it short (`complete: false`, how many bytes arrived;
// with `slowRead` the server reads 32 KB every 10 ms, so a client that cuts early is seen mid-body). Each connection carries one
// request (`Connection: close`), so the client never reuses a connection and never replays a request on its own. Real sockets, so
// the system's own transfer code is what is tested; no proxy and no real network.

final class UploadServer: @unchecked Sendable {
    enum PutReply: Sendable { case drop, reset, ok, forbidden, hold }

    struct Seen: Sendable {
        let method: String
        let path: String
        let bodyBytes: Int
        let headers: [String: String]
        /// False when the client went away before the whole body arrived.
        var complete = true
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var running = true
    private var puts: [PutReply] = [.ok]
    private var putsServed = 0
    private var tickets = 0
    private var ticketLife: TimeInterval = 900
    private var clockOffset: TimeInterval = 0
    private var slowRead = false
    private var seen: [Seen] = []

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw NSError(domain: "UploadServer", code: 1) }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard bound, listen(socket, 16) == 0 else { close(socket); throw NSError(domain: "UploadServer", code: 2) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        listener = socket
        port = UInt16(bigEndian: actual.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    /// The next scenario: what the PUTs get in order (the last one repeats), how long a ticket lives after the answer's `Date`, and how
    /// far Sky Studio's clock is from this Mac's (the `Date` header and `expires_at` both move by it). Clears the log.
    func configure(puts: [PutReply], ticketLife: TimeInterval = 900, clockOffset: TimeInterval = 0, slowRead: Bool = false) {
        lock.lock()
        self.slowRead = slowRead
        self.puts = puts.isEmpty ? [.ok] : puts
        self.ticketLife = ticketLife
        self.clockOffset = clockOffset
        putsServed = 0
        tickets = 0
        seen = []
        lock.unlock()
    }

    var log: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// The signed address and the file_url of ticket `n` (1, 2…).
    func uploadURL(_ n: Int) -> String { "http://127.0.0.1:\(port)/r2/originals/u/skycut/\(n).png?X-Amz-Signature=s\(n)" }
    func fileURL(_ n: Int) -> String { "https://r2.example/originals/u/skycut/\(n).png" }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private var isSlow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return slowRead
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = Self.read(client, slowly: isSlow) else { close(client); return }
        lock.lock()
        seen.append(request)
        guard request.complete else { lock.unlock(); close(client); return }
        let reply: PutReply?
        var ticket: (n: Int, date: Date, life: TimeInterval)?
        if request.method == "PUT" {
            reply = puts[min(putsServed, puts.count - 1)]
            putsServed += 1
        } else {
            reply = nil
            if request.path.hasSuffix("/uploads") {
                tickets += 1
                ticket = (tickets, Date().addingTimeInterval(clockOffset), ticketLife)
            }
        }
        lock.unlock()
        if let ticket {
            let body = """
            {"upload_url": "\(uploadURL(ticket.n))", "method": "PUT", "headers": {"Content-Type": "image/png", "x-amz-meta-app": "skycut"}, \
            "file_url": "\(fileURL(ticket.n))", "expires_at": "\(Self.iso(ticket.date.addingTimeInterval(ticket.life)))"}
            """
            respond(client, status: "200 OK", body: body, extra: ["Date: " + Self.httpDate(ticket.date), "Content-Type: application/json"])
            return
        }
        switch reply {
        case .drop?:
            close(client)
        case .reset?:
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            close(client)
        case .ok?:
            respond(client, status: "200 OK", body: "", extra: [])
        case .forbidden?:
            respond(client, status: "403 Forbidden", body: "<Error><Code>AccessDenied</Code></Error>", extra: ["Content-Type: application/xml"])
        case .hold?:
            hold(client)
        case nil:
            respond(client, status: "404 Not Found", body: "", extra: [])
        }
    }

    /// Keep the connection open without answering until the client closes it (a cancel) or the server stops.
    private func hold(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while isRunning {
            var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            if recv(client, &buffer, buffer.count, 0) <= 0 { break }
        }
        close(client)
    }

    private func respond(_ client: Int32, status: String, body: String, extra: [String]) {
        let payload = Data(body.utf8)
        let head = (["HTTP/1.1 " + status, "Content-Length: \(payload.count)", "Connection: close"] + extra).joined(separator: "\r\n") + "\r\n\r\n"
        let bytes = Data(head.utf8) + payload
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
        shutdown(client, SHUT_WR)
        close(client)
    }

    /// One request: the head up to the blank line, then exactly Content-Length bytes of body (fewer when the client cut it short).
    private static func read(_ client: Int32, slowly: Bool) -> Seen? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let blank = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            headEnd = data.range(of: blank)
        }
        guard let end = headEnd, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let expected = Int(headers["content-length"] ?? "") ?? 0
        var body = data.count - end.upperBound
        while body < expected {
            if slowly { usleep(10_000) }
            let count = recv(client, &buffer, min(slowly ? 32_768 : buffer.count, expected - body), 0)
            guard count > 0 else { return Seen(method: parts[0], path: parts[1], bodyBytes: body, headers: headers, complete: false) }
            body += count
        }
        return Seen(method: parts[0], path: parts[1], bodyBytes: body, headers: headers)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
