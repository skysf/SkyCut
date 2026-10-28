import Foundation

// MARK: - 生成类工具的「提供方」：配了谁、才列出谁的工具
//
// 管什么：方案第 36 条 —— 大多数用户不一定会填 fal 的 Key，**生成类工具做成提供方可换，谁都没配就不列出来**（以后可以换成
// skystudioai.com）。工具清单是小程序当场回的（Claude 一启动就要清单，不能为此把 SrtFlow 拉起来），而 Key 在 App 的钥匙串里：
// 所以 App 在 Key 添加 / 删除时写一个**只有提供方名字**的小文件（`mcp-providers.json`，放在和 socket 同一个目录），小程序回清单时读它。
// 文件里没有 Key、也没有别的机密：`{"providers":["fal","skystudio"]}`。2026-10-28 起 generate_media、upscale_clip 都归 Sky Studio
// （收费方案第 6 刀）；fal 的 Key 只剩配旁白（add_voiceover 一直列着），不再多列工具，第 7 刀删 fal 时连这个提供方一起删。
// 不管什么：Key 怎么存（App 的 FalKeyStore / SkyStudioKey）、谁写这个文件（App 的 MCPProviderSync）、清单怎么回（MCPServerCore）。
//
// 读得宽：文件不在 / 读不出来 / 有不认识的提供方，都当「没有」，不因此让整份清单出错。

public enum MCPProvider: String, CaseIterable, Sendable {
    case fal
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
