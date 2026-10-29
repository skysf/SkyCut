import Foundation

// MARK: - 云端工具提供方标记
// 管什么：App 启动与 Sky Studio Key 变化时写提供方名字；helper 不碰钥匙串即可决定清单。
// 不管什么：密钥 / 请求。沿用 mcp-providers.json，宽容读取旧版 fal 标记并忽略已删除的提供方。

public enum MCPProvider: String, CaseIterable, Sendable {
    /// Sky Studio 的 Key（`sk-…`，设置里「Sky Studio」一节）。
    case skystudio
}

public enum MCPProviderMarker {
    /// 和 socket 同一个目录（`~/Library/Application Support/<bundle id>/`）。测试版是另一个 bundle id，各有各的。
    public static func url(bundleIdentifier: String, home: String = MCPBridge.realHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/" + bundleIdentifier + "/mcp-providers.json")
    }

    public static func read(at url: URL) -> Set<MCPProvider> {
        guard let data = try? Data(contentsOf: url), let json = try? JSONValue.decode(data),
              let names = json["providers"]?.arrayValue else { return [] }
        return Set(names.compactMap { $0.stringValue.flatMap(MCPProvider.init(rawValue:)) })
    }

    /// 只在内容变了才写（App 每次启动都会同步一遍，别白白动文件的修改时间）。
    @discardableResult
    public static func write(_ providers: Set<MCPProvider>, to url: URL) throws -> Bool {
        guard read(at: url) != providers || !FileManager.default.fileExists(atPath: url.path) else { return false }
        let names = providers.map(\.rawValue).sorted().map { JSONValue.string($0) }
        let data = try JSONValue.object(["providers": .array(names)]).encodedData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }
}
