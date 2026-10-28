import Foundation

// MARK: - 交活之前要的两样：Key、模型表（这一次运行里记一份）
//
// 管什么：（1）拿 Sky Studio 的 Key：用户点了按钮起的活可以弹钥匙串授权框（`.prompting`），AI 起的活不弹（`.silent`：没人在看，
// 读不到就请用户去设置里点「允许…」，同 SkyStudioAccount 后台问 /me 的规矩）；没存 Key、读不到各说一句。
// （2）`GET /models` 记一份：10 分钟内不再问，同时只问一次；换了 Key 就作废（SkyStudioAccount 存 / 删 Key 时调 `forget`）。
// 不管什么：HTTP（SkyStudioAPI）、钥匙串（SkyStudioKey / KeychainSecret）、每种活怎么用这些（upscale、生成、配旁白）。

@MainActor
enum SkyStudioJobKey {
    enum Mode { case prompting, silent }

    /// 读不到 Key 时给 AI / 界面的话（英文；界面那边各自按语言换）。
    enum Problem: Error, Equatable {
        case noKey
        case needsPermission
        case keychain(Int32)

        var message: String {
            switch self {
            case .noKey:
                return "No Sky Studio API key is set in SkyCut. Ask the user to create one in Sky Studio (the avatar at the top right → SkyCut) "
                    + "and paste it in SkyCut Settings → Sky Studio."
            case .needsPermission:
                return "SkyCut needs the user's permission to read the Sky Studio key: ask them to open SkyCut Settings → Sky Studio and "
                    + "click Allow…, then try again."
            case .keychain(let status):
                return "The macOS keychain did not give SkyCut the Sky Studio key (error \(status))."
            }
        }
    }

    /// `willAsk`：要弹授权框之前在主线程上叫一声（界面先说一句这是什么）；`.silent` 从不弹。
    static func key(_ mode: Mode, willAsk: @escaping @MainActor @Sendable () -> Void = {}) async -> Result<String, Problem> {
        let result = mode == .prompting ? await SkyStudioKey.cache.key(willAsk: willAsk) : await SkyStudioKey.cache.keyWithoutPrompt()
        switch result {
        case .key(let key): return .success(key)
        case .missing: return .failure(.noKey)
        case .needsPermission: return .failure(.needsPermission)
        case .failed(let status): return .failure(.keychain(status))
        }
    }
}

/// `/models` 记一份。
@MainActor
final class SkyStudioCatalogCache {
    static let shared = SkyStudioCatalogCache()
    static let lifetime: TimeInterval = 600

    private var stored: (catalog: SkyStudioCatalog, at: Date)?
    private var loading: Task<SkyStudioCatalog, Error>?

    /// 有就用；没有、或者过了 10 分钟就问一次（正在问就等那一次）。
    func catalog(key: String, api: SkyStudioAPI = SkyStudioAPI(), now: Date = Date()) async throws -> SkyStudioCatalog {
        if let stored, now.timeIntervalSince(stored.at) < Self.lifetime, now >= stored.at { return stored.catalog }
        if let loading { return try await loading.value }
        let task = Task { try await api.models(key: key) }
        loading = task
        defer { loading = nil }
        let catalog = try await task.value
        stored = (catalog, Date())
        return catalog
    }

    /// 换了 Key（模型和价可能跟账号走）。
    func forget() {
        stored = nil
        loading = nil
    }
}
