import Foundation

// MARK: - `GET /me` 的回答，和它怎么存
//
// 管什么：/me 回来的 JSON 长什么样、怎么读（读得宽：认不出的字段不管、少了可选的不算错、日期带不带毫秒都认、
// 网址读不成就当没有）；存下来的一次回答（SkyStudioStoredAnswer：回答 + 拿到的那一刻的本机时间）。
// 合同以 Sky Studio 仓库的 docs/agents/skycut-api.md「GET /me」为准。
// 不管什么：这份回答此刻还算不算数、能用什么（SkyCutLicense）；去问（SkyStudioAPI）。

struct SkyStudioMe: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        var id: String
        var email: String?
    }

    struct Credits: Codable, Equatable, Sendable {
        var balance: Double
    }

    struct Features: Codable, Equatable, Sendable {
        var mcp: Bool
        var watermark: Bool
    }

    /// `skycut` 那一块：这个账号的 SkyCut 授权。规则全在服务器，这里只照着读。
    struct License: Codable, Equatable, Sendable {
        /// `free` / `trial` / `pro`；认不出的也留着原样（显示用，能用什么只看 `features`）。
        var plan: String
        var trialStartedAt: Date?
        var trialEndsAt: Date?
        /// 没给体验的原因：`machine_used`（这台 Mac 已经给别的账号体验过）。
        var trialUnavailable: String?
        var paidUntil: Date?
        var features: Features
        /// 不问服务器能照这份回答用到什么时候（服务器的钟）。
        var validUntil: Date
        var minVersion: String?
        var maxRunningJobs: Int?
        var rechargeUrl: String?
        /// 「联系开通」那一页（2026-10-27 用户定：先做 B 端，C 端先只放联系方式）；服务器没给就用 SkyStudioLinks.upgradePage。
        var upgradeUrl: String?
    }

    var account: Account
    var credits: Credits
    var skycut: License
    var serverTime: Date
}

extension SkyStudioMe.License {
    var rechargeURL: URL? { SkyStudioLinks.webURL(rechargeUrl) }
    var upgradeURL: URL? { SkyStudioLinks.webURL(upgradeUrl) }
}

/// 存下来的一次 /me：断网时照它用到 `validUntil`（SkyCutLicense 换算成本机时间）。
struct SkyStudioStoredAnswer: Codable, Equatable, Sendable {
    var me: SkyStudioMe
    /// 拿到回答那一刻的本机时间。
    var receivedAt: Date

    /// 把服务器的时间换成本机时间：拿到回答时服务器是 `serverTime`、本机是 `receivedAt`，差多少就挪多少。
    func local(_ serverDate: Date) -> Date {
        receivedAt.addingTimeInterval(serverDate.timeIntervalSince(me.serverTime))
    }
}

/// Sky Studio 网站上 SkyCut 用到的几个页面。
enum SkyStudioLinks {
    /// 「联系开通」：没有 Key 的人问不到 /me，所以这里写一个兜底；有 Key 时用 /me 给的 `upgrade_url`。
    /// 网址要和 Sky Studio 那边定的一样（2026-10-27 建议 `/skycut`），定了就别再改：老版本的 SkyCut 一直打开它。
    static let upgradePage = URL(string: "https://skystudioai.com/skycut")!

    /// 服务器给的网址：只认 https（本机的假服务器自检时给 http://127.0.0.1 也认），读不成就当没有。
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host != nil else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", let host = url.host, SkyStudioAPI.isLoopback(host) { return url }
        return nil
    }
}

/// 读 / 写 Sky Studio 的 JSON：键是 snake_case，日期是 ISO 8601（带不带毫秒都认：JS 的 `toISOString()` 带毫秒，
/// Foundation 自带的 `.iso8601` 不认毫秒，直接用它的话这样的回答整份读不出来）。
enum SkyStudioJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter(fractional: true).string(from: date))
        }
        return encoder
    }

    static func parseDate(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }

    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}
