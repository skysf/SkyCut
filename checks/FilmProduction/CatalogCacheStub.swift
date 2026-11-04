import Foundation

// 只供目录竞态检查：真正 URLSession/URLProtocol，但所有回答由台架显式放行，无网络或睡眠猜时序。
final class CatalogCacheStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [CatalogCacheStub] = []
    private static var waiters: [UUID: (Int, CheckedContinuation<Void, Error>)] = [:]
    private static var automaticFrom: Int?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogCacheStub.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock()
        precondition(waiters.isEmpty, "Previous cache probe still has an unresolved waiter")
        requests = []; automaticFrom = nil
        lock.unlock()
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    static func received(_ count: Int) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if requests.count >= count { lock.unlock(); continuation.resume(); return }
            waiters[id] = (count, continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
                waiter?.1.resume(throwing: ProductionCheckFailure.timedOut("catalog request \(count)"))
            }
        }
    }

    static func automaticallyAnswer(from index: Int) {
        lock.lock(); automaticFrom = index; lock.unlock()
    }

    static func answer(_ index: Int) {
        lock.lock(); let request = requests[index]; lock.unlock()
        request.finish()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let index = Self.requests.count
        Self.requests.append(self)
        let ready = Self.waiters.filter { $0.value.0 <= Self.requests.count }
        for id in ready.keys { Self.waiters.removeValue(forKey: id) }
        let automatic = Self.automaticFrom.map { index >= $0 } ?? false
        Self.lock.unlock()
        for waiter in ready.values { waiter.1.resume() }
        if automatic { finish() }
    }

    private func finish() {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let id = key.contains("old") ? "old-catalog" : "new-catalog"
        let body = "{\"models\":[{\"id\":\"\(id)\",\"kind\":\"image\",\"title\":\"Synthetic public model\"}]}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
