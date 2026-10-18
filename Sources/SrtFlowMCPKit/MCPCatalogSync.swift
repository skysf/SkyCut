import Foundation

// MARK: - App 升级之后，正在跑的旧小程序换上新的工具清单
//
// 管什么：工具清单编在小程序里（`MCPToolName` / `MCPToolCatalog`），而小程序是 AI 客户端开会话时启动的进程 —— App 升级、重开之后，
// 这个会话里跑的还是旧的小程序，清单停在旧版（2026-10-06 盲测：六条片子都用不上新加的 snap / overshoot / spring 缓动，
// docs/bugfixes/2026-10-14-stale-helper-tool-list.md）。所以 App 的每个回答带上自己清单的指纹（`fingerprint`，`MCPBridge.Response.catalog`）；
// 小程序发现和自己的不一样，就向 App 要它的清单（`MCPBridge.catalogTool`，App 在收发线程上答），从此按它回 `tools/list`、认它的工具名，
// 并告诉客户端清单变了（老一代协议发 `notifications/tools/list_changed`；新一代靠清单的缓存时间）。
// 不管什么：清单本身（MCPToolCatalog）、怎么收发（AppConnection / AIBridgeServer）。总说明（instructions）只在握手时给，换不了。

public enum MCPCatalogSync {
    /// 这一份程序里编进去的清单（全部提供方都配好时）的指纹。FNV-1a 64 位、按同一份 JSON 文本算：两边是同一份清单就一样
    /// （不用 Swift 的 Hasher：它每个进程换一次种子）。
    public static let fingerprint: String = digest(
        MCPToolName.listJSON(providers: Set(MCPProvider.allCases)).encodedString()
    )

    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// App 答 `catalogTool` 的结果：全部工具的定义（顺序就是清单的顺序）+ 要哪个提供方才列出来。
    public static func catalogResult() -> JSONValue {
        var providers: [String: JSONValue] = [:]
        for tool in MCPToolName.allCases {
            if let provider = tool.provider { providers[tool.rawValue] = .string(provider.rawValue) }
        }
        return [
            "fingerprint": .string(fingerprint),
            "tools": .array(MCPToolName.allCases.map(\.definition.json)),
            "providers": .object(providers)
        ]
    }

    /// 换上新清单的那一次，工具结果里给 AI 的一句话。
    public static let refreshedNote = """
        SkyCut was updated after this AI session started, so the session began with an older tool list. \
        It has been refreshed: list the tools again if a tool or option you need seemed to be missing.
        """
}

/// 小程序换上的 App 那份清单（没换就是空的，照旧用编进来的那份）。线程安全：工具调用在后台线程回来时写，`tools/list` 在别的线程读。
public final class MCPCatalogOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?
    private var tools: [(name: String, provider: String?, json: JSONValue)] = []
    private var pendingNotice = false

    public init() {}

    /// App 报来的指纹要不要去换：报了、和编进来的不一样、也不是已经换上的那份。
    public func needsRefresh(appFingerprint: String?) -> Bool {
        guard let appFingerprint, appFingerprint != MCPCatalogSync.fingerprint else { return false }
        lock.lock()
        defer { lock.unlock() }
        return appFingerprint != fingerprint
    }

    /// 换上 App 的那份（`MCPCatalogSync.catalogResult` 的样子）。认不出来就不换，返回 false。
    @discardableResult
    public func adopt(_ catalog: JSONValue) -> Bool {
        guard let fingerprint = catalog["fingerprint"]?.stringValue, let list = catalog["tools"]?.arrayValue, !list.isEmpty else {
            return false
        }
        let providers = catalog["providers"]?.objectValue ?? [:]
        let parsed = list.compactMap { tool -> (name: String, provider: String?, json: JSONValue)? in
            guard let name = tool["name"]?.stringValue else { return nil }
            return (name, providers[name]?.stringValue, tool)
        }
        guard parsed.count == list.count else { return false }
        lock.lock()
        defer { lock.unlock() }
        self.fingerprint = fingerprint
        tools = parsed
        pendingNotice = true
        return true
    }

    /// 刚换上、还没告诉客户端：取一次就清掉（小程序据此给老一代客户端发 `list_changed`）。
    public func takeRefreshNotice() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let notice = pendingNotice
        pendingNotice = false
        return notice
    }

    /// 换上过吗。
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fingerprint != nil
    }

    /// 配了这些提供方时该列的工具（`tools/list` 的 `tools`）；没换上就是 nil。
    public func toolsJSON(providers enabled: Set<MCPProvider>) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard fingerprint != nil else { return nil }
        let names = Set(enabled.map(\.rawValue))
        return .array(tools.filter { $0.provider.map(names.contains) ?? true }.map(\.json))
    }

    /// 这个名字是换上的那份清单里的工具吗（编进来的清单里没有的新工具，调用照样转给 App）。
    public func knows(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tools.contains { $0.name == name }
    }
}
