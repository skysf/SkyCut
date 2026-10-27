import Foundation
import SrtFlowMCPKit

// MARK: - 调 Sky Studio 给 SkyCut 的接口（`https://skystudioai.com/api/skycut/v1`）
//
// 管什么：发请求（认证头、版本号、机器号）、读回答、没问成时说清楚是哪一种（服务器回了错 / 没连上 / 回的不像话）。
// **SkyCut 里只有这里碰 Sky Studio 的地址**（checks/sky-studio-wiring.sh 钉着）。合同以 Sky Studio 仓库的 docs/agents/skycut-api.md 为准。
// 现在只有 `GET /me`（收费方案第 5 刀）；生成、upscale、克隆要的 /models、/quote、/uploads、/jobs 是第 6 刀。
// 不管什么：Key 存哪（SkyStudioKey）、回答还算不算数（SkyCutLicense）、什么时候问（SkyStudioAccount）。
//
// 自检和冒烟用 `SRTFLOW_SKYSTUDIO_API_BASE` 把地址指到本机的假服务器，**只认回环地址**（Key 不会因此发到别处）。

struct SkyStudioAPI: Sendable {
    static let productionBase = URL(string: "https://skystudioai.com/api/skycut/v1")!
    static let baseEnvironmentKey = "SRTFLOW_SKYSTUDIO_API_BASE"

    let session: URLSession
    let base: URL
    let version: String
    let machine: String?

    init(
        session: URLSession = .shared, base: URL = SkyStudioAPI.configuredBase(ProcessInfo.processInfo.environment),
        version: String = SkyStudioAPI.appVersion, machine: String? = SkyStudioMachine.current
    ) {
        self.session = session
        self.base = base
        self.version = version
        self.machine = machine
    }

    /// 这个 SkyCut 的版本号（`X-SkyCut-Version`；比服务器要的最低版本低就回 `upgrade_required`）。
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 地址：环境变量指到本机的假服务器时用它（只认 http(s)://回环地址），别的一律正式地址。
    static func configuredBase(_ environment: [String: String]) -> URL {
        guard let text = environment[baseEnvironmentKey], let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, isLoopback(host) else { return productionBase }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: 接口

    /// `GET /me`：这个 Key 是谁、余额、SkyCut 的授权。账号第一次来时服务器顺手开始体验（这台 Mac 没体验过的话）。
    func me(key: String) async throws -> SkyStudioMe {
        let data = try await send(request("me", key: key))
        do {
            return try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: data)
        } catch {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
    }

    // MARK: 发请求

    func request(_ path: String, key: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "X-SkyCut-Version")
        if let machine { request.setValue(machine, forHTTPHeaderField: "X-SkyCut-Machine") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 发出去、拿回 2xx 的正文；别的都换成 `SkyStudioFailure`（取消照旧是 CancellationError）。
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SkyStudioFailure.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
        return data
    }

    /// 不是 2xx：服务器照约好的回了 `{"error": {"code", "message", …}}` 就原样留着，不是就是「回的不像话」。
    static func failure(status: Int, data: Data) -> SkyStudioFailure {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var error)? = body["error"],
              let code = error["code"]?.stringValue, !code.isEmpty else {
            return .badAnswer(status: status)
        }
        let message = error["message"]?.stringValue ?? code
        error["code"] = nil
        error["message"] = nil
        return .server(SkyStudioServerError(status: status, code: code, message: message, fields: error))
    }
}

/// 服务器照约好的格式回的错。`message` 是写给人看的英文，SkyCut 原样给用户 / AI 看。
struct SkyStudioServerError: Equatable, Sendable {
    static let invalidKey = "invalid_key"
    static let upgradeRequired = "upgrade_required"

    let status: Int
    let code: String
    let message: String
    /// 附加的字段（`min_version`、`download_url`、`balance`、`retry_after`…），原样留着。
    let fields: [String: JSONValue]

    var downloadURL: URL? { SkyStudioLinks.webURL(fields["download_url"]?.stringValue) }
}

/// 问 Sky Studio 没问成。给人看的话在界面那一层按语言换（SkyStudioAccount），服务器的 message 原样带上。
enum SkyStudioFailure: Error, Equatable, Sendable {
    /// 服务器回了错（Key 不对、版本太老、余额不够……）。
    case server(SkyStudioServerError)
    /// 没连上：断网、超时、找不到主机。
    case network(String)
    /// 回的不是约好的样子（不是 JSON、少了字段）。
    case badAnswer(status: Int)
}
