import Darwin
import Foundation

// A local TCP + UDP listener on one 127.0.0.1 port that counts everything that reaches it: accepted connections (even
// ones that never send a byte: link preconnect) and datagrams (WebRTC's STUN). The network check points every way a page
// can reach the network at this port; the lock must keep the count at zero.

final class NetworkListener: @unchecked Sendable {
    let port: UInt16
    private let tcp: Int32
    private let udp: Int32
    private let lock = NSLock()
    private var running = true
    private var connections: [String] = []
    private var datagrams = 0

    init() throws {
        let stream = socket(AF_INET, SOCK_STREAM, 0)
        let datagram = socket(AF_INET, SOCK_DGRAM, 0)
        guard stream >= 0, datagram >= 0 else { throw NSError(domain: "NetworkListener", code: 1) }
        var yes: Int32 = 1
        setsockopt(stream, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        guard NetworkListener.bind(stream, &address), listen(stream, 64) == 0 else { throw NSError(domain: "NetworkListener", code: 2) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(stream, $0, &length) } }
        address.sin_port = bound.sin_port
        guard NetworkListener.bind(datagram, &address) else { throw NSError(domain: "NetworkListener", code: 3) }
        tcp = stream
        udp = datagram
        port = UInt16(bigEndian: bound.sin_port)
        Thread { self.acceptLoop() }.start()
        Thread { self.receiveLoop() }.start()
    }

    private static func bind(_ fd: Int32, _ address: inout sockaddr_in) -> Bool {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    var counts: (connections: [String], datagrams: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (connections, datagrams)
    }

    func reset() {
        lock.lock()
        connections = []
        datagrams = 0
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            var poller = pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let client = accept(tcp, nil, nil)
            guard client >= 0 else { continue }
            var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 512)
            let read = recv(client, &buffer, buffer.count, 0)
            let firstLine = read > 0 ? String(decoding: buffer[0..<read], as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "" : ""
            close(client)
            lock.lock()
            connections.append(firstLine.isEmpty ? "(connected, sent nothing)" : firstLine)
            lock.unlock()
        }
        close(tcp)
    }

    private func receiveLoop() {
        while isRunning {
            var poller = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 2048)
            if recv(udp, &buffer, buffer.count, 0) >= 0 {
                lock.lock()
                datagrams += 1
                lock.unlock()
            }
        }
        close(udp)
    }

    /// Positive control: this process can reach the listener both ways (so zero later means blocked, not deaf).
    func selfTest() -> Bool {
        reset()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        _ = "GET /self-test HTTP/1.1\r\n\r\n".withCString { send(client, $0, strlen($0), 0) }
        close(client)
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, "x", 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        close(sender)
        for _ in 0..<30 {
            let seen = counts
            if seen.connections.count == 1, seen.datagrams == 1 { reset(); return connected }
            usleep(50_000)
        }
        return false
    }
}
