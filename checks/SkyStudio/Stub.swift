import Foundation

// 假 Sky Studio：挂在 URLSession 上的协议，按脚本回话、把每个请求（方法、地址、头、体）记下来。不碰真的网络。

struct StubSeen {
    var method: String
    var url: String
    var headers: [String: String]
    var body: Data?
}

final class SkyStudioStub: URLProtocol {
    enum Reply {
        case http(Int, String)
        /// 连不上（断网、超时……）。
        case failure(URLError.Code)
    }

    static var handler: (StubSeen) -> Reply = { _ in .http(200, "{}") }
    static var seen: [StubSeen] = []
    private static let lock = NSLock()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkyStudioStub.self]
        return URLSession(configuration: configuration)
    }()

    static func reset(_ handler: @escaping (StubSeen) -> Reply) {
        lock.lock()
        seen = []
        self.handler = handler
        lock.unlock()
    }

    static var log: [StubSeen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let seen = StubSeen(
            method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody
        )
        Self.lock.lock()
        Self.seen.append(seen)
        let handler = Self.handler
        Self.lock.unlock()
        switch handler(seen) {
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// Sky Studio 仓库 docs/agents/skycut-api.md「GET /me」里的那份样例（2026-10-27 定稿 08bd908a，和 e9fa13e3 一样），原样抄来。
let sampleMe = """
{
  "account": {"id": "uuid", "email": "someone@example.com"},
  "credits": {"balance": 30},
  "skycut": {
    "plan": "trial",
    "trial_started_at": "2026-10-27T15:04:05Z",
    "trial_ends_at": "2026-11-03T15:04:05Z",
    "trial_unavailable": null,
    "paid_until": null,
    "features": {"mcp": true, "watermark": true},
    "valid_until": "2026-10-30T15:04:05Z",
    "min_version": "0.18.47",
    "max_running_jobs": 3,
    "recharge_url": "https://skystudioai.com/app?credits=1"
  },
  "server_time": "2026-10-27T15:04:05Z"
}
"""
