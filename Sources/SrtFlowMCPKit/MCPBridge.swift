import Foundation

// MARK: - 小程序和 App 之间的通道
//
// 管什么：`skycut-mcp`（AI 客户端启动的小程序）把一次工具调用交给正在运行的 SrtFlow 时，
// 两边说的话长什么样、在哪个 Unix socket 上说。
// 不管什么：socket 怎么收发（MCPUnixSocket）、MCP 协议本身（MCPServerCore）。
//
// 一次调用一条连接：小程序连上 → 写一行请求 → 读一行回答 → 断开。连接便宜，
// 这样 Claude 同时发几个调用也不用在一条连接上配对。

public enum MCPBridge {
    /// 通道格式的版本。两边对不上时 App 回一句人话（「请重启 AI 客户端」），
    /// 别让 AI 对着解码错误猜。
    public static let version = 1

    public struct Request: Codable, Sendable {
        public var bridge: Int
        public var id: String
        public var tool: String
        public var arguments: JSONValue
        /// 哪个 AI 客户端（`initialize` 或每次请求 `_meta` 里的 clientInfo.name）。横幅上显示它。
        public var client: String?
        /// 这个会话在剪的工程（小程序记的，`MCPSessionProject`）。App 发现开着的不是它就不做（几个会话共用一个 App）。
        /// 后加的两个字段都是可选的：老小程序不带、老 App 不认，照旧能通。
        public var project: ProjectStamp?
        /// 哪个会话（一个小程序进程一个随机号）：会话自己刚换了工程，并排发来的下一个调用不算「被别人换了」。
        public var session: String?

        public init(
            id: String = UUID().uuidString, tool: String, arguments: JSONValue, client: String?,
            project: ProjectStamp? = nil, session: String? = nil
        ) {
            self.bridge = MCPBridge.version
            self.id = id
            self.tool = tool
            self.arguments = arguments
            self.client = client
            self.project = project
            self.session = session
        }
    }

    public struct Response: Codable, Sendable {
        public var bridge: Int
        public var id: String
        /// MCP 的 CallToolResult：`content` + `isError`。
        public var result: JSONValue
        /// 这一次用到的（或刚换上的）工程；没碰工程的调用、被拒的调用不带。小程序据此记住这个会话在剪哪一个。
        public var project: ProjectStamp?
        /// 只有回答「探一下」（`probeTool`）时带：主线程还活着没有、问的那个调用到哪了。
        public var health: Health?
        /// 回答的这一方编进去的工具清单的指纹（`MCPCatalogSync.fingerprint`）。小程序发现和自己的不一样（App 升级过、这个会话里跑的
        /// 还是旧小程序），就向 App 要新清单（`catalogTool`）。老 App 不带、老小程序不认，照旧能通。
        public var catalog: String?

        public init(
            id: String, result: JSONValue, project: ProjectStamp? = nil, health: Health? = nil,
            catalog: String? = MCPCatalogSync.fingerprint
        ) {
            self.bridge = MCPBridge.version
            self.id = id
            self.result = result
            self.project = project
            self.health = health
            self.catalog = catalog
        }
    }

    // MARK: App 卡住的时候

    /// 小程序等一个调用等久了，另开一条连接问 App 的那一种请求（`Request.tool` 写这个名字，不是 MCP 的工具）。
    /// App 在收发线程上当场回、**不经主线程**：主线程卡死了也答得上来。参数 `call` 是在等的那个调用的 id，
    /// `abandon: true` = 小程序不等了 —— 那个调用还没开始就不做了（不然 App 缓过来之后照做，AI 以为它失败了、再调一次就做了两遍）。
    /// docs/architecture/ai-control-mcp.md 第三节「App 卡住的时候」。
    public static let probeTool = "_srtflow_probe"

    /// 小程序要 App 的工具清单（`MCPCatalogSync.catalogResult`）的那一种请求：App 在收发线程上当场回、不经主线程。
    /// 回答里的指纹和小程序自己的不一样时才来要（docs/bugfixes/2026-10-14-stale-helper-tool-list.md）。
    public static let catalogTool = "_srtflow_catalog"

    /// 一个调用在 App 里到哪了。
    public enum CallState: String, Codable, Sendable {
        /// 还没轮到（主线程卡着、或者排在别的调用后面）。
        case waiting
        /// 正在做。
        case running
        /// 做完了（回答可能还在路上）。
        case finished
        /// 没开始就放弃了，不会再做。
        case dropped
        /// App 不认得这个 id（太早、太晚，或者 App 重启过）。
        case unknown
    }

    public struct Health: Codable, Sendable, Equatable {
        /// 主线程已经多久没回应（秒）：0 = 好好的；nil = 量不出来（App 的看门狗关着）。
        public var mainThreadStuckSeconds: Double?
        /// 问到的那个调用到哪了（没问就是 nil）。
        public var call: CallState?

        public init(mainThreadStuckSeconds: Double?, call: CallState?) {
            self.mainThreadStuckSeconds = mainThreadStuckSeconds
            self.call = call
        }
    }

    /// 一个开着的工程是谁（docs/architecture/ai-control-mcp.md 第三节「几个会话共用一个 App」）。
    ///
    /// `token` 认的是「这一次运行里的这一次打开」：App 每次启动换一个前缀、每换一次工程后面的号 +1，所以存储为、自动存盘
    /// 改了路径也还是它，App 重启过、中间被换走过就不是。同一个文件（路径一样）也算同一个：被换走又换回来的还是它。
    /// `path`、`name` 用来对 AI 说清楚是哪一个。
    public struct ProjectStamp: Codable, Sendable, Equatable {
        public var token: String
        public var path: String?
        public var name: String
        /// 工程的短 id（p1、p2…，AI 用 `project` 参数指它；2026-10-17 起）。老 App 不带。
        public var id: String?

        public init(token: String, path: String?, name: String, id: String? = nil) {
            self.token = token
            self.path = path
            self.name = name
            self.id = id
        }

        public func isSameProject(as other: ProjectStamp) -> Bool {
            if token == other.token { return true }
            guard let path, let otherPath = other.path else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: otherPath).standardizedFileURL.path
        }

        /// 这一次运行的代号（`token` 的前半截）：App 重启过就不一样，短 id 会从 p1 重新发，旧的 p2 不再是那一个。
        public var run: String { String(token.prefix { $0 != "-" }) }
    }

    /// 工具结果：一段文字。出错也走它（`isError: true`）—— MCP 规定工具自己的失败要让模型看得见，
    /// 不能变成协议层的错误。
    public static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError)
        ]
    }

    /// 在结果最前面加一句（小程序自己的话，比如「SrtFlow 刚被重新启动」）：别的内容（文字、图）和 `isError` 原样留着。
    public static func addingNote(_ note: String, to result: JSONValue) -> JSONValue {
        guard case .object(var object) = result else { return result }
        var content: [JSONValue] = [["type": "text", "text": .string(note)]]
        if case .array(let existing)? = object["content"] { content += existing }
        object["content"] = .array(content)
        return .object(object)
    }

    /// 小程序得先把 App 拉起来才连得上时，结果前面那一句：之前打开的工程、文件夹、看法都不在了（多半是 App 被退出过）。
    public static let relaunchNote = "Note: SkyCut was not running, so it was just started. Nothing from before is open: "
        + "call open_folder and open_project again before using earlier paths or ids (and set_view background again if you "
        + "were working in the background)."

    // MARK: 在哪说

    /// App 监听的那个 socket。
    ///
    /// **按 bundle id 分开**：测试版（另一个 bundle id）和正式版同时开着时，各自的小程序只连
    /// 自己那个 App。放在「应用支持」下面而不是 /tmp：那个目录只有这个用户能进。
    /// Unix socket 的路径不能超过 103 个字节，太长（用户名特别长）就退到 /tmp 下按用户号区分。
    public static func socketPath(bundleIdentifier: String, home: String = realHomeDirectory()) -> String {
        let preferred = home + "/Library/Application Support/" + bundleIdentifier + "/mcp.sock"
        if preferred.utf8.count < 104 { return preferred }
        return "/tmp/srtflow-mcp-\(getuid())-\(stableHash(bundleIdentifier) % 100_000).sock"
    }

    /// 两个进程算出来必须一样的哈希（FNV-1a）。**不能用 `hashValue`**：Swift 每个进程的
    /// 哈希种子不同，小程序和 App 会算出两个不同的路径。
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// 真正的家目录（不看 `HOME` 环境变量：被沙盒化的客户端会把它指到自己的容器里，
    /// 那样小程序和 App 算出来的 socket 就不是同一个）。
    public static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
