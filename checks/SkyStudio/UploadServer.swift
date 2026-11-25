import Darwin
import Foundation

// A local HTTP/1.1 server on 127.0.0.1 for the upload retry checks (UploadRetryChecks). It answers `POST …/uploads` the way the
// scenario says (a ticket whose signed address points back at itself, with or without `expires_at`, over http or, to make the PUT's TLS
// fail on this plain server, https; or a dropped connection) and treats each `PUT /r2/…` likewise: read the whole body, then drop the
// connection without an answer (FIN) or reset it (RST); answer 200 or 403; start a 403 or 200 answer and drop it mid-body; or hold the
// connection open until the client goes away. It can stop listening (a refused connection). Every request is logged once its body is read, or once the client cut it short (`complete: false`, how many bytes arrived;
// with `slowRead` the server reads 32 KB every 10 ms, so a client that cuts early is seen mid-body). Each connection carries one
// request (`Connection: close`), so the client never reuses a connection and never replays a request on its own. Real sockets, so
// the system's own transfer code is what is tested; no proxy and no real network.
// Downloads (DownloadRetryChecks, 2026-11-24): each `GET /files/…` gets the next `GetReply`: the whole result (200 with an ETag and
// Accept-Ranges, so the system can resume; a resumed try's Range, with a matching If-Range, gets 206 and the rest), part of the body
// then the connection closed or reset, an HTTP error, or its head then a stall until the client goes away.

final class UploadServer: @unchecked Sendable {
    /// `…ThenStall` / `…ThenReset`: the answer's head and 1 KB of its body go out, then the connection hangs (the client times out) or
    /// is reset.
    /// `forbiddenHeadersThenStall`: only the head goes out (its declared body never comes).
    enum PutReply: Sendable {
        case drop, reset, ok, forbidden, hold, forbiddenThenStall, forbiddenHeadersThenStall, forbiddenThenReset, okThenStall, okThenReset
        /// A redirect (307 / 308) to another address on this server.
        case redirect(Int)
    }
    /// What a `POST …/uploads` gets: a ticket (`life`: seconds from the answer's `Date` to `expires_at`, nil = no `expires_at`; `tls`:
    /// the signed address is https, which this plain server cannot speak), or the connection dropped after the request.
    /// `status`: an HTTP error with a plain body; `refusal`: Sky Studio's own error answer; `noAddress`: a 200 without `upload_url`.
    enum TicketReply: Sendable { case ticket(life: TimeInterval?, tls: Bool = false), drop, status(Int), refusal(Int, code: String, reason: String? = nil), noAddress }

    /// What a `GET /files/…` gets. `slow`: the whole result in 32 KB pieces every 10 ms (a client that cuts early is seen mid-body).
    /// `cut` / `cutReset`: the head (the whole length declared) and that many body bytes from where the Range starts, then the
    /// connection closed (FIN) or reset. `stall`: the head and 1 KB, then nothing until the client goes away. `statusCut`: an HTTP error
    /// whose head declares 64 KB, then 1 KB of it and the connection closed; `statusStall`: only its head, then nothing.
    /// `shortRange`: a resumed GET answered 206 with only that many bytes from where the Range starts (`bytes a-b/total`, b short of the
    /// end), the answer itself whole. `redirect`: a 302 to another result on this server.
    enum GetReply: Sendable { case file, slow, cut(Int), cutReset(Int), status(Int), statusCut(Int), statusStall(Int), stall, shortRange(Int), redirect(String) }
    static let etag = "\"skycut-check-1\""

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
    private var ticketReplies: [TicketReply] = [.ticket(life: 900)]
    private var ticketsServed = 0
    private var clockOffset: TimeInterval = 0
    private var slowRead = false
    private var seen: [Seen] = []
    private var gets: [GetReply] = [.file]
    private var getsServed = 0
    private var result = Data()
    private var validators = true

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

    /// The next scenario: what the PUTs and the `/uploads` asks get in order (the last one repeats), and how far Sky Studio's clock is
    /// from this Mac's (the `Date` header and `expires_at` both move by it). Clears the log.
    func configure(puts: [PutReply], tickets: [TicketReply] = [.ticket(life: 900)], clockOffset: TimeInterval = 0, slowRead: Bool = false) {
        lock.lock()
        self.slowRead = slowRead
        self.puts = puts.isEmpty ? [.ok] : puts
        ticketReplies = tickets.isEmpty ? [.ticket(life: 900)] : tickets
        self.clockOffset = clockOffset
        putsServed = 0
        ticketsServed = 0
        self.tickets = 0
        seen = []
        lock.unlock()
    }

    /// The next download scenario: what the GETs get in order (the last one repeats), the result's bytes, and whether its answers carry
    /// an ETag / Accept-Ranges / Last-Modified (without them the system cannot resume). Clears the log.
    func configureDownload(gets: [GetReply], result: Data, validators: Bool = true) {
        lock.lock()
        self.gets = gets.isEmpty ? [.file] : gets
        getsServed = 0
        self.result = result
        self.validators = validators
        seen = []
        lock.unlock()
    }

    /// The result's address on this server (`tls`: https, which this plain server cannot speak).
    func resultURL(_ name: String, tls: Bool = false) -> URL { URL(string: "\(tls ? "https" : "http")://127.0.0.1:\(port)/files/\(name)")! }

    var log: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// The signed address and the file_url of ticket `n` (1, 2…).
    func uploadURL(_ n: Int) -> String { "http://127.0.0.1:\(port)/r2/originals/u/skycut/\(n).png?X-Amz-Signature=s\(n)" }
    func fileURL(_ n: Int) -> String { "https://r2.example/originals/u/skycut/\(n).png" }

    /// Stops listening (a new connection is then refused). Only the first call closes the socket: a second close could hit a descriptor
    /// the process has reused since.
    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
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
        if request.method == "TLS" {
            // A TLS client on this plain server (an https address): a plain answer makes its handshake fail.
            lock.unlock()
            respond(client, status: "400 Bad Request", body: "", extra: [])
            return
        }
        if request.method == "GET", request.path.hasPrefix("/files/") {
            let answer = gets[min(getsServed, gets.count - 1)]
            getsServed += 1
            let (body, validated) = (result, validators)
            lock.unlock()
            serveGet(client, answer, body: body, validators: validated, headers: request.headers)
            return
        }
        let reply: PutReply?
        var ticket: (reply: TicketReply, n: Int, date: Date)?
        if request.method == "PUT" {
            reply = puts[min(putsServed, puts.count - 1)]
            putsServed += 1
        } else {
            reply = nil
            if request.path.hasSuffix("/uploads") {
                let answer = ticketReplies[min(ticketsServed, ticketReplies.count - 1)]
                ticketsServed += 1
                if case .ticket = answer { tickets += 1 }
                ticket = (answer, tickets, Date().addingTimeInterval(clockOffset))
            }
        }
        lock.unlock()
        if let ticket {
            switch ticket.reply {
            case .ticket(let life, let tls):
                let expires = life.map { ", \"expires_at\": \"\(Self.iso(ticket.date.addingTimeInterval($0)))\"" } ?? ""
                let address = tls ? uploadURL(ticket.n).replacingOccurrences(of: "http://", with: "https://") : uploadURL(ticket.n)
                let body = "{\"upload_url\": \"\(address)\", \"method\": \"PUT\", "
                    + "\"headers\": {\"Content-Type\": \"image/png\", \"x-amz-meta-app\": \"skycut\"}, "
                    + "\"file_url\": \"\(fileURL(ticket.n))\"\(expires)}"
                respond(client, status: "200 OK", body: body, extra: ["Date: " + Self.httpDate(ticket.date), "Content-Type: application/json"])
            case .drop:
                close(client)
            case .status(let status):
                respond(client, status: "\(status) Error", body: "<html>Request Entity Too Large</html>", extra: ["Content-Type: text/html"])
            case .refusal(let status, let code, let reason):
                let why = reason.map { ", \"reason\": \"\($0)\"" } ?? ""
                respond(client, status: "\(status) Error",
                        body: "{\"error\": {\"code\": \"\(code)\", \"message\": \"Refused by the test server.\"\(why)}}",
                        extra: ["Content-Type: application/json"])
            case .noAddress:
                respond(client, status: "200 OK", body: "{\"method\": \"PUT\"}", extra: ["Content-Type: application/json"])
            }
            return
        }
        switch reply {
        case .drop?:
            close(client)
        case .reset?:
            resetAndClose(client)
        case .ok?:
            respond(client, status: "200 OK", body: "", extra: [])
        case .forbidden?:
            respond(client, status: "403 Forbidden", body: "<Error><Code>AccessDenied</Code></Error>", extra: ["Content-Type: application/xml"])
        case .hold?:
            hold(client)
        case .forbiddenHeadersThenStall?:
            begin(client, status: "403 Forbidden", declaredLength: 65_536, bodyBytes: 0)
            hold(client)
        case .forbiddenThenStall?:
            begin(client, status: "403 Forbidden", declaredLength: 65_536)
            hold(client)
        case .forbiddenThenReset?:
            begin(client, status: "403 Forbidden", declaredLength: 65_536)
            usleep(200_000)   // the client reads the head first: a reset right behind it could take the head with it
            resetAndClose(client)
        case .okThenStall?:
            begin(client, status: "200 OK", declaredLength: 65_536)
            hold(client)
        case .redirect(let code)?:
            respond(client, status: "\(code) Redirect", body: "", extra: ["Location: http://127.0.0.1:\(port)/r2/moved"])
        case .okThenReset?:
            begin(client, status: "200 OK", declaredLength: 65_536)
            usleep(200_000)
            resetAndClose(client)
        case nil:
            respond(client, status: "404 Not Found", body: "", extra: [])
        }
    }

    /// A download's answer: a resumed try's Range is honoured only with validators and a matching If-Range (else the whole body again).
    private func serveGet(_ client: Int32, _ reply: GetReply, body: Data, validators: Bool, headers: [String: String]) {
        if case .status(let code) = reply {
            respond(client, status: "\(code) Error", body: "<Error><Code>AccessDenied</Code></Error>", extra: ["Content-Type: application/xml"])
            return
        }
        if case .statusCut(let code) = reply {
            begin(client, status: "\(code) Error", declaredLength: 65_536)
            usleep(200_000)
            shutdown(client, SHUT_WR)
            close(client)
            return
        }
        if case .statusStall(let code) = reply {
            begin(client, status: "\(code) Error", declaredLength: 65_536, bodyBytes: 0)
            return hold(client)
        }
        if case .redirect(let name) = reply {
            return respond(client, status: "302 Found", body: "", extra: ["Location: /files/\(name)"])
        }
        var start = 0
        if validators, let range = headers["range"], range.hasPrefix("bytes="), headers["if-range"].map({ $0 == Self.etag }) ?? true,
           let offset = Int(range.dropFirst(6).prefix { $0 != "-" }), offset < body.count {
            start = offset
        }
        // A short 206 ends `bytes` past where the Range starts, short of the result's end.
        var end = body.count
        if case .shortRange(let bytes) = reply, start > 0 { end = min(body.count - 1, start + bytes) }
        var head = [start > 0 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK", "Content-Length: \(end - start)",
                    "Content-Type: video/mp4", "Connection: close"]
        if validators { head += ["ETag: \(Self.etag)", "Accept-Ranges: bytes", "Last-Modified: Mon, 23 Nov 2026 07:00:00 GMT"] }
        if start > 0 { head.append("Content-Range: bytes \(start)-\(end - 1)/\(body.count)") }
        write(client, Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        switch reply {
        case .file, .shortRange:
            write(client, body.subdata(in: start..<end))
            shutdown(client, SHUT_WR)
            close(client)
        case .slow:
            var at = start
            while at < body.count, isRunning {
                let end = min(body.count, at + 32_768)
                guard write(client, body.subdata(in: at..<end)) else { break }
                at = end
                usleep(10_000)
            }
            shutdown(client, SHUT_WR)
            close(client)
        case .cut(let bytes), .cutReset(let bytes):
            write(client, body.subdata(in: start..<min(body.count, start + bytes)))
            usleep(200_000)   // the client takes in what arrived before the connection goes
            if case .cutReset = reply { resetAndClose(client) } else { shutdown(client, SHUT_WR); close(client) }
        case .stall:
            write(client, body.subdata(in: start..<min(body.count, start + 1_024)))
            hold(client)
        case .status, .statusCut, .statusStall, .redirect:
            break
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
        write(client, Data(head.utf8) + payload)
        shutdown(client, SHUT_WR)
        close(client)
    }

    /// An answer that starts: its head (declaring `declaredLength`) and 1 KB of body, with the connection left open.
    private func begin(_ client: Int32, status: String, declaredLength: Int, bodyBytes: Int = 1_024) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(declaredLength)\r\nContent-Type: application/xml\r\nConnection: close\r\n\r\n"
        write(client, Data(head.utf8) + Data(repeating: 0x78, count: bodyBytes))
    }

    /// An abortive close: the client sees the connection reset.
    private func resetAndClose(_ client: Int32) {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(client)
    }

    /// False when the client went away before all of it was sent.
    @discardableResult
    private func write(_ client: Int32, _ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
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
            // A TLS handshake record (0x16) instead of an HTTP request: an https client on this plain server.
            if data.first == 0x16 { return Seen(method: "TLS", path: "", bodyBytes: 0, headers: [:]) }
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
